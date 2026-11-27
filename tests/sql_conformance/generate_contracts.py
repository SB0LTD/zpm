#!/usr/bin/env python3
"""Generate allocator-free in-process Sig contracts from a validated PG oracle.

The generated broad suite is intentionally red until gaps close; never add it to
the passing regression aggregate or treat core smoke coverage as full conformance.
"""
import argparse
import hashlib
import json
from pathlib import Path

from audit import FIRST_USER_OID, explain_measurement


def literal(value):
    if value is None:
        return "null"
    # Escape bytes, not UTF-16 codepoints: Sig string literals use UTF-8 bytes.
    return '"' + ''.join(chr(b) if 32 <= b < 127 and b not in (34, 92)
                         else f'\\x{b:02x}' for b in value.encode('utf8')) + '"'


PRELUDE = r'''
const std=@import("std"); const sql=@import("sql");
const DB=sql.Database(.{.tables=8,.columns=16,.rows_per_table=32,.text_bytes=512,
    .expr_nodes=2048,.work_rows=64,.result_rows=64,.nulls_first_ascending=false});
/// Catalog identity of an allocated type (OID >= 16384): pg_namespace.nspname,
/// pg_type.typname and typtype, recorded from native PostgreSQL by
/// verify_type_identity_oracle.py. Built-in OIDs are compared exactly.
const Identity=struct{namespace:[]const u8,name:[]const u8,kind:[]const u8};
const Column=struct{name:[]const u8,oid:u32,typmod:i32,identity:?Identity=null};
/// explain_rows: audit.py's explain_structure comparator (root actual rows).
const Statement=struct{source:[]const u8,columns:[]const Column,rows:[]const []const ?[]const u8,explain_rows:?u64=null};
const Case=struct{id:[]const u8,ordered:bool,reason:?[]const u8=null,statements:[]const Statement=&.{}};
var db:DB=.{};var result:DB.Result=.{};var identity_result:DB.Result=.{};
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
/// The wire's RowDescription OID: a nominal (user-defined) type, else the built-in OID.
fn columnOid(index:usize) u32 {
    if(result.nominalColumnType(index)) |nominal| return nominal.oid;
    return sql.typeOid(result.column_types[index]);
}
/// The wire's text: record output for nominal composite values, else ordinary output.
fn cellText(column:usize,cell:anytype,buffer:*[DB.Io.format_bytes]u8) ![]const u8 {
    if(try result.formatNominalText(column,cell,buffer)) |length| return buffer[0..length];
    return DB.Io.format(cell,false,&db.session,buffer);
}
fn rowEqual(expected:[]const ?[]const u8,index:usize) !bool {
    var buffer:[DB.Io.format_bytes]u8=undefined;
    for(expected,0..) |wanted,column| {
        const cell=&result.rows[index].cells[column];
        if(wanted) |text| {
            if(cell.*==.null_value) return false;
            if(!same(text,try cellText(column,cell,&buffer))) return false;
        } else if(cell.*!=.null_value) return false;
    }
    return true;
}
/// audit.py resolves allocated OIDs inside the fixture transaction with this
/// same pg_type/pg_namespace query and compares the identities.
fn sameIdentity(tx:u16,oid:u32,wanted:Identity) !bool {
    if(oid<16384) return false;
    var text:[192]u8=undefined;
    const source=try std.fmt.bufPrint(&text,"SELECT n.nspname,t.typname,t.typtype FROM pg_catalog.pg_type t " ++
        "JOIN pg_catalog.pg_namespace n ON n.oid=t.typnamespace WHERE t.oid={d}",.{oid});
    try db.statement(tx,source,&identity_result,.{});
    if(identity_result.column_count!=3 or identity_result.row_count!=1) return false;
    var buffer:[DB.Io.format_bytes]u8=undefined;
    for([_][]const u8{wanted.namespace,wanted.name,wanted.kind},0..) |part,column| {
        const cell=&identity_result.rows[0].cells[column];
        if(cell.*==.null_value) return false;
        if(!same(part,try DB.Io.format(cell,false,&db.session,&buffer))) return false;
    }
    return true;
}
fn verify(expected:*const Statement,ordered:bool,tx:u16) !void {
    if(expected.explain_rows!=null) return verifyExplain(expected);
    if(result.column_count!=expected.columns.len or result.row_count!=expected.rows.len) return error.RowShapeMismatch;
    for(expected.columns,0..) |column,index| {
        if((column.identity==null and columnOid(index)!=column.oid) or
            result.column_typmods[index]!=column.typmod or
            !same(result.column_names[index].slice(),column.name)) return error.MetadataMismatch;
    }
    var used:[64]bool=@splat(false);
    for(expected.rows,0..) |row,index| {
        if(ordered){if(!try rowEqual(row,index)) return error.OrderedValueMismatch;}
        else {
            var found=false;
            for(0..result.row_count) |candidate| {
                if(!used[candidate] and try rowEqual(row,candidate)){used[candidate]=true;found=true;break;}
            }
            if(!found) return error.BagValueMismatch;
        }
    }
    // Allocated OIDs last: the lookup runs another statement in the transaction.
    for(expected.columns,0..) |column,index| {
        if(column.identity) |wanted| if(!try sameIdentity(tx,columnOid(index),wanted)) return error.MetadataMismatch;
    }
}
/// audit.py explain_structure: one typed JSON cell whose plan tree is
/// structurally valid; physical operators and timing may differ, the root's
/// actual rows for its single loop must match.
fn verifyExplain(expected:*const Statement) !void {
    if(result.command!=.explain or result.column_count!=1 or result.row_count!=1 or expected.columns.len!=1) return error.ExplainShapeMismatch;
    const column=expected.columns[0];
    if(columnOid(0)!=column.oid or result.column_typmods[0]!=column.typmod or
        !same(result.column_names[0].slice(),column.name)) return error.MetadataMismatch;
    const cell=&result.rows[0].cells[0];
    if(cell.*==.null_value) return error.ExplainShapeMismatch;
    var buffer:[DB.Io.format_bytes]u8=undefined;
    var plan:PlanJson=.{.text=try cellText(0,cell,&buffer)};
    const rows=plan.measure() orelse return error.ExplainStructureMismatch;
    if(rows!=expected.explain_rows.?) return error.ExplainRowsMismatch;
}
/// Allocator-free reader for EXPLAIN (FORMAT JSON) mirroring audit.py's
/// explain_measurement: a one-element array whose object holds "Plan"; every
/// plan node has a non-empty "Node Type" string, a non-negative numeric
/// "Actual Rows", a non-negative integer "Actual Loops" and optional "Plans"
/// array of nodes. The root must run one loop with an integral row count.
/// Later duplicate keys win, as in Python's json. Nesting is bounded.
const PlanJson=struct{
    text:[]const u8,at:usize=0,
    const max_depth=64;
    const Number=struct{literal_integer:bool,negative:bool,integral:bool,value:?u64};
    const Node=struct{type_ok:bool=false,rows:?Number=null,loops:?Number=null};
    fn ws(self:*PlanJson) void {
        while(self.at<self.text.len and (self.text[self.at]==' ' or self.text[self.at]=='\t' or self.text[self.at]=='\n' or self.text[self.at]=='\r')) self.at+=1;
    }
    fn peek(self:*PlanJson) ?u8 {self.ws();return if(self.at<self.text.len) self.text[self.at] else null;}
    fn eat(self:*PlanJson,c:u8) bool {if(self.peek()==c){self.at+=1;return true;}return false;}
    fn literal(self:*PlanJson,word:[]const u8) bool {
        if(self.text.len-self.at<word.len or !same(self.text[self.at..][0..word.len],word)) return false;
        self.at+=word.len;return true;
    }
    fn hex(c:u8) ?u8 {return switch(c){'0'...'9'=>c-'0','a'...'f'=>c-'a'+10,'A'...'F'=>c-'A'+10,else=>null};}
    /// Validates a string; true when its decoded text equals `wanted` (ASCII).
    /// `nonempty` reports whether it decodes to at least one character.
    fn string(self:*PlanJson,wanted:[]const u8,matches:*bool,nonempty:*bool) bool {
        if(!self.eat('"')) return false;
        var count:usize=0;matches.*=true;
        while(self.at<self.text.len) {
            var c=self.text[self.at];
            if(c=='"'){self.at+=1;nonempty.*=count!=0;if(count!=wanted.len) matches.*=false;return true;}
            if(c<0x20) return false;
            self.at+=1;
            if(c=='\\'){
                if(self.at>=self.text.len) return false;
                const e=self.text[self.at];self.at+=1;
                c=switch(e){'"'=>'"','\\'=>'\\','/'=>'/','b'=>8,'f'=>12,'n'=>'\n','r'=>'\r','t'=>'\t',
                    'u'=>blk:{
                        if(self.text.len-self.at<4) return false;
                        var code:u16=0;
                        for(self.text[self.at..][0..4]) |h| code=code*16+(hex(h) orelse return false);
                        self.at+=4;
                        // Non-ASCII code units never equal an ASCII key.
                        break :blk if(code<0x80) @intCast(code) else 0x80;
                    },
                    else=>return false};
            }
            if(count>=wanted.len or wanted[count]!=c) matches.*=false;
            count+=1;
        }
        return false;
    }
    fn number(self:*PlanJson) ?Number {
        self.ws();
        var n:Number=.{.literal_integer=true,.negative=false,.integral=true,.value=0};
        if(self.at<self.text.len and self.text[self.at]=='-'){n.negative=true;self.at+=1;}
        const int_start=self.at;
        if(self.at>=self.text.len) return null;
        if(self.text[self.at]=='0') self.at+=1
        else if(self.text[self.at]>='1' and self.text[self.at]<='9') {while(self.at<self.text.len and self.text[self.at]>='0' and self.text[self.at]<='9') self.at+=1;}
        else return null;
        const int_end=self.at;
        var frac_start=self.at;var frac_end=self.at;
        if(self.at<self.text.len and self.text[self.at]=='.'){
            n.literal_integer=false;self.at+=1;frac_start=self.at;
            while(self.at<self.text.len and self.text[self.at]>='0' and self.text[self.at]<='9') self.at+=1;
            frac_end=self.at;if(frac_end==frac_start) return null;
        }
        var exponent:i64=0;
        if(self.at<self.text.len and (self.text[self.at]=='e' or self.text[self.at]=='E')){
            n.literal_integer=false;self.at+=1;
            var exp_negative=false;
            if(self.at<self.text.len and (self.text[self.at]=='+' or self.text[self.at]=='-')){exp_negative=self.text[self.at]=='-';self.at+=1;}
            const exp_start=self.at;
            while(self.at<self.text.len and self.text[self.at]>='0' and self.text[self.at]<='9'):(self.at+=1){
                if(exponent<1_000_000) exponent=exponent*10+(self.text[self.at]-'0');
            }
            if(self.at==exp_start) return null;
            if(exp_negative) exponent=-exponent;
        }
        // Value = digits(int ++ frac) * 10^(exponent - frac_len).
        const digit_count=(int_end-int_start)+(frac_end-frac_start);
        const shift=exponent-@as(i64,@intCast(frac_end-frac_start));
        var zero=true;var magnitude:u128=0;var overflow=false;
        for(0..digit_count) |i| {
            const d=if(i<int_end-int_start) self.text[int_start+i] else self.text[frac_start+i-(int_end-int_start)];
            const digit=d-'0';
            if(digit!=0) zero=false;
            const kept=shift>=0 or @as(i64,@intCast(digit_count-i))+shift>0;
            if(kept){
                if(magnitude>(std.math.maxInt(u128)-9)/10) overflow=true else magnitude=magnitude*10+digit;
            } else if(digit!=0) n.integral=false;
        }
        if(!zero and shift>0){
            var k:i64=0;
            while(k<shift):(k+=1){if(magnitude>std.math.maxInt(u128)/10){overflow=true;break;}magnitude*=10;}
        }
        if(zero){n.negative=false;n.value=0;}
        else n.value=if(overflow or magnitude>std.math.maxInt(u64)) null else @intCast(magnitude);
        return n;
    }
    /// Skips any JSON value (Python's json also accepts NaN and Infinity).
    fn value(self:*PlanJson,depth:usize) bool {
        if(depth>max_depth) return false;
        const c=self.peek() orelse return false;
        switch(c){
            '{'=>{
                self.at+=1;
                if(self.eat('}')) return true;
                while(true){
                    var m=false;var ne=false;
                    if(!self.string("",&m,&ne) or !self.eat(':') or !self.value(depth+1)) return false;
                    if(self.eat(',')) continue;
                    return self.eat('}');
                }
            },
            '['=>{
                self.at+=1;
                if(self.eat(']')) return true;
                while(true){
                    if(!self.value(depth+1)) return false;
                    if(self.eat(',')) continue;
                    return self.eat(']');
                }
            },
            '"'=>{var m=false;var ne=false;return self.string("",&m,&ne);},
            't'=>return self.literal("true"),'f'=>return self.literal("false"),'n'=>return self.literal("null"),
            'N'=>return self.literal("NaN"),'I'=>return self.literal("Infinity"),
            else=>{
                if(c=='-' and self.text.len-self.at>=9 and same(self.text[self.at..][0..9],"-Infinity")){self.at+=9;return true;}
                return self.number()!=null;
            },
        }
    }
    fn isNumberStart(self:*PlanJson) bool {
        const c=self.peek() orelse return false;
        if(c=='-') return self.text.len-self.at<2 or self.text[self.at+1]!='I';
        return c>='0' and c<='9';
    }
    /// A plan node object. Returns its fields; every child must also be valid.
    fn node(self:*PlanJson,depth:usize,out:*Node) bool {
        if(depth>max_depth or !self.eat('{')) return false;
        var plans_ok=true;
        if(self.eat('}')) return false;
        while(true){
            var is_type=false;var is_rows=false;var is_loops=false;var is_plans=false;var ne=false;
            const key_at=self.at;
            if(!self.string("Node Type",&is_type,&ne)) return false;
            self.at=key_at;_=self.string("Actual Rows",&is_rows,&ne);
            self.at=key_at;_=self.string("Actual Loops",&is_loops,&ne);
            self.at=key_at;_=self.string("Plans",&is_plans,&ne);
            if(!self.eat(':')) return false;
            if(is_type){
                if(self.peek()=='"'){var m=false;var nonempty=false;if(!self.string("",&m,&nonempty)) return false;out.type_ok=nonempty;}
                else {out.type_ok=false;if(!self.value(depth+1)) return false;}
            } else if(is_rows or is_loops){
                const parsed:?Number=if(self.isNumberStart()) (self.number() orelse return false) else blk:{if(!self.value(depth+1)) return false;break :blk null;};
                if(is_rows) out.rows=parsed else out.loops=parsed;
            } else if(is_plans){
                if(self.peek()=='['){
                    self.at+=1;plans_ok=true;
                    if(!self.eat(']')){
                        while(true){
                            var child:Node=.{};
                            if(self.peek()!='{'){plans_ok=false;if(!self.value(depth+1)) return false;}
                            else if(!self.node(depth+1,&child)) return false
                            else if(!valid(&child)) plans_ok=false;
                            if(self.eat(',')) continue;
                            if(!self.eat(']')) return false;
                            break;
                        }
                    }
                } else {plans_ok=false;if(!self.value(depth+1)) return false;}
            } else if(!self.value(depth+1)) return false;
            if(self.eat(',')) continue;
            if(!self.eat('}')) return false;
            break;
        }
        if(!plans_ok) out.type_ok=false;
        return true;
    }
    fn valid(n:*const Node) bool {
        const rows=n.rows orelse return false;const loops=n.loops orelse return false;
        // A zero (also -0) is parsed as non-negative.
        if(!n.type_ok or rows.negative or !loops.literal_integer or loops.negative) return false;
        return true;
    }
    fn measure(self:*PlanJson) ?u64 {
        if(!self.eat('[') or !self.eat('{')) return null;
        var root:?Node=null;
        if(!self.eat('}')){
            while(true){
                var is_plan=false;var ne=false;
                if(!self.string("Plan",&is_plan,&ne) or !self.eat(':')) return null;
                if(is_plan){
                    if(self.peek()!='{') return null;
                    var found:Node=.{};
                    if(!self.node(1,&found)) return null;
                    root=found;
                } else if(!self.value(1)) return null;
                if(self.eat(',')) continue;
                if(!self.eat('}')) return null;
                break;
            }
        }
        if(!self.eat(']') or self.peek()!=null) return null;
        const plan=root orelse return null;
        if(!valid(&plan)) return null;
        const loops=plan.loops.?;const rows=plan.rows.?;
        if(loops.value==null or loops.value.?!=1 or !rows.integral) return null;
        return rows.value;
    }
};
fn run(case:*const Case,at:*usize) !void {
    db=.{}; result=.{};
    const tx=try db.begin();defer db.abort(tx);
    for(case.statements,0..) |statement,index| {
        at.*=index;
        try db.statement(tx,statement.source,&result,.{});
        try verify(&statement,case.ordered,tx);
    }
}
pub fn main(init:std.process.Init) !void {
    var buffer:[512]u8=undefined;var failed:usize=0;
    for(cases) |case| {
        var at:usize=0;
        const reason=if(case.reason) |reason| reason else blk:{run(&case,&at) catch |err| break :blk @errorName(err);break :blk null;};
        if(reason!=null) failed+=1;
        const line=try std.fmt.bufPrint(&buffer,"{{\"id\":\"{s}\",\"status\":\"{s}\",\"statement\":{d},\"detail\":\"{s}\"}}\n",
            .{case.id,if(reason==null) "core_smoke_pass" else "incomplete",at,reason orelse ""});
        try std.Io.File.stdout().writeStreamingAll(init.io,line);
    }
    if(failed!=0) return error.SqlConformanceIncomplete;
    // Core smoke acceptance alone never establishes full SQL/system conformance.
    return error.SqlClosureDimensionsUnqualified;
}
'''


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--oracle-report', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--type-identities', type=Path, default=Path(__file__).with_name('type_identity_oracle.json'),
                   help='Catalog identities of allocated type OIDs (verify_type_identity_oracle.py)')
    args = p.parse_args()
    manifest_bytes = Path(__file__).with_name('cases.json').read_bytes().replace(b'\r\n', b'\n')
    manifest = json.loads(manifest_bytes)
    report = json.loads(args.oracle_report.read_text(encoding='utf8'))
    if report.get('manifest_sha256') != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError('Stale or unversioned oracle evidence: revalidate the manifest')
    evidence = {c['id']: c for c in report['cases']}
    identities = {}
    if args.type_identities.exists():
        recorded = json.loads(args.type_identities.read_text(encoding='utf8'))
        if recorded.get('manifest_sha256') == report['manifest_sha256']:
            identities = recorded['cases']
    generated = [PRELUDE, '\nconst cases=[_]Case{\n']
    for case in manifest['cases']:
        prefix = '.{.id=' + literal(case['id']) + ',.ordered=' + str(case['ordered']).lower()
        oracle = evidence.get(case['id'], {})
        comparator = case.get('comparator', 'exact')
        if case['scope'] != 'transaction' or comparator not in ('exact', 'explain_structure'):
            generated.append(prefix + ',.reason="UnexecutedScopeOrComparator"},\n')
            continue
        if oracle.get('status') != 'oracle_valid':
            generated.append(prefix + ',.reason="OracleNotValidated"},\n')
            continue
        commands = manifest['fixtures'][case['setup']] + case['statements']
        expected = oracle['oracle'][1:]  # BEGIN is owned by the driver.
        if len(commands) != len(expected):
            raise ValueError('Oracle statement count mismatch: ' + case['id'])
        body, reason = [], None
        for index, (source, result) in enumerate(zip(commands, expected)):
            if result['error']:
                raise ValueError('Invalid positive oracle: ' + case['id'])
            columns = []
            for position, c in enumerate(result['columns']):
                column = '.{.name='+literal(c[0])+f',.oid={c[1]},.typmod={c[3]}'
                if c[1] >= FIRST_USER_OID:
                    # Cluster-counter OID: compare the catalog identity, as audit.py does.
                    found = identities.get(case['id'], {}).get(str(index), {}).get(str(position))
                    if found is None:
                        reason = 'OracleTypeIdentityMissing'
                        break
                    column += ',.identity=.{.namespace='+literal(found[0])+',.name='+literal(found[1])+',.kind='+literal(found[2])+'}'
                columns.append(column + '}')
            explain = ''
            if comparator == 'explain_structure' and index == len(commands) - 1:
                measured = explain_measurement(result)
                if measured is None:
                    reason = 'OracleNotValidated'
                    break
                explain = f',.explain_rows={int(measured)}'
                rows = ''
            else:
                rows = ','.join('&.{'+','.join(map(literal, row))+'}' for row in result['rows'])
            body.append('.{.source='+literal(source)+',.columns=&.{'+','.join(columns)+'},.rows=&.{'+rows+'}'+explain+'},\n')
            if reason:
                break
        if reason:
            generated.append(prefix + f',.reason="{reason}"' + '},\n')
            continue
        generated.append(prefix + ',.statements=&.{\n')
        generated += body
        generated.append('}},\n')
    generated.append('};\n')
    args.output.write_text(''.join(generated), encoding='utf8')


if __name__ == '__main__':
    main()
