"""Native PostgreSQL oracle for shared lexical parameter boundaries.

Uses SQL PREPARE to validate the same PostgreSQL template grammar; direct Parse,
Bind, binary values, Sync and failure atomicity are covered by the Sig codec test.
"""
import argparse,json,sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tests/sql_conformance"))
from verify_numeric_functions_oracle import PeerPg
from audit import Pg


def cases():
    for depth in range(65):
        yield dict(id=f"nested_{depth}",source="SELECT "+"/* ' $32 "*depth+" */"*depth+"$1::int",types="int",arguments="7",rows=[["7"]],oids=[23])
    for i,source in enumerate([
        "SELECT /* $32 */ $1::int",
        "SELECT /* outer /* $32 */ $0 */ $1::int",
        'SELECT /* \' -- " $999999999999999999999 */ $1::int',
        "SELECT /* $2 /* ' */ $3 */ $1::int",
        "SELECT $1::int /* ' */ + $1::int",
        "SELECT $1::int -- ' $32\n + $1::int",
    ]):
        yield dict(id=f"comment_{i}",source=source,types="int",arguments="7",rows=[["14" if " + " in source else "7"]],oids=[23])
    yield dict(id="quoted",source='SELECT \'it\'\'s $32\', $1::int AS "out$31"',types="int",arguments="7",rows=[["it's $32","7"]],oids=[25,23])
    yield dict(id="identifier",source="SELECT a$2 FROM lex WHERE a$2=$1 /* v=$32 */",types="int",arguments="7",rows=[["7"]],oids=[23])
    yield dict(id="inference",source="/* FROM missing $32 */ UPDATE lex SET v=$1 WHERE a$2=$2",types="",arguments="-5,7",rows=[],oids=[])
    yield dict(id="insert_inference",source="INSERT /* missing $32 */ INTO lex(a$2,v) VALUES($1,/* '$3 */$2)",types="",arguments="8,9",rows=[],oids=[])
    for i,source in enumerate(["SELECT /* unterminated $1","SELECT 1e-$1","SELECT 'a'$1,$2e1,x$3,$4.5"]):
        yield dict(id=f"syntax_{i}",source=source,types="int" if i!=2 else "text,int,bool,bigint",state="42601")


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    endpoint=parser.add_mutually_exclusive_group(required=True)
    endpoint.add_argument("--unix-socket")
    endpoint.add_argument("--port",type=int)
    version_group=parser.add_mutually_exclusive_group(required=True)
    version_group.add_argument("--expected-version")
    version_group.add_argument("--expected-major",type=int,choices=(16,18))
    parser.add_argument("--report",type=Path,required=True)
    args=parser.parse_args();pg=PeerPg(args.unix_socket) if args.unix_socket else Pg(args.port,"postgres","postgres");records=[]
    try:
        version=pg.query("SHOW server_version_num")["rows"][0][0]
        assert (version==args.expected_version if args.expected_version else int(version)//10000==args.expected_major),version
        assert pg.query("CREATE TEMP TABLE lex(a$2 INT,v INT)")["error"] is None
        assert pg.query("INSERT INTO lex VALUES(7,100)")["error"] is None
        for case in cases():
            declaration=f"({case['types']})" if case['types'] else ""
            prepared=pg.query(f"PREPARE pg_lex_case{declaration} AS {case['source']}")
            state=prepared['error']['sqlstate'] if prepared['error'] else '00000'
            assert state==case.get('state','00000'),(case,prepared)
            record=dict(case,prepare=prepared)
            if state=='00000':
                executed=pg.query(f"EXECUTE pg_lex_case({case['arguments']})")
                assert executed['error'] is None and executed['rows']==case['rows'],(case,executed)
                assert [c[1] for c in executed['columns']]==case['oids'],(case,executed)
                record['execute']=executed
                assert pg.query("DEALLOCATE pg_lex_case")['error'] is None
            records.append(record)
        assert pg.query("SELECT v FROM lex WHERE a$2=7")['rows']==[['-5']]
        assert pg.query("SELECT v FROM lex WHERE a$2=8")['rows']==[['9']]
    finally:pg.close()
    args.report.parent.mkdir(parents=True,exist_ok=True)
    args.report.write_text(json.dumps(dict(server_version=version,cases=records,failures=0),indent=2)+'\n',encoding='utf8')
    print(f"PASS {len(records)} native PREPARE cases; temporary mutation rows verified")

if __name__=='__main__':main()
