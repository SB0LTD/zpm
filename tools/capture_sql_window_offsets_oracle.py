#!/usr/bin/env python3
"""Capture native offset-window fixtures from the repository root.
Default command: psql. For WSL: --psql wsl -d Ubuntu -u postgres -- psql.
The captured source setup and cases are written under tests/fixtures; generated
Sig calls print to stdout without patching test files.
"""
from pathlib import Path
import subprocess,json,re,argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--psql",nargs=argparse.REMAINDER,default=["psql"])
args=parser.parse_args()
setup="CREATE TEMP TABLE w(id INTEGER PRIMARY KEY,g INTEGER,v INTEGER,o INTEGER); INSERT INTO w VALUES(1,1,10,1),(2,1,NULL,0),(3,1,30,-1),(4,2,40,NULL),(5,2,50,99),(6,2,60,-2147483648);"
exprs=[]
for fn in ['lag','lead']:
 for args in ['v','v,0','v,1','v,-1','v,2,-99','v,-2,-99','v,99,0','v,-99,0','v,NULL,9','v,o,id*100','v,2147483647,7','v,-2147483648,7',"id::text,1,'outside'",'v::numeric,1,2.50','NULL,1,NULL',"NULL,1,'outside'", "'{\"a\":1}'::jsonb,1,'{}'",'v,1::smallint,99']:
  for spec in ['PARTITION BY g ORDER BY id','ORDER BY id DESC ROWS BETWEEN CURRENT ROW AND CURRENT ROW']:
   exprs.append((fn+'('+args+') OVER ('+spec+')',''))
 for args in ['','v,1,2,3','v,1::bigint','v,1.5','v,true','v,0,1/0']:
  exprs.append((fn+'('+args+') OVER ()',''))
 exprs += [(fn+'(v) OVER (ORDER BY id ROWS BETWEEN -1 PRECEDING AND CURRENT ROW)',''),(fn+'(v) OVER (ORDER BY id ROWS BETWEEN NULL PRECEDING AND CURRENT ROW)',''),(fn+'(v) FILTER (WHERE true) OVER ()','')]
records=[]
for expr,_ in exprs:
 sql='SELECT id,'+expr+' AS value FROM w ORDER BY id'
 q="SELECT json_agg(json_build_array(id::text,value::text,pg_typeof(value)::text)) FROM ("+sql+")q;"
 p=subprocess.run(args.psql+["-X","-qAt","--set=VERBOSITY=verbose"],input=setup+'\n'+q,text=True,capture_output=True,check=True)
 m=re.search(r'ERROR:  (\w{5}):',p.stderr)
 records.append({'sql':sql,'sqlstate':m[1] if m else '00000','rows':None if m else json.loads(p.stdout),'diagnostic':p.stderr.strip()})
Path('tests/fixtures/window_offsets_pg16.json').write_text(json.dumps({'reference':'PostgreSQL16.15','setup':setup,'cases':records},indent=2)+'\n')
def sig(s):return '"'+''.join(chr(b) if 32<=b<127 and b not in (34,92) else '\\x%02x'%b for b in s.encode())+'"'
errors={'42883':'UndefinedFunction','22012':'DivisionByZero','22013':'InvalidWindowFrameOffset','22004':'NullWindowFrameOffset','0A000':'UnsupportedStatement'}
lines=[]
for c in records:
 if c['sqlstate']=='00000':
  cells=','.join('.{'+sig(row[0])+','+('null' if row[1] is None else sig(row[1]))+','+sig(row[2])+'}' for row in c['rows'])
  lines.append('    try rows('+sig(c['sql'])+', &.{'+cells+'});')
 else:lines.append('    try rejects('+sig(c['sql'])+', error.'+errors[c['sqlstate']]+');')
print('\n'.join(lines))
