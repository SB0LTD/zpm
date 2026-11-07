import pathlib, subprocess, sys

ROOT=next(p for p in pathlib.Path(__file__).resolve().parents if (p/'src/core/sql.sig').is_file())
NAMES=['window_frames','windows','grouping_rollup','rollup','to_char','types','query','stream_group']
mode=sys.argv[1]
if len(sys.argv)>2: NAMES=sys.argv[2:]
for name in NAMES:
    source=f'tests/test_sql_{name}.sig'
    if mode=='windows':
        compiler=r'C:/Users/Shado/AppData/Local/Programs/Sig/0.6.4/bin/sig.exe'
        sdk=r'C:/Just-Things/Projects/sb0/ramsql/.sig-cache/portable-toolchain-0df/lib'
        binary=f'.sig-cache/qualified-{name}.exe'
        cmd=[compiler,'build-exe','-O','ReleaseSafe','--dep','sql',f'-Mroot={source}','-Msql=src/core/sql.sig',f'-femit-bin={binary}','--Sig-lib-dir',sdk]
        run=[binary]
    else:
        base='/mnt/c/Just-Things/Projects/sb0/'
        tool=('/home/sb/sig/sig-0.6.4-zig0.17.0.90a898d-x86_64-linux' if mode=='linux' else base+'zpm-parallel-read/.sig-cache/legacy-059/sig-0.5.9-zig0.17.0.786a282-x86_64-linux')
        compiler=tool+'/bin/sig'
        binary=f'.sig-cache/qualified-{mode}-{name}'
        prefix=['wsl','-d','Ubuntu','--cd',base+'zpm-window-frames','--']
        cmd=prefix+[compiler,'build-exe','-O','ReleaseSafe' if mode=='linux' else 'Debug','--dep','sql',f'-Mroot={source}','-Msql=src/core/sql.sig',f'-femit-bin={binary}','--Sig-lib-dir',tool+'/lib']
        run=prefix+['./'+binary]
    print(f'{mode}: {name}',flush=True)
    subprocess.run(cmd,cwd=ROOT,check=True)
    subprocess.run(run,cwd=ROOT,check=True)
