param([string]$Compiler='C:/Just-Things/Projects/Lib/sig-latest/bin/sig.exe',[string]$ZpmRoot="$PSScriptRoot/../../../zpm",[string]$ContextRoot="$PSScriptRoot/../../../zpm-context",[string]$OutputName='slowwire-studio.exe')
$ErrorActionPreference='Stop'
$slowwireRoot=(Resolve-Path "$PSScriptRoot/../..").Path
$out=Join-Path $slowwireRoot '.build'
$ui=Join-Path $PSScriptRoot 'ui'
$zpm=(Resolve-Path $ZpmRoot).Path
$context=(Resolve-Path $ContextRoot).Path
New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $slowwireRoot
try {
    $argsBuild=@(
        'build-exe','-OReleaseFast','-lkernel32','-luser32','-lgdi32','-lopengl32','-lshell32',("-femit-bin=$out/$OutputName"),
        '--dep','ui_app','-Mroot=examples/slowwire/ui/main.sig',
        '--dep','zpm_slowwire','--dep','win32','--dep','gl','--dep','window','--dep','text','--dep','primitives','--dep','color','--dep','ui_model','--dep','ui_widgets','--dep','ui_theme','--dep','context_projection',("-Mui_app=$ui/app.sig"),
        ("-Mui_model=$ui/model.sig"),
        '--dep','color',("-Mui_theme=$ui/theme.sig"),
        '--dep','primitives','--dep','color','--dep','text','--dep','ui_theme','--dep','ui_model',("-Mui_widgets=$ui/widgets.sig"),
        '--dep','win32','--dep','gl',("-Mwindow=$zpm/src/platform/window.sig"),
        '--dep','gl','--dep','color',("-Mprimitives=$zpm/src/render/primitives.sig"),
        '--dep','win32','--dep','gl','--dep','color',("-Mtext=$zpm/src/render/text.sig"),
        ("-Mwin32=$zpm/src/platform/win32.sig"),
        ("-Mgl=$zpm/src/platform/gl.sig"),
        ("-Mcolor=$zpm/src/render/color.sig"),
        '-Mzpm_slowwire=slowwire.sig',
        '--dep','sig_mem','--dep','sig_testing',("-Mcontext_projection=$context/src/core/context_projection.sig"),
        ("-Msig_mem=$context/src/core/sig_mem.sig"),
        ("-Msig_testing=$context/src/core/sig_testing.sig")
    )
    & $Compiler @argsBuild
    if($LASTEXITCODE -ne 0){Write-Error 'SlowWire Studio build failed' -ErrorAction Stop}
    Write-Output ('Built native transparent device workbench: ' + $out + '/' + $OutputName)
} finally { Pop-Location }
