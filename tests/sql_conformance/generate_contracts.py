#!/usr/bin/env python3
"""Generate allocator-free in-process Sig contracts from a validated PG oracle.

The generated broad suite is intentionally red until gaps close; never add it to
the passing regression aggregate or treat core smoke coverage as full conformance.
"""
import argparse
import hashlib
import json
from pathlib import Path


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
const Column=struct{name:[]const u8,oid:u32,typmod:i32};
const Statement=struct{source:[]const u8,columns:[]const Column,rows:[]const []const ?[]const u8};
const Case=struct{id:[]const u8,ordered:bool,reason:?[]const u8=null,statements:[]const Statement=&.{}};
var db:DB=.{};var result:DB.Result=.{};
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
fn rowEqual(expected:[]const ?[]const u8,index:usize) !bool {
    var buffer:[DB.Io.format_bytes]u8=undefined;
    for(expected,0..) |wanted,column| {
        const cell=&result.rows[index].cells[column];
        if(wanted) |text| {
            if(cell.*==.null_value) return false;
            if(!same(text,try DB.Io.format(cell,false,&db.session,&buffer))) return false;
        } else if(cell.*!=.null_value) return false;
    }
    return true;
}
fn verify(expected:*const Statement,ordered:bool) !void {
    if(result.column_count!=expected.columns.len or result.row_count!=expected.rows.len) return error.RowShapeMismatch;
    for(expected.columns,0..) |column,index| {
        if(sql.typeOid(result.column_types[index])!=column.oid or
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
}
fn run(case:*const Case,at:*usize) !void {
    db=.{}; result=.{};
    const tx=try db.begin();defer db.abort(tx);
    for(case.statements,0..) |statement,index| {
        at.*=index;
        try db.statement(tx,statement.source,&result,.{});
        try verify(&statement,case.ordered);
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
    args = p.parse_args()
    manifest_bytes = Path(__file__).with_name('cases.json').read_bytes().replace(b'\r\n', b'\n')
    manifest = json.loads(manifest_bytes)
    report = json.loads(args.oracle_report.read_text(encoding='utf8'))
    if report.get('manifest_sha256') != hashlib.sha256(manifest_bytes).hexdigest():
        raise ValueError('Stale or unversioned oracle evidence: revalidate the manifest')
    evidence = {c['id']: c for c in report['cases']}
    generated = [PRELUDE, '\nconst cases=[_]Case{\n']
    for case in manifest['cases']:
        prefix = '.{.id=' + literal(case['id']) + ',.ordered=' + str(case['ordered']).lower()
        oracle = evidence.get(case['id'], {})
        if case['scope'] != 'transaction' or case.get('comparator', 'exact') != 'exact':
            generated.append(prefix + ',.reason="UnexecutedScopeOrComparator"},\n')
            continue
        if oracle.get('status') != 'oracle_valid':
            generated.append(prefix + ',.reason="OracleNotValidated"},\n')
            continue
        commands = manifest['fixtures'][case['setup']] + case['statements']
        expected = oracle['oracle'][1:]  # BEGIN is owned by the driver.
        if len(commands) != len(expected):
            raise ValueError('Oracle statement count mismatch: ' + case['id'])
        generated.append(prefix + ',.statements=&.{\n')
        for source, result in zip(commands, expected):
            if result['error']:
                raise ValueError('Invalid positive oracle: ' + case['id'])
            columns = ','.join('.{.name='+literal(c[0])+f',.oid={c[1]},.typmod={c[3]}'+'}' for c in result['columns'])
            rows = ','.join('&.{'+','.join(map(literal, row))+'}' for row in result['rows'])
            generated.append('.{.source='+literal(source)+',.columns=&.{'+columns+'},.rows=&.{'+rows+'}},\n')
        generated.append('}},\n')
    generated.append('};\n')
    args.output.write_text(''.join(generated), encoding='utf8')


if __name__ == '__main__':
    main()
