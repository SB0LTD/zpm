"""Capture native conditional-DDL behavior using isolated temporary relations.
Run from repository root; --psql wsl -d Ubuntu -u postgres psql works on Windows.
Each program owns one transaction and rolls it back. Prints Sig fixture calls.
"""
from pathlib import Path
import argparse,json,re,subprocess
p=argparse.ArgumentParser(description=__doc__);p.add_argument('--psql',nargs=argparse.REMAINDER,default=['psql']);args=p.parse_args()
cases=[]
table=['CREATE TABLE t(id INTEGER PRIMARY KEY,v INTEGER DEFAULT 7)','INSERT INTO t VALUES(1,10)']
seq=['CREATE SEQUENCE s START WITH 19 INCREMENT BY 3']
def case(name,setup,statement,probe='SELECT 1 AS value'):
 cases.append(dict(name=name,setup=setup,statement=statement,probe=probe))
case('create_absent',[],'CREATE TABLE IF NOT EXISTS t(id INTEGER)','SELECT COUNT(*) AS value FROM t')
for name,definition in [('different','other TEXT'),('default','other INTEGER DEFAULT undefined_function()'),('divide','other INTEGER DEFAULT 1/0'),('identity','id INTEGER GENERATED ALWAYS AS IDENTITY(INCREMENT BY 0)'),('generated','id INTEGER GENERATED ALWAYS AS(nonexistent) STORED'),('duplicates','id INTEGER,id INTEGER'),('primary','id INTEGER PRIMARY KEY,v INTEGER PRIMARY KEY'),('not_null','id INTEGER NOT NULL NOT NULL'),('defaults','id INTEGER DEFAULT 1 DEFAULT 2')]:
 case('existing_table_'+name,table,'CREATE TABLE IF NOT EXISTS t('+definition+')','SELECT id,v FROM t ORDER BY id')
case('table_collision_sequence',seq,'CREATE TABLE IF NOT EXISTS s(id INTEGER)','SELECT nextval(\'s\') AS value')
case('sequence_collision_table',table,'CREATE SEQUENCE IF NOT EXISTS t INCREMENT BY 0','SELECT id,v FROM t ORDER BY id')
redundant=['AS TEXT AS BIGINT','INCREMENT BY 1 INCREMENT BY 2','MINVALUE 1 NO MINVALUE','NO MAXVALUE MAXVALUE 20','START 1 START 2','CACHE 1 CACHE 1','CYCLE NO CYCLE']
for name,options in [('zero','INCREMENT BY 0'),('type','AS TEXT'),('bounds','MINVALUE 10 MAXVALUE 1'),('cache','CACHE 0'),('changed','START WITH 100 INCREMENT BY -1')]+[(f'redundant_{i}',options) for i,options in enumerate(redundant)]:
 case('existing_sequence_'+name,seq,'CREATE SEQUENCE IF NOT EXISTS s '+options,"SELECT nextval('s') AS value")
for i,options in enumerate(redundant):case(f'absent_redundant_{i}',[],'CREATE SEQUENCE IF NOT EXISTS s '+options)
case('absent_invalid_type',[],'CREATE SEQUENCE IF NOT EXISTS s AS TEXT')
case('sequence_absent',[],'CREATE SEQUENCE IF NOT EXISTS s START WITH 9',"SELECT nextval('s') AS value")
for kind,name,setup in [('TABLE','t',table),('SEQUENCE','s',seq)]:
 case('drop_missing_'+kind.lower(),[],f'DROP {kind} IF EXISTS missing')
 case('drop_existing_'+kind.lower(),setup,f'DROP {kind} IF EXISTS {name}')
 case('wrong_kind_'+kind.lower(),seq if kind=='TABLE' else table,f'DROP {kind} IF EXISTS '+('s' if kind=='TABLE' else 't'))
 case('ordinary_if_'+kind.lower(),[],f'CREATE {kind} if'+('(id INTEGER)' if kind=='TABLE' else ''))
 case('drop_if_'+kind.lower(),[f'CREATE {kind} if'+('(id INTEGER)' if kind=='TABLE' else '')],f'DROP {kind} if')
case('ordinary_duplicate_table',table,'CREATE TABLE t(id INTEGER)')
case('ordinary_duplicate_sequence',seq,'CREATE SEQUENCE s')
case('bad_create_clause',[],'CREATE TABLE IF EXISTS t(id INTEGER)')
case('bad_drop_clause',[],'DROP TABLE IF NOT EXISTS t')
case('identity_owned', ['CREATE TABLE t(id INTEGER GENERATED ALWAYS AS IDENTITY)'],'DROP SEQUENCE IF EXISTS t_id_seq')
case('quoted_case', ['CREATE TABLE "T"(id INTEGER)'],'CREATE TABLE IF NOT EXISTS t(id INTEGER)','SELECT COUNT(*) AS value FROM t')
def temporary(sql):return sql.replace('CREATE TABLE','CREATE TEMP TABLE',1).replace('CREATE SEQUENCE','CREATE TEMP SEQUENCE',1)
for c in cases:
 script='BEGIN;'+''.join(temporary(x)+';' for x in c['setup'])+temporary(c['statement'])+';SELECT json_agg(row_to_json(q)) FROM ('+c['probe']+')q;ROLLBACK;'
 proc=subprocess.run(args.psql+['-X','-qAt','--set=VERBOSITY=verbose'],input=script,capture_output=True,text=True,check=True)
 error=re.search(r'ERROR:  (\w{5}):',proc.stderr)
 c.update(sqlstate=error[1] if error else '00000',rows=None if error else json.loads(proc.stdout) if proc.stdout.strip() else [],diagnostic=proc.stderr.strip())
version=subprocess.run(args.psql+['-X','-qAt','-c','SHOW server_version'],capture_output=True,text=True,check=True).stdout.strip().split()[0]
Path('tests/fixtures/conditional_ddl_pg16.json').write_text(json.dumps(dict(reference='PostgreSQL'+version,scope='Temporary relations, one rolled-back native transaction per program; notices retained separately',cases=cases),indent=2)+'\n')
def sig(s):return '"'+''.join(chr(b) if 32<=b<127 and b not in (34,92) else '\\x%02x'%b for b in s.encode())+'"'
errors={'42P07':'TableExists','42809':'WrongObjectType','42601':'Syntax','2BP01':'DependentObjects','22023':'InvalidParameterValue'}
for c in cases:
 setup='&.{'+','.join(sig(x) for x in c['setup'])+'}'
 error='error.'+errors[c['sqlstate']] if c['sqlstate']!='00000' else 'null'
 rows='&.{'+','.join('&.{'+','.join('null' if v is None else sig(str(v)) for v in row.values())+'}' for row in (c['rows'] or []))+'}'
 print(' try fixture('+setup+','+sig(c['statement'])+','+sig(c['probe'])+','+error+','+rows+');')
