"""Generate finite native-reference VARCHAR contracts, preserving the broad red audit."""
import json,pathlib,sys,argparse
ROOT=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tests/sql_conformance'))
from generate_contracts import literal
PRELUDE=r'''const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=8,.rows_per_table=32,.work_rows=128,.result_rows=64,.expr_nodes=1024,.text_bytes=256,.nulls_first_ascending=false});
var db:DB=.{};var result:DB.Result=.{};
const Column=struct{name:[]const u8,oid:u32,typmod:i32};
const Event=struct{source:[]const u8,state:[]const u8,command:sql.CommandTag=.none,affected:usize=0,columns:[]const Column=&.{},rows:[]const []const ?[]const u8=&.{}};
const Case=struct{id:[]const u8,setup:[]const []const u8,events:[]const Event};
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
fn stateOf(err:anyerror) []const u8{return switch(err){error.Syntax=>"42601",error.InvalidParameterValue=>"22023",error.StringDataRightTruncation=>"22001",error.InvalidTextRepresentation=>"22P02",error.DivisionByZero=>"22012",error.TypeMismatch=>"42804",error.UndefinedFunction=>"42883",error.ColumnNotFound=>"42703",error.NotNullViolation=>"23502",error.PrimaryKeyViolation=>"23505",else=>@errorName(err)};}
fn verify(e:*const Event) !bool{
 if(!same(e.state,"00000") or result.command!=e.command or result.column_count!=e.columns.len or result.row_count!=e.rows.len) return false;
 if(e.command!=.select and result.affected_rows!=e.affected) return false;
 for(e.columns,0..) |c,i| if(sql.typeOid(result.column_types[i])!=c.oid or result.column_typmods[i]!=c.typmod or !same(result.column_names[i].slice(),c.name)) return false;
 var buffer:[DB.Io.format_bytes]u8=undefined;
 for(e.rows,0..) |row,i| for(row,0..) |wanted,j| {
  const cell=&result.rows[i].cells[j];
  if(wanted) |text| {if(cell.*==.null_value or !same(text,try DB.Io.format(cell,false,&db.session,&buffer))) return false;}
  else if(cell.*!=.null_value) return false;
 };
 return true;
}
const cases=[_]Case{
'''
POSTLUDE=r'''};
pub fn main() !void{
 var passed:usize=0;var gaps:usize=0;
 for(&cases) |*c| {
  db=.{};result=.{};var ok=true;
  for(c.setup) |q| db.execute(q,&result) catch |err| {std.debug.print("GAP {s} setup {s}\n",.{c.id,@errorName(err)});ok=false;break;};
  if(!ok){gaps+=1;continue;}
  for(c.events,0..) |*e,i| {
   const match=if(db.execute(e.source,&result)) |_| try verify(e) else |err| same(e.state,stateOf(err));
   if(!match){ok=false;std.debug.print("GAP {s} event{d}: {s}\n",.{c.id,i,e.source});}
  }
  if(ok){passed+=1;}else{gaps+=1;}
 }
 std.debug.print("character types: {d} passing, {d} gaps, {d} programs\n",.{passed,gaps,cases.len});
 if(gaps!=0)return error.SqlCharacterTypesIncomplete;
}
'''
def generate(f):
 out=[PRELUDE]
 for c in f['cases']:
  out.append('.{.id='+literal(c['id'])+',.setup=&.{'+','.join(literal(q) for q in c['setup'])+'},.events=&.{\n')
  for e in c['events']:
   r=e['outcome'];state=r['error']['sqlstate'] if r['error'] else '00000'
   out.append('.{.source='+literal(e['sql'])+',.state='+literal(state))
   if state=='00000':
    command=r['command'].split()[0].lower();command={'create':'create_table','drop':'drop_table'}.get(command,command)
    affected=int(r['command'].split()[-1]) if command in ('insert','update','delete') else 0
    out.append(',.command=.'+command+',.affected='+str(affected)+',.columns=&.{'+','.join('.{.name='+literal(k[0])+',.oid='+str(k[1])+',.typmod='+str(k[3])+'}' for k in r['columns'])+'},.rows=&.{'+','.join('&.{'+','.join(literal(v) for v in row)+'}' for row in r['rows'])+'}')
   out.append('},\n')
  out.append('}},\n')
 return ''.join(out)+POSTLUDE
def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--check',action='store_true');a=p.parse_args()
 text=generate(json.loads((ROOT/'tests/fixtures/character_types_pg16.json').read_text(encoding='utf8')));out=ROOT/'tests/test_sql_character_types.sig'
 if a.check:
  if out.read_text(encoding='utf8')!=text:raise SystemExit('Generated character contract stale')
 else:out.write_text(text,encoding='utf8')
if __name__=='__main__':main()
