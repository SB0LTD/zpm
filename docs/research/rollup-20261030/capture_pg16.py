import subprocess,json,pathlib,hashlib
setup="CREATE TEMP TABLE fact(id INTEGER PRIMARY KEY,k INTEGER,v INTEGER); INSERT INTO fact VALUES(1,1,10),(2,1,10),(3,1,30),(4,2,5),(5,2,NULL),(6,NULL,7); CREATE TEMP TABLE dim(id INTEGER PRIMARY KEY,label TEXT); INSERT INTO dim VALUES(1,'north'),(2,'north'),(3,'south');"
queries=[]
for keys in ['k','v','k,v','v,k','k,v,id','']:
 fields=keys+',' if keys else ''
 mask='GROUPING('+keys+'),' if keys else ''
 order=keys+(' NULLS LAST,GROUPING('+keys+')' if keys else '')
 # Explicit default NULL placement also applies to earlier keys via library PG profile.
 for where in ['', ' WHERE id<0',' WHERE id>2']:
  queries.append('SELECT '+fields+mask+'COUNT(*),COUNT(v),SUM(v),ROUND(AVG(v),4) FROM fact'+where+(' GROUP BY ROLLUP('+keys+')' if keys else ' GROUP BY ()')+(' ORDER BY '+order if keys else ''))
queries += [
 'SELECT k,v,GROUPING(k,v),GROUPING(v,k),GROUPING(k,k),COUNT(*) FROM fact GROUP BY ROLLUP(k,v) ORDER BY k NULLS LAST,v NULLS LAST,GROUPING(k,v)',
 'SELECT k,GROUPING(k),COUNT(DISTINCT v),COUNT(DISTINCT id),SUM(v) FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k),k NULLS LAST',
 'SELECT k,GROUPING(k),COUNT(*) FILTER (WHERE v>10),SUM(100/(id-3)) FILTER (WHERE id<>3) FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k),k NULLS LAST',
 'SELECT k,GROUPING(k),SUM(v) FROM fact GROUP BY ROLLUP(k) HAVING GROUPING(k)=1 ORDER BY k NULLS LAST',
 'SELECT k,GROUPING(k),SUM(v) FROM fact GROUP BY ROLLUP(k) HAVING COUNT(*)>1 ORDER BY GROUPING(k),k NULLS LAST',
 'SELECT k,GROUPING(k),SUM(v),RANK() OVER (ORDER BY SUM(v) DESC) FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k),k NULLS LAST',
 'SELECT k,GROUPING(k),SUM(v),SUM(SUM(v)) OVER () FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k),k NULLS LAST',
 'SELECT d.label,f.v,GROUPING(d.label,f.v),COUNT(*),SUM(f.v),ROUND(AVG(f.v),2) FROM fact f JOIN dim d ON d.id=f.k GROUP BY ROLLUP(d.label,f.v) ORDER BY d.label NULLS LAST,f.v NULLS LAST,GROUPING(d.label,f.v)',
 'SELECT d.label,f.k,GROUPING(d.label,f.k),COUNT(*),SUM(f.v) FROM fact f FULL JOIN dim d ON d.id=f.k GROUP BY ROLLUP(d.label,f.k) ORDER BY d.label NULLS LAST,f.k NULLS LAST,GROUPING(d.label,f.k)',
 'SELECT d.label,f.k,GROUPING(d.label,f.k),COUNT(*),SUM(f.v) FROM fact f CROSS JOIN dim d WHERE f.v>10 GROUP BY ROLLUP(d.label,f.k) ORDER BY d.label NULLS LAST,f.k NULLS LAST,GROUPING(d.label,f.k)',
 'SELECT k,GROUPING(k) FROM fact GROUP BY k ORDER BY k NULLS LAST',
 'SELECT k,GROUPING(k),COUNT(*) FROM fact GROUP BY ROLLUP(k) ORDER BY GROUPING(k),k NULLS LAST LIMIT 2 OFFSET 1',
 'SELECT COUNT(*) GROUP BY ()',
]
sql="\\pset null '<NULL>'\n\\pset fieldsep '\x1f'\n"+setup+'\n'+'\n'.join("SELECT 'CASE:"+str(i)+"';\n"+q+";\nSELECT 'END';" for i,q in enumerate(queries))
p=subprocess.run(['wsl.exe','-d','Ubuntu','-u','postgres','--','psql','-X','-qAt','-v','ON_ERROR_STOP=1'],input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE)
if p.returncode: print(p.stderr.decode());raise SystemExit(p.returncode)
values=[];current=[];index=None
for line in p.stdout.decode().split('\n'):
 if line.startswith('CASE:'): index=int(line[5:]);current=[]
 elif line=='END': values.append((index,'\x1e'.join(current)));index=None
 elif index is not None: current.append(line)
assert len(values)==len(queries)
target=pathlib.Path('tests/evidence/rollup-pg16.tsv')
target.write_bytes(('\n'.join(queries[i]+'\t'+value for i,value in values)+'\n').encode())
version=subprocess.check_output(['wsl.exe','-d','Ubuntu','-u','postgres','--','psql','-X','-qAt','-c','SELECT version()']).decode().strip()
meta={'reference':version,'setup':setup,'cases':len(values),'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'purpose':'correctness fixture; no timings'}
target.with_suffix('.json').write_text(json.dumps(meta,indent=2)+'\n');print(meta)
