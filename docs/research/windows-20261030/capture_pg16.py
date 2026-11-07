import subprocess,json,pathlib,hashlib
setup="CREATE TEMP TABLE fact(id INTEGER PRIMARY KEY,k INTEGER,v INTEGER); INSERT INTO fact VALUES(1,1,10),(2,1,10),(3,1,30),(4,2,5),(5,2,NULL),(6,NULL,7);"
queries=[]
for func in ['RANK()','DENSE_RANK()','ROW_NUMBER()','SUM(v)','COUNT(v)','COUNT(*)','AVG(v)','MIN(v)','MAX(v)']:
 for spec in ['','PARTITION BY k','ORDER BY v','PARTITION BY k ORDER BY v DESC NULLS LAST','PARTITION BY k ORDER BY v,id ROWS UNBOUNDED PRECEDING','ORDER BY v DESC ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING']:
  queries.append(f'SELECT id,{func} OVER ({spec}) FROM fact ORDER BY id')
queries += [
 'SELECT k,SUM(v),RANK() OVER (ORDER BY SUM(v) DESC),DENSE_RANK() OVER (ORDER BY SUM(v) DESC) FROM fact GROUP BY k ORDER BY k NULLS LAST',
 'SELECT k,SUM(v),SUM(SUM(v)) OVER () FROM fact GROUP BY k ORDER BY k NULLS LAST',
 'SELECT k,SUM(v),RANK() OVER (ORDER BY SUM(v) DESC) FROM fact GROUP BY k HAVING SUM(v)>5 ORDER BY k NULLS LAST',
 'SELECT id,COUNT(*) OVER (),SUM(v) OVER (),AVG(v) OVER () FROM fact WHERE id>2 ORDER BY id LIMIT 2 OFFSET 1',
 'SELECT DISTINCT k,COUNT(*) OVER (PARTITION BY k) FROM fact ORDER BY k NULLS LAST',
 'SELECT id FROM fact ORDER BY RANK() OVER (ORDER BY v DESC NULLS LAST),id LIMIT 4',
 'SELECT id,CASE WHEN id<3 THEN RANK() OVER (ORDER BY v DESC) ELSE 99 END FROM fact ORDER BY id',
 'SELECT id,SUM(v) OVER (PARTITION BY k ORDER BY v),COUNT(*) OVER () FROM fact ORDER BY id DESC LIMIT 4',
 'SELECT COUNT(*) OVER (),SUM(v) OVER () FROM fact WHERE id<0',
 'SELECT RANK() OVER (),COUNT(*) OVER (),MIN(NULL) OVER ()',
 'WITH revenue AS (SELECT k,SUM(v) AS revenue FROM fact GROUP BY k) SELECT k,revenue,ROUND(100.0*revenue/SUM(revenue) OVER (),4) FROM revenue ORDER BY revenue DESC,k NULLS LAST LIMIT 2',
 'SELECT id,SUM(v) OVER (PARTITION BY k ORDER BY v,id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM fact ORDER BY id',
]
# psql markers delimit complete result sets; ordinary numeric text retains scale.
sql="\\pset null '<NULL>'\n\\pset fieldsep '\x1f'\n"+setup+'\n'+'\n'.join("SELECT 'CASE:"+str(i)+"';\n"+q+";\nSELECT 'END';" for i,q in enumerate(queries))
p=subprocess.run(['wsl.exe','-d','Ubuntu','-u','postgres','--','psql','-X','-qAt','-v','ON_ERROR_STOP=1'],input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if p.returncode: print(p.stderr.decode());raise SystemExit(p.returncode)
lines=p.stdout.decode().split('\n');values=[];current=[];index=None
for line in lines:
 if line.startswith('CASE:'): index=int(line[5:]);current=[]
 elif line=='END': values.append((index,'\x1e'.join(current)));index=None
 elif index is not None: current.append(line)
assert len(values)==len(queries)
target=pathlib.Path('tests/evidence/windows-pg16.tsv')
target.write_bytes(('\n'.join(queries[i]+'\t'+value for i,value in values)+'\n').encode())
version=subprocess.check_output(['wsl.exe','-d','Ubuntu','-u','postgres','--','psql','-X','-qAt','-c','SELECT version()']).decode().strip()
meta={'reference':version,'setup':setup,'cases':len(values),'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'purpose':'correctness fixture; no timings'}
target.with_suffix('.json').write_text(json.dumps(meta,indent=2)+'\n');print(meta)
