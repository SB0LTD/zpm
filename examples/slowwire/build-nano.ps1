param([string]$Compiler='C:/Just-Things/Projects/Lib/sig-latest/bin/sig.exe',[string]$ContextRoot="$PSScriptRoot/../../../zpm-context")
$ErrorActionPreference='Stop'
$nanoRepo=(Resolve-Path "$PSScriptRoot/../..").Path
$nanoOutput=Join-Path $nanoRepo '.build'
$contextRepo=(Resolve-Path -LiteralPath $ContextRoot).Path
New-Item -ItemType Directory -Force $nanoOutput | Out-Null
function Checked([string]$program,[string[]]$arguments){ & $program @arguments; if($LASTEXITCODE -ne 0){throw "$program failed ($LASTEXITCODE)"} }
function WslPath([string]$path){ $resolved=(Resolve-Path -LiteralPath $path).Path; return '/mnt/'+$resolved.Substring(0,1).ToLower()+'/'+$resolved.Substring(3).Replace('\','/') }
Push-Location $nanoRepo
try {
    Checked $Compiler @('test','slowwire_tests.sig')
    # Object output avoids the unrelated AVR compiler_rt address-space defect.
    # AVR binutils link native Sig code and the inline Sig startup assembly.
    Checked $Compiler @('build-obj','-target','avr-freestanding-none','-mcpu','atmega328p','-OReleaseSmall','-fllvm',"-femit-bin=$nanoOutput/nano.o",'--dep','zpm_slowwire','-Mroot=examples/slowwire/nano.sig','-Mzpm_slowwire=slowwire.sig')
    $outputWsl=WslPath $nanoOutput
    Checked 'wsl' @('-d','Ubuntu','--','avr-ld','-m','avr5','-T',(WslPath "$PSScriptRoot/nano.ld"),"$outputWsl/nano.o",'-o',"$outputWsl/nano.elf")
    Checked 'wsl' @('-d','Ubuntu','--','avr-size',"$outputWsl/nano.elf")
    Checked 'wsl' @('-d','Ubuntu','--','avr-objcopy','-O','binary',"$outputWsl/nano.elf","$outputWsl/nano.bin")
    Checked $Compiler @('build-exe','-OReleaseSafe','-lkernel32',"-femit-bin=$nanoOutput/slowwire-nano-host.exe",'--dep','zpm_slowwire','--dep','context_projection','-Mroot=examples/slowwire/nano-host.sig','-Mzpm_slowwire=slowwire.sig','--dep','sig_mem','--dep','sig_testing',"-Mcontext_projection=$contextRepo/src/core/context_projection.sig","-Msig_mem=$contextRepo/src/core/sig_mem.sig","-Msig_testing=$contextRepo/src/core/sig_testing.sig")
    Checked $Compiler @('build-exe','-OReleaseSafe','-lkernel32',"-femit-bin=$nanoOutput/slowwire-nano-console.exe",'--dep','zpm_slowwire','--dep','context_projection','-Mroot=examples/slowwire/nano-console.sig','-Mzpm_slowwire=slowwire.sig','--dep','sig_mem','--dep','sig_testing',"-Mcontext_projection=$contextRepo/src/core/context_projection.sig","-Msig_mem=$contextRepo/src/core/sig_mem.sig","-Msig_testing=$contextRepo/src/core/sig_testing.sig")
    Write-Output 'Built Nano firmware and native adaptive-context I/O validation host. No device was flashed.'
} finally { Pop-Location }
