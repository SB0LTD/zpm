from pathlib import Path
import subprocess,json,re,argparse
parser=argparse.ArgumentParser(description="Capture scoped value-window fixtures and explicit native boundary deviations. Run from repository root.")
parser.add_argument("--psql",nargs=argparse.REMAINDER,default=["psql"])
args=parser.parse_args()
setup='CREATE TEMP TABLE w(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER); INSERT INTO w VALUES(1,1,10),(2,1,NULL),(3,1,10),(4,2,40),(5,2,50),(6,NULL,60);'
queries=[]
frames=['','ORDER BY id','PARTITION BY g ORDER BY id','ORDER BY v NULLS LAST','ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING','ORDER BY id ROWS BETWEEN 2 FOLLOWING AND 1 FOLLOWING','ORDER BY v GROUPS BETWEEN 1 PRECEDING AND CURRENT ROW EXCLUDE TIES','ORDER BY v RANGE BETWEEN 10 PRECEDING AND 10 FOLLOWING','ORDER BY v ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING EXCLUDE GROUP','ORDER BY id ROWS CURRENT ROW EXCLUDE CURRENT ROW']
frames+=['ORDER BY v DESC NULLS LAST ROWS BETWEEN 2 PRECEDING AND 1 PRECEDING EXCLUDE TIES','ORDER BY v ASC NULLS LAST ROWS BETWEEN 1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES']
for fn in ['first_value(v)','last_value(v)','nth_value(v,1)','nth_value(v,2)','nth_value(v,7)','nth_value(v,NULL)']:
 for frame in frames:queries.append('SELECT id,'+fn+' OVER('+frame+') AS value FROM w ORDER BY id')
for expr in ['nth_value(v,0)','nth_value(v,-1)','nth_value(v,g)','nth_value(v,2147483647)','nth_value(v,1::smallint)','nth_value(v,1::bigint)','nth_value(v,1.2)','first_value(NULL)',"last_value('text')",'first_value(v,1)','last_value()','nth_value(v)','first_value(*)','nth_value(v,1/0)']:
 queries.append('SELECT id,'+expr+' OVER(ORDER BY id) AS value FROM w ORDER BY id')
queries+=['SELECT id,first_value(v) OVER x AS value FROM w WINDOW x AS(PARTITION BY g ORDER BY id ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING) ORDER BY id','SELECT id,nth_value(v,0) OVER() AS value FROM w LIMIT 0','SELECT id,nth_value(v,0) OVER() AS value FROM w WHERE FALSE',"SELECT id,first_value(v::text) OVER(ORDER BY id DESC) AS value FROM w ORDER BY id"]
records=[]
for sql in queries:
 p=subprocess.run(args.psql+['-X','-qAt','--set=VERBOSITY=verbose'],input=setup+'\nSELECT json_agg(json_build_array(id::text,value::text,pg_typeof(value)::text)) FROM ('+sql+')q;',text=True,capture_output=True,check=True)
 m=re.search(r'ERROR:  (\w{5}):',p.stderr)
 records.append({'sql':sql,'sqlstate':m[1] if m else '00000','rows':None if m else json.loads(p.stdout) if p.stdout.strip() else [],'diagnostic':p.stderr.strip()})
version=subprocess.run(args.psql+['-X','-qAt','-c','SHOW server_version'],capture_output=True,text=True,check=True).stdout.strip().split()[0]
f={'reference':'PostgreSQL'+version,'setup':setup,'cases':records}
boundary=[];normal=[]
for c in f['cases']:
 if '2 PRECEDING AND 1 PRECEDING EXCLUDE TIES' not in c['sql'] and '1 FOLLOWING AND 2 FOLLOWING EXCLUDE TIES' not in c['sql']:normal.append(c);continue
 expr=re.search(r'(first_value|last_value|nth_value)\(v(?:,([^)]*))?\)',c['sql'])
 sql=c['sql'][:expr.start()]+'array_agg(v)'+c['sql'][expr.end():]
 q=f['setup']+'\nSELECT json_agg(json_build_array(id,value)) FROM ('+sql+')q;'
 proc=subprocess.run(args.psql+['-X','-qAt','--set=VERBOSITY=verbose'],input=q,text=True,capture_output=True,check=True)
 assert not proc.stderr,proc.stderr
 member_rows=json.loads(proc.stdout);expected=[]
 for identity,members in member_rows:
  members=members or [];n=1 if expr[1]=='first_value' else len(members) if expr[1]=='last_value' else None if expr[2]=='NULL' else int(expr[2])
  value=members[n-1] if n is not None and 0<n<=len(members) else None
  expected.append([str(identity),None if value is None else str(value),'integer'])
 c['frame_membership_rows']=member_rows;c['mathematical_rows']=expected;c['native_matches_frame_selection']=c['rows']==expected;boundary.append(c)
assert len(normal)==78 and len(boundary)==12
Path('tests/fixtures/window_values_boundary_deviations_pg16.json').write_text(json.dumps({'reference':f['reference'],'scope':'Known native frame-navigation differences; not passing PostgreSQL parity evidence. Mathematical values derived from independently observed array_agg frame membership.','setup':f['setup'],'cases':boundary},indent=2)+'\n')
f['cases']=normal;Path('tests/fixtures/window_values_pg16.json').write_text(json.dumps(f,indent=2)+'\n')
print('78 scoped fixtures;12 boundary programs;',sum(not c['native_matches_frame_selection'] for c in boundary),'native deviations')
