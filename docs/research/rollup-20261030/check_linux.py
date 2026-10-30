import subprocess
compiler=r'C:/Users/Shado/AppData/Local/Programs/Sig/0.6.4/bin/sig.exe';sdk=r'C:/Just-Things/Projects/sb0/ramsql/.sig-cache/portable-toolchain-0df/lib';base='/mnt/c/Just-Things/Projects/sb0/zpm-sql-rollup'
legacy='/mnt/c/Just-Things/Projects/sb0/zpm-parallel-read/.sig-cache/legacy-059/sig-0.5.9-zig0.17.0.786a282-x86_64-linux'
for name in ('sql_grouping_rollup','sql_windows'):
 out='.sig-cache/'+name+'-linux'
 subprocess.run([compiler,'build-exe','-O','ReleaseSafe','-target','x86_64-linux','--dep','sql','-Mroot=tests/test_'+name+'.sig','-Msql=src/core/sql.sig','-femit-bin='+out,'--Sig-lib-dir',sdk],check=True)
 subprocess.run(['wsl.exe','-d','Ubuntu','--',base+'/'+out],check=True)
 out='.sig-cache/'+name+'-059'
 subprocess.run(['wsl.exe','-d','Ubuntu','--cd',base,'--',legacy+'/bin/sig','build-exe','-O','Debug','--dep','sql','-Mroot=tests/test_'+name+'.sig','-Msql=src/core/sql.sig','-femit-bin='+out,'--Sig-lib-dir',legacy+'/lib'],check=True)
 subprocess.run(['wsl.exe','-d','Ubuntu','--',base+'/'+out],check=True)
