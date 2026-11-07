import subprocess
root='/mnt/c/Just-Things/Projects/sb0/zpm-block-presence'
compiler=r'C:/Users/Shado/AppData/Local/Programs/Sig/0.6.4/bin/sig.exe'
sdk=r'C:/Just-Things/Projects/sb0/ramsql/.sig-cache/portable-toolchain-0df/lib'
subprocess.run([compiler,'build-exe','-O','ReleaseSafe','-target','x86_64-linux','--dep','sql','-Mroot=tests/test_sql_dimension_distinct.sig','-Msql=src/core/sql.sig','-femit-bin=.sig-cache/dimension-distinct-linux','--cache-dir','.sig-cache/dimension-distinct-linux-cache','--Sig-lib-dir',sdk],check=True)
subprocess.run(['wsl.exe','-d','Ubuntu','--',root+'/.sig-cache/dimension-distinct-linux'],check=True)
legacy='/mnt/c/Just-Things/Projects/sb0/zpm-parallel-read/.sig-cache/legacy-059/sig-0.5.9-zig0.17.0.786a282-x86_64-linux'
subprocess.run(['wsl.exe','-d','Ubuntu','--cd',root,'--',legacy+'/bin/sig','build-exe','-O','Debug','--dep','sql','-Mroot=tests/test_sql_dimension_distinct.sig','-Msql=src/core/sql.sig','-femit-bin=.sig-cache/dimension-distinct-059-debug','--Sig-lib-dir',legacy+'/lib'],check=True)
subprocess.run(['wsl.exe','-d','Ubuntu','--',root+'/.sig-cache/dimension-distinct-059-debug'],check=True)
