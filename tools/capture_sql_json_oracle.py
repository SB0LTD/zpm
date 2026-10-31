#!/usr/bin/env python3
"""Capture exact JSON operator fixtures from a native PostgreSQL psql command.
Run from the ZPM repository root. Defaults to local psql; use --psql wsl -d
Ubuntu -u postgres -- psql for WSL. Requires UTF8 with standard_conforming_strings.
Writes the JSON oracle and prints Sig calls to stdout; never patches tests.
"""
from pathlib import Path
import subprocess,json,re,argparse
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--psql",nargs=argparse.REMAINDER,default=["psql"])
args=parser.parse_args()
root=Path.cwd()
def lit(s):return "'"+s.replace("'","''")+"'"
values=['{}','[]','null','1','true','"s"','{"a":1}','[1,2]','{"a":{"x":1}}']
exprs=[lit(a)+'::jsonb || '+lit(b)+'::jsonb' for a in values for b in values]
exprs += [lit('{"aa":1,"b":2,"a":3}')+'::jsonb || '+lit('{"a":4,"b":null,"z":9}')+'::jsonb',lit('{"a":{"x":1}}')+'::jsonb || '+lit('{"a":{"y":2}}')+'::jsonb',lit('{"a":1}')+'::jsonb || '+lit('{"b":2}'),lit('{"a":1}')+' || '+lit('{"b":2}')+'::jsonb',lit('1')+'::jsonb || '+lit('x')+'::text',lit('x')+'::text || '+lit('1')+'::jsonb',"NULL::jsonb || '{}'::jsonb","'{}'::jsonb || NULL", "'{}'::jsonb || 1", "1 || '{}'::jsonb", "'{}'::jsonb || 'not json'", "'{\"a\":1}'::json @> '{}'::json"]
docs=[' { "b" : 2, "a" : 1, "a" : 3 } ','[ 1, 2.50, { "x" : true } ]','{"a":null,"b":"a\\tb","c":"\\u00e9"}','1','null','"hello"','{"a":{"b":[1,{ "x":2.50 }]}}','{"\\u0061":1,"a":2}',r'{"bad":"\ud800","a":1}',r'{"bad":"\u0000","a":1}']
for doc in docs:
 for suffix in ["-> 'a'", "->> 'a'",'-> 0','-> -1',"->> 1", "#> '{}'", "#>> '{}'", "#> '{a,b,1}'", "#>> '{a,b,1,x}'"]:exprs.append(lit(doc)+'::json '+suffix)
exprs += [r''''{"bad":"\ud800","a":1}'::json ->> 'bad' ''',r''''{"bad":"\u0000","a":1}'::json ->> 'bad' ''',"NULL::json -> 'a'","'{}'::json -> NULL::text","'{}'::json -> 1::bigint","'{}'::jsonb -> 1::bigint", "'[10,20]'::json #> '{+1}'", "'[10,20]'::jsonb #> '{+1}'", "'[10,20]'::json #> '{ 1}'", "'[10,20]'::jsonb #> '{ 1}'"]
exprs += ["'1'::jsonb -> 0", "'1'::jsonb #> '{0}'", "'1'::jsonb #> '{}'", "'[1]'::jsonb #> '{0,0}'", "'1'::json -> 0", "'1'::json #> '{0}'", '\'"\\ud800"\'::json', '\'"\\u0000"\'::json']
records=[]
for expr in exprs:
 q='SELECT row_to_json(q) FROM (SELECT ('+expr+')::text AS value, pg_typeof(('+expr+'))::text AS type) q;'
 p=subprocess.run(args.psql+["-X","-qAt","--set=VERBOSITY=verbose"],input="SET TIME ZONE 'UTC'; SET standard_conforming_strings=on;\n"+q+'\n',text=True,capture_output=True,check=True)
 m=re.search(r'ERROR:  (\w{5}):',p.stderr)
 records.append({'sql':'SELECT ('+expr+') AS value','sqlstate':m[1] if m else '00000','result':None if m else json.loads(p.stdout),'diagnostic':p.stderr.strip()})
Path('tests/fixtures/json_operators_pg16.json').write_text(json.dumps({'reference':'PostgreSQL 16.15 Ubuntu, UTF8, UTC','cases':records},ensure_ascii=True,indent=2)+'\n',encoding='utf-8')
def sig(s):
 return '"'+''.join(('\\"' if b==34 else '\\\\' if b==92 else chr(b) if 32<=b<=126 else '\\x%02x'%b) for b in s.encode('utf-8'))+'"'
errors={'42883':'UndefinedFunction','42725':'AmbiguousFunction','22P02':'InvalidTextRepresentation','22P05':'UntranslatableCharacter','22023':'InvalidParameterValue'}
lines=[]
for c in records:
 if c['sqlstate']!='00000':
  lines.append('    try rejects('+sig(c['sql'])+', error.'+errors[c['sqlstate']]+');')
 else:
  v=c['result']['value'];ty=c['result']['type'];lines.append('    try row('+sig(c['sql'])+', '+('null' if v is None else sig(v))+', .'+ty+');')
print('\n'.join(lines))
