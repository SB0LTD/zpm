"""Generate the allocator-free native-reference aggregate-demand core contract."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tests/sql_conformance'))
from generate_contracts import literal

PRELUDE = r'''//! Native-reference aggregate-state demand regressions; baseline ef6e3c0 was red.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=3,.columns=8,.rows_per_table=16,.work_rows=128,.result_rows=64,.expr_nodes=512,.text_bytes=128});
var db:DB=.{};var result:DB.Result=.{};
const Column=struct{name:[]const u8,oid:u32};
const Event=struct{source:[]const u8,state:[]const u8,columns:[]const Column=&.{},rows:[]const []const ?[]const u8=&.{}};
const Case=struct{id:[]const u8,setup:[]const []const u8,events:[]const Event};
fn same(a:[]const u8,b:[]const u8) bool{return std.mem.eql(u8,a,b);}
// Finite core-test adapter for native SQLSTATEs in this fixture; protocol mapping
// remains separately qualified through the PostgreSQL codec/client suites.
fn stateOf(err:anyerror) []const u8 {return switch(err){
 error.DivisionByZero=>"22012",error.ColumnNotFound=>"42703",error.UndefinedFunction=>"42883",
 error.GroupingError=>"42803",error.IntegerOverflow,error.NumericValueOutOfRange=>"22003",
 else=>@errorName(err),
};}
fn sameRow(wanted:[]const ?[]const u8,index:usize) !bool {
 var buffer:[DB.Io.format_bytes]u8=undefined;
 for(wanted,0..) |value,column| {
  const cell=&result.rows[index].cells[column];
  if(value) |text| {if(cell.*==.null_value or !same(text,try DB.Io.format(cell,false,&db.session,&buffer))) return false;}
  else if(cell.*!=.null_value) return false;
 }
 return true;
}
fn verify(event:*const Event) !bool {
 if(!same(event.state,"00000") or result.command!=.select or result.row_count!=event.rows.len or result.column_count!=event.columns.len) return false;
 for(event.columns,0..) |column,index| if(sql.typeOid(result.column_types[index])!=column.oid or !same(result.column_names[index].slice(),column.name)) return false;
 // Compare bags, preserving duplicate rows. These probes do not close ORDER BY.
 var used:[64]bool=@splat(false);
 for(event.rows) |row| {
  var found=false;
  for(0..result.row_count) |i| if(!used[i] and try sameRow(row,i)) {used[i]=true;found=true;break;};
  if(!found) return false;
 }
 return true;
}
const cases=[_]Case{
'''
POSTLUDE = r'''};
pub fn main() !void {
 var passed:usize=0;var failed:usize=0;
 for(&cases) |*c| {
  db=.{};result=.{};var ok=true;
  for(c.setup) |source| db.execute(source,&result) catch |err| {std.debug.print("GAP {s} setup: {s}\n",.{c.id,@errorName(err)});ok=false;break;};
  if(!ok) {failed+=1;continue;}
  for(c.events,0..) |*event,index| {
   const matched=if(db.execute(event.source,&result)) |_| try verify(event) else |err| same(event.state,stateOf(err));
   if(!matched) {ok=false;std.debug.print("GAP {s} event {d}: {s}\n",.{c.id,index,event.source});}
  }
  if(ok) {passed+=1;} else {failed+=1;}
 }
 std.debug.print("aggregate demand: {d} passing, {d} gaps, {d} programs\n",.{passed,failed,cases.len});
 if(failed!=0) return error.SqlAggregateDemandIncomplete;
}
'''


def generate(fixture):
    out = [PRELUDE]
    for case in fixture['cases']:
        setup = case.get('setup', fixture['setup'])
        out.append(' .{.id=' + literal(case['id']) + ',.setup=&.{' + ','.join(literal(q) for q in setup) + '},.events=&.{\n')
        for event in case['events']:
            expected = event['outcome']
            out.append('  .{.source=' + literal(event['sql']) + ',.state=' + literal(expected['sqlstate']))
            if expected['sqlstate'] == '00000':
                columns = ','.join('.{.name=' + literal(c['name']) + ',.oid=' + str(c['oid']) + '}' for c in expected['columns'])
                rows = ','.join('&.{' + ','.join(literal(None if v is None else str(v)) for v in row) + '}' for row in expected['rows'])
                out.append(',.columns=&.{' + columns + '},.rows=&.{' + rows + '}')
            out.append('},\n')
        out.append(' }},\n')
    out.append(POSTLUDE)
    return ''.join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    fixture = json.loads((ROOT / 'tests/fixtures/aggregate_demand_pg16.json').read_text(encoding='utf8'))
    output = ROOT / 'tests/test_sql_aggregate_demand.sig'
    text = generate(fixture)
    if args.check:
        if output.read_text(encoding='utf8') != text:
            raise SystemExit('Generated aggregate-demand contract is stale')
    else:
        output.write_text(text, encoding='utf8')


if __name__ == '__main__':
    main()
