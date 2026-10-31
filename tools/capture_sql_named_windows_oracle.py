from pathlib import Path
import subprocess,json,re,argparse
parser=argparse.ArgumentParser(description="Capture PostgreSQL named-window fixtures; run from repository root.")
parser.add_argument("--psql",nargs=argparse.REMAINDER,default=["psql"])
args=parser.parse_args()
setup="CREATE TEMP TABLE w(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER); INSERT INTO w VALUES(1,1,10),(2,1,NULL),(3,1,30),(4,2,40),(5,2,50),(6,NULL,60);"
queries=[]
for expr,defs in [("sum(v) OVER x","x AS(ORDER BY id)"),("sum(v) OVER x","x AS(PARTITION BY g ORDER BY id ROWS1 PRECEDING)"),("lag(v) OVER x","x AS(PARTITION BY g ORDER BY id ROWS CURRENT ROW)"),("cume_dist() OVER x","x AS(PARTITION BY g ORDER BY v)"),("ntile(2) OVER x","x AS(PARTITION BY g ORDER BY id)"),("sum(v) OVER (x ORDER BY id)","x AS(PARTITION BY g)"),("sum(v) OVER (x ROWS1 PRECEDING)","x AS(ORDER BY id)"),("sum(v) OVER z","x AS(PARTITION BY g),y AS(x ORDER BY id),z AS(y ROWS1 PRECEDING)"),("sum(v) OVER (x)","x AS(ORDER BY id)"),("sum(v) OVER x","x AS(ROWS UNBOUNDED PRECEDING)"),("sum(v) OVER (x)","x AS(ROWS UNBOUNDED PRECEDING)"),("sum(v) OVER (x PARTITION BY g)","x AS()"),("sum(v) OVER (x ORDER BY id)","x AS(ORDER BY v)"),("sum(v) OVER missing","x AS()"),("sum(v) OVER x","x AS(y),y AS()"),("sum(v) OVER x","x AS(x)"),("sum(v) OVER x","x AS(),x AS()"),("sum(v) OVER z","x AS(ORDER BY id RANGE UNBOUNDED PRECEDING),z AS(x)"),("sum(v) OVER \"X\"",'"X" AS(ORDER BY id)'),("sum(v) OVER \"X\"","x AS(ORDER BY id)"),("sum(v) OVER x","x AS(ORDER BY id GROUPS BETWEEN1 PRECEDING AND1 FOLLOWING EXCLUDE CURRENT ROW)")]:
 queries.append(('SELECT id,'+expr+' AS value FROM w WINDOW '+defs+' ORDER BY id').replace('ROWS1','ROWS 1').replace('BETWEEN1','BETWEEN 1').replace('AND1','AND 1'))
queries += ["SELECT 1 AS id,1 AS value FROM w WINDOW x AS(ORDER BY nonexistent)","SELECT 1 AS id,1 AS value FROM w WINDOW x AS(ORDER BY sum(v))","SELECT 1 AS id,count(*) AS value FROM w WINDOW x AS(ORDER BY v)","SELECT id,(SELECT sum(v) OVER x FROM w) AS value FROM w WINDOW x AS() ORDER BY id","SELECT id,sum(v) OVER x AS value FROM w WHERE FALSE WINDOW x AS(ROWS -1 PRECEDING)","SELECT id,sum(v) OVER x AS value FROM w WINDOW x AS(ROWS (1/0) PRECEDING) LIMIT 0"]
records=[]
for sql in queries:
 q='SELECT json_agg(json_build_array(id::text,value::text,pg_typeof(value)::text)) FROM ('+sql+')q;'
 p=subprocess.run(args.psql+['-X','-qAt','--set=VERBOSITY=verbose'],input=setup+'\n'+q,text=True,capture_output=True,check=True);m=re.search(r'ERROR:  (\w{5}):',p.stderr)
 records.append({'sql':sql,'sqlstate':m[1] if m else '00000','rows':None if m else json.loads(p.stdout),'diagnostic':p.stderr.strip()})
Path('tests/fixtures/named_windows_pg16.json').write_text(json.dumps({'reference':'PostgreSQL16.15','setup':setup,'cases':records},indent=2)+'\n')
def sig(s):return '"'+''.join(chr(b) if 32<=b<127 and b not in (34,92) else '\\x%02x'%b for b in s.encode())+'"'
errors={'42704':'UndefinedObject','42P20':'WindowingError','42703':'ColumnNotFound','42803':'GroupingError','22012':'DivisionByZero','22013':'InvalidWindowFrameOffset'}
lines=[]
for c in records:
 if c['sqlstate']=='00000':
  cells=','.join('.{'+sig(row[0])+','+('null' if row[1] is None else sig(row[1]))+','+sig(row[2])+'}' for row in (c['rows'] or []))
  lines.append('    try rows('+sig(c['sql'])+', &.{'+cells+'});')
 else:lines.append('    try rejects('+sig(c['sql'])+', error.'+errors[c['sqlstate']]+');')
print('\n'.join(lines))
