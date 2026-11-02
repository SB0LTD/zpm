"""Verify frozen planner-demand observations on an explicitly selected native PG."""
import argparse,json,sys,struct
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tests/sql_conformance"))
from audit import Pg
from verify_numeric_functions_oracle import PeerPg

def describe(pg,name,source):
 def frame(tag,body):return tag+struct.pack('!I',len(body)+4)+body
 name=name.encode()+b'\0'
 pg.sock.sendall(frame(b'P',name+source.encode()+b'\0'+b'\0\0')+frame(b'D',b'S'+name)+frame(b'S',b''))
 out={'oids':[],'error':None,'tags':[]}
 while True:
  kind,body=pg.message();out['tags'].append(kind.decode())
  if kind==b'E':out['error']=pg.error(body)
  if kind==b'T':
   at=2
   for _ in range(struct.unpack('!H',body[:2])[0]):
    end=body.index(0,at);out['oids'].append(struct.unpack('!IhIhih',body[end+1:end+19])[2]);at=end+19
  if kind==b'Z':return out

def main():
 p=argparse.ArgumentParser(description=__doc__)
 g=p.add_mutually_exclusive_group(required=True);g.add_argument('--port',type=int);g.add_argument('--unix-socket')
 p.add_argument('--expected-major',type=int,choices=[16,18],required=True);p.add_argument('--report',type=Path,required=True)
 args=p.parse_args();fixture=json.loads((Path(__file__).resolve().parents[1]/'tests/fixtures/planner_demand_pg16.json').read_text(encoding='utf8'))
 pg=PeerPg(args.unix_socket) if args.unix_socket else Pg(args.port,'postgres','postgres');observed=[]
 try:
  version=pg.query('SHOW server_version_num')['rows'][0][0];assert int(version)//10000==args.expected_major,version
  metadata=[]
  for i,(source,oid) in enumerate([
   ('SELECT sqrt(-1::numeric) WHERE FALSE',1700),
   ('SELECT sqrt(-1::numeric) FROM (SELECT 1) q WHERE FALSE',1700),
   ('SELECT 1/0 LIMIT 0',23),
  ]):
   actual=describe(pg,f'planner_metadata_{i}',source)
   assert actual['error'] is None and actual['oids']==[oid] and actual['tags']==['1','t','T','Z'],(source,actual)
   metadata.append(dict(sql=source,describe=actual))
  actual=describe(pg,'planner_metadata_invalid','SELECT missing FROM (SELECT 1) q')
  assert actual['error']['sqlstate']=='42703',actual
  metadata.append(dict(sql='SELECT missing FROM (SELECT 1) q',describe=actual))
  for q in fixture['setup_native']:assert pg.query(q)['error'] is None,q
  for case in fixture['cases']:
   actual=pg.query(case['sql']);wanted=case['result']
   state=lambda r:r['error']['sqlstate'] if r['error'] else '00000'
   assert state(actual)==state(wanted),(case,actual)
   if state(actual)=='00000':
    assert actual['rows']==wanted['rows'],(case,actual)
    assert [(c[1],c[3]) for c in actual['columns']]==[(c[1],c[3]) for c in wanted['columns']],(case,actual)
   observed.append(dict(sql=case['sql'],result=actual))
 finally:pg.close()
 args.report.parent.mkdir(parents=True,exist_ok=True)
 args.report.write_text(json.dumps(dict(server_version=version,cases=observed,metadata=metadata,failures=0),indent=2)+'\n',encoding='utf8')
 print('PASS',len(observed),'native execution cases and',len(metadata),'Parse/Describe cases')
if __name__=='__main__':main()
