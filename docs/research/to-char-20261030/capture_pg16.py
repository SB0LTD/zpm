import json,pathlib,subprocess,hashlib
dates=['0001-01-01 BC','0001-12-31','0099-01-01','0100-12-31','0999-12-31','1900-03-01','1999-12-31 23:59:59.999999','2000-01-01','2000-02-29 12:34:56.012345','2001-01-01 00:00:00.000001','2024-02-29 13:14:15.123456','2024-12-31','10000-01-02','294276-12-31 23:59:59.999999']
patterns=['YYYY-MM-DD','YY YYY Y Y,YYY CC','DDD WW W Q J D','HH24:MI:SS.MS US','HH HH12 AM PM A.M. p.m.','MONTH|Month|month|MON|Mon|mon','DAY|Day|day|DY|Dy|dy','FMMonth FMDDth FMYYYY','FMDDTH DDth DDTH','FMHH24:MI:SS FMMS FMUS','BC B.C. AD A.D. bc a.d.','FF1 FF2 FF3 FF4 FF5 FF6','YYYY FMYYYY FMYYYY MM FMMM DD FMDD','SSSS SSSSS','"literal YYYY" YYYY','"a\\"b"YYYY','unknown','YYYY-MM-DD"T"HH24:MI:SS','']
queries=["SELECT to_char(TIMESTAMP '"+d+"','"+p.replace("'","''")+"')" for d in dates for p in patterns if p]
sql="SET TIME ZONE 'UTC';\n"+'\n'.join('SELECT json_build_array('+str(i)+',v) FROM ('+q+') AS t(v);' for i,q in enumerate(queries))
proc=subprocess.run(['wsl.exe','-d','Ubuntu','-u','postgres','--','psql','-X','-qAt','-v','ON_ERROR_STOP=1'],input=sql.encode(),stdout=subprocess.PIPE,stderr=subprocess.PIPE,check=True)
rows=[json.loads(line) for line in proc.stdout.decode().splitlines()]
assert len(rows)==len(queries)
target=pathlib.Path('tests/evidence/to-char-pg16.tsv')
target.write_bytes(('\n'.join(queries[i]+'\t'+value for i,value in rows)+'\n').encode())
version=subprocess.check_output(['wsl.exe','-d','Ubuntu','-u','postgres','--','psql','-X','-qAt','-c','SELECT version()']).decode().strip()
meta={'reference':version,'session_timezone':'UTC','cases':len(rows),'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'purpose':'correctness fixture; no timings'}
target.with_suffix('.json').write_text(json.dumps(meta,indent=2)+'\n')
print(meta)
