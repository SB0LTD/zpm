#!/usr/bin/env python3
"""Capture native ranking/distribution fixtures from the repository root.
Default command: psql. For WSL: --psql wsl -d Ubuntu -u postgres -- psql.
Writes frozen JSON fixture; prints Sig calls without patching test source.
"""
from pathlib import Path
import json,re,subprocess,argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--psql",nargs=argparse.REMAINDER,default=["psql"])
args=parser.parse_args()
setup="CREATE TEMP TABLE r(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER,b INTEGER); INSERT INTO r VALUES(1,1,10,NULL),(2,1,10,2),(3,1,30,3),(4,2,40,2),(5,2,40,0),(6,2,NULL,-1),(7,NULL,60,3),(8,NULL,60,1),(9,3,70,NULL);"
exprs=[]
for fn in ['percent_rank','cume_dist']:
 for spec in ['', 'ORDER BY v','ORDER BY v DESC NULLS LAST','PARTITION BY g ORDER BY v','PARTITION BY g','ORDER BY v,id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW','ORDER BY v,id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW']:
  exprs.append(fn+'() OVER ('+spec+')')
 for args in ['1','NULL','*']:exprs.append(fn+'('+args+') OVER ()')
for arg in ['1','2','3','4','8','9','10','2147483647','NULL','b',"'2'",'2::smallint','0','-1','-2147483648','2::bigint','1.5','true','1/0']:
 for spec in ['PARTITION BY g ORDER BY v,id','ORDER BY id DESC']:
  exprs.append('ntile('+arg+') OVER ('+spec+')')
exprs += ['ntile(3) OVER (ORDER BY id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW)','ntile(3) OVER (ORDER BY id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW)','ntile() OVER ()','ntile(2,3) OVER ()']
records=[]
for expr in exprs:
 sql='SELECT id,'+expr+' AS value FROM r ORDER BY id'
 q='SELECT json_agg(json_build_array(id::text,value::text,pg_typeof(value)::text)) FROM ('+sql+')q;'
 p=subprocess.run(args.psql+["-X","-qAt","--set=VERBOSITY=verbose"],input=setup+'\n'+q,text=True,capture_output=True,check=True);m=re.search(r'ERROR:  (\w{5}):',p.stderr)
 records.append({'sql':sql,'sqlstate':m[1] if m else '00000','rows':None if m else json.loads(p.stdout),'diagnostic':p.stderr.strip()})
Path('tests/fixtures/window_ranking_pg16.json').write_text(json.dumps({'reference':'PostgreSQL16.15','setup':setup,'cases':records},indent=2)+'\n')
def sig(s):return '"'+''.join(chr(b) if 32<=b<127 and b not in (34,92) else '\\x%02x'%b for b in s.encode())+'"'
errors={'42883':'UndefinedFunction','22012':'DivisionByZero','22014':'InvalidArgumentForNtile','0A000':'UnsupportedStatement','42809':'WrongObjectType'}
lines=[]
for c in records:
 if c['sqlstate']=='00000':
  cells=','.join('.{'+sig(row[0])+','+('null' if row[1] is None else sig(row[1]))+','+sig(row[2])+'}' for row in c['rows'])
  lines.append('    try rows('+sig(c['sql'])+', &.{'+cells+'});')
 else:lines.append('    try rejects('+sig(c['sql'])+', error.'+errors[c['sqlstate']]+');')
print('\n'.join(lines))
