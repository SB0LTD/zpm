"""Freeze SQRT expectations from independent Decimal arithmetic and native PG."""
import argparse,json,sys,hashlib,re
from decimal import Decimal,localcontext,ROUND_HALF_UP
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tests/sql_conformance'))
from verify_numeric_functions_oracle import PeerPg


def matrix():
    for coef in [1,2,3,4,9,10,15,16,17,99,100,101,9999,10000,10001,123456789]:
        for scale in [0,2,6,18,40]:
            yield coef,scale
    yield 0,0
    yield 0,120
    for coef in [1,2,99]:yield coef,120
    yield 10**62,0
    for delta in [0,1]:yield 10**60+10**30+delta,0


def model(coef,scale):
    with localcontext() as context:
        context.prec=256
        value=Decimal(coef).scaleb(-scale)
        # Native base10000 weight chooses display precision; actual square
        # root and rounding are independently computed by Python Decimal.
        weight=(len(str(coef))-1-scale)//4 if coef else 0
        result_scale=max(16-(2*weight+1),scale,0)
        result=value.sqrt().quantize(Decimal(1).scaleb(-result_scale),rounding=ROUND_HALF_UP)
        return f'SELECT sqrt({format(value,"f")}::numeric)',format(result,'f')


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--unix-socket',required=True)
    parser.add_argument('--expected-version',default='160015')
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--contract',type=Path)
    args=parser.parse_args()
    cases=[dict(sql=q,oid=1700,text=text,state='00000',model='Decimal sqrt with256-digit working precision') for q,text in (model(c,s) for c,s in matrix())]
    for query,oid,text in [
        ('SELECT sqrt(4)',701,'2'),('SELECT sqrt(4::real)',701,'2'),
        ("SELECT sqrt('4')",701,'2'),('SELECT sqrt(NULL)',701,None),
        ('SELECT sqrt(NULL::numeric)',1700,None),('SELECT sqrt(NULL::int2)',701,None),
        ("SELECT sqrt('-0'::float8)",701,'-0'),("SELECT sqrt('Infinity'::numeric)",1700,'Infinity'),
        ("SELECT sqrt('NaN'::numeric)",1700,'NaN'),("SELECT sqrt('NaN'::float8)",701,'NaN'),
        ("SELECT sqrt('Infinity'::float8)",701,'Infinity'),
        ('SELECT sqrt(2::float8)',701,'1.4142135623730951'),
    ]:cases.append(dict(sql=query,oid=oid,text=text,state='00000',model='explicit native edge/overload'))
    for query,state,error in [
        ('SELECT sqrt(-1)','2201F','InvalidArgumentForPowerFunction'),
        ('SELECT sqrt(-1::numeric)','2201F','InvalidArgumentForPowerFunction'),
        ("SELECT sqrt('-Infinity'::numeric)",'2201F','InvalidArgumentForPowerFunction'),
        ("SELECT sqrt('-Infinity'::float8)",'2201F','InvalidArgumentForPowerFunction'),
        ('SELECT sqrt(TRUE)','42883','UndefinedFunction'),
        ("SELECT sqrt('4'::text)",'42883','UndefinedFunction'),
        ('SELECT sqrt(4::oid)','42883','UndefinedFunction'),
        ('SELECT sqrt()','42883','UndefinedFunction'),('SELECT sqrt(1,2)','42883','UndefinedFunction'),
    ]:cases.append(dict(sql=query,state=state,error=error,model='native SQLSTATE'))
    pg=PeerPg(args.unix_socket);failures=[]
    try:
        version=pg.query('SHOW server_version_num')['rows'][0][0]
        assert version==args.expected_version,version
        for case in cases:
            actual=pg.query(case['sql']);error=actual['error']
            if case['state']=='00000':
                good=error is None and actual['rows']==[[case['text']]] and actual['columns'][0][1]==case['oid'] and actual['columns'][0][3]==-1
            else:good=error is not None and error['sqlstate']==case['state']
            if not good:failures.append(dict(case=case,actual=actual))
        extended_probes=0;extended_statements=0
        source=Path(__file__).resolve().parents[1]/'tests/test_sql_square_root.sig'
        if source.exists() and '// END frozen native cases' in source.read_text(encoding='utf8'):
            text=source.read_text(encoding='utf8').split('// END frozen native cases',1)[1]
            literal=r'("(?:[^"\\]|\\.)*")'
            assert pg.query('BEGIN')['error'] is None
            try:
                for line in text.splitlines():
                    row=re.search(r'try row\('+literal+r',(\d+),(null|'+literal+r')\)',line)
                    negative=re.search(r'try rejects\('+literal+r',error\.(\w+)\)',line)
                    setup=re.search(r'try db.execute\('+literal+r',&result\)',line)
                    if row:query=json.loads(row[1]);oid=int(row[2]);wanted=json.loads(row[3]);state='00000'
                    elif negative:
                        if negative[2] in ('NumericCapacity','QueryWorkLimit'):continue
                        query=json.loads(negative[1]);state={'InvalidArgumentForPowerFunction':'2201F'}[negative[2]]
                    elif setup:query=json.loads(setup[1]);state='00000'
                    else:continue
                    query=query.replace('CREATE TABLE ','CREATE TEMP TABLE ').replace('CREATE SEQUENCE ','CREATE TEMP SEQUENCE ')
                    pg.query('SAVEPOINT sqrt_case')
                    actual=pg.query(query);error=actual['error']
                    good=(error is None) if state=='00000' else error is not None and error['sqlstate']==state
                    if row:good=good and actual['rows']==[[wanted]] and actual['columns'][0][1]==oid and actual['columns'][0][3]==-1
                    if not good:failures.append(dict(extended_sql=query,actual=actual,expected_state=state))
                    if error:pg.query('ROLLBACK TO SAVEPOINT sqrt_case')
                    pg.query('RELEASE SAVEPOINT sqrt_case')
                    extended_statements+=1
                    if row or negative:extended_probes+=1
            finally:pg.query('ROLLBACK')
    finally:pg.close()
    report=dict(version=version,matrix_queries=sum(1 for _ in matrix()),cases=cases,failures=failures,extended_probes=extended_probes,extended_statements=extended_statements,
        script_lf_sha256=hashlib.sha256(Path(__file__).read_bytes().replace(b'\r\n',b'\n')).hexdigest())
    args.report.write_text(json.dumps(report,indent=2)+'\n',encoding='utf8',newline='\n')
    print(json.dumps(dict(cases=len(cases),extended_probes=extended_probes,extended_statements=extended_statements,failures=failures)))
    if failures:return 1
    if args.contract:
        head='''//! Native-backed SQRT TDD: exact decimal precision, rounding and overloads.
const std=@import("std");const sql=@import("sql");
const DB=sql.Database(.{.tables=2,.columns=4,.rows_per_table=8,.text_bytes=256});
var db:DB=.{};var result:DB.Result=.{};var assertions:usize=0;
fn check(ok:bool) !void {assertions+=1;if(!ok)return error.SquareRootContractFailed;}
fn row(query:[]const u8,oid:u32,wanted:?[]const u8) !void {
    db.execute(query,&result) catch |err| {std.debug.print("{s}: {s}\\n",.{query,@errorName(err)});return err;};
    try check(result.row_count==1 and result.column_count==1);
    try check(sql.typeOid(result.column_types[0])==oid and result.column_typmods[0]==-1);
    if(wanted)|text| {
        var bytes:[DB.Io.format_bytes]u8=undefined;
        const actual=try DB.Io.format(&result.rows[0].cells[0],false,&db.session,&bytes);
        if(!std.mem.eql(u8,text,actual))std.debug.print("{s}: {s} expected {s}\\n",.{query,actual,text});
        try check(std.mem.eql(u8,text,actual));
    } else try check(result.rows[0].cells[0]==.null_value);
}
fn rejects(query:[]const u8,wanted:anyerror) !void {
    const before=result;
    if(db.execute(query,&result)) |_| return error.InvalidSquareRootAccepted else |err| {try check(err==wanted);}
    try check(before.row_count==result.row_count and before.column_count==result.column_count);
    for(0..result.row_count)|i|for(0..result.column_count)|j|try check(std.meta.eql(before.rows[i].cells[j],result.rows[i].cells[j]));
}
pub fn main() !void {
'''
        lines=[]
        for case in cases:
            if case['state']=='00000':lines.append('    try row('+json.dumps(case['sql'])+','+str(case['oid'])+','+('null' if case['text'] is None else json.dumps(case['text']))+');')
            else:lines.append('    try rejects('+json.dumps(case['sql'])+',error.'+case['error']+');')
        if args.contract.exists():
            original=args.contract.read_text(encoding='utf8')
            begin='    // BEGIN frozen native cases\n';end='    // END frozen native cases'
            assert original.count(begin)==1 and original.count(end)==1,'Refuse to overwrite an unmarked contract'
            prefix,rest=original.split(begin,1);_,suffix=rest.split(end,1)
            contract=prefix+begin+'\n'.join(lines)+'\n'+end+suffix
        else:
            contract=head+'    // BEGIN frozen native cases\n'+'\n'.join(lines)+'\n    // END frozen native cases\n    std.debug.print("square-root assertions {d}\\n",.{assertions});\n}\n'
        args.contract.write_text(contract,encoding='utf8',newline='\n')
    return 0

if __name__=='__main__':raise SystemExit(main())
