param([ValidatePattern('^[a-z0-9-]{1,48}$')][string]$Session=('file-crash-'+(Get-Date -Format 'yyyyMMdd-HHmmss')))
$ErrorActionPreference='Stop'
$crashRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$crashOut=Join-Path $crashRoot "sig-out/mesh-history/$Session"
if(Test-Path -LiteralPath $crashOut){throw 'Choose a fresh session to preserve evidence'}
New-Item -ItemType Directory -Path $crashOut -Force | Out-Null
$crashExe=Join-Path $crashRoot 'sig-out/bin/mesh-file-crash.exe'
function Invoke-CrashChild([string]$Directory,[string]$Tag,[string[]]$Arguments,[int]$ExpectedExit=0){
 $crashProcess=Start-Process -FilePath $crashExe -ArgumentList $Arguments -WorkingDirectory $Directory -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Directory "$Tag.out.log") -RedirectStandardError (Join-Path $Directory "$Tag.log") -PassThru
 if(!$crashProcess.WaitForExit(10000)){Stop-Process -Id $crashProcess.Id;throw 'Crash fixture timed out'}
 if($crashProcess.ExitCode -ne $ExpectedExit){throw "$Tag exited with $($crashProcess.ExitCode), expected $ExpectedExit"}
 return $crashProcess.Id
}
$crashResults=@()
foreach($crashStage in 1..2){
 $crashDirectory=Join-Path $crashOut "stage-$crashStage"
 New-Item -ItemType Directory -Path $crashDirectory -Force | Out-Null
 $null=Invoke-CrashChild $crashDirectory 'baseline' @('--create=1','--expected=1')
 $crashPid=Invoke-CrashChild $crashDirectory 'crashed' @("--stage=$crashStage") (90+$crashStage)
 $crashExpected=if($crashStage -eq 1){1}else{2}
 $null=Invoke-CrashChild $crashDirectory 'recovered' @('--inspect=1',"--expected=$crashExpected")
 $crashResults+=@{stage=$crashStage;pid=$crashPid;recoveredCursor=$crashExpected;value=$crashExpected;temporaryRetained=(Test-Path -LiteralPath (Join-Path $crashDirectory 'node-history.bin.tmp'))}
}
# Keep the valid recovery candidate alongside a damaged target. Loading must
# reject corruption without silently falling back or overwriting either file.
$crashCorrupt=Join-Path $crashOut 'corrupt-target'
New-Item -ItemType Directory -Path $crashCorrupt -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $crashOut 'stage-1/node-history.bin.tmp') -Destination (Join-Path $crashCorrupt 'node-history.bin.tmp')
$crashBytes=[IO.File]::ReadAllBytes((Join-Path $crashOut 'stage-1/node-history.bin'));$crashBytes[80]=$crashBytes[80] -bxor 1
[IO.File]::WriteAllBytes((Join-Path $crashCorrupt 'node-history.bin'),$crashBytes)
$crashBefore=(Get-FileHash -LiteralPath (Join-Path $crashCorrupt 'node-history.bin') -Algorithm SHA256).Hash
$crashProcess=Start-Process -FilePath $crashExe -ArgumentList @('--inspect=1') -WorkingDirectory $crashCorrupt -WindowStyle Hidden -RedirectStandardError (Join-Path $crashCorrupt 'rejected.log') -RedirectStandardOutput (Join-Path $crashCorrupt 'rejected.out.log') -PassThru
if(!$crashProcess.WaitForExit(10000)){Stop-Process -Id $crashProcess.Id;throw 'Corruption fixture timed out'}
if($crashProcess.ExitCode -eq 0){throw 'Corrupt target accepted'}
if((Get-FileHash -LiteralPath (Join-Path $crashCorrupt 'node-history.bin') -Algorithm SHA256).Hash -ne $crashBefore){throw 'Rejected journal was modified'}
$crashReport=@{pass=$true;session=$Session;stages=$crashResults;corruptionRejected=$true;corruptTargetPreserved=$true;uncommittedTemporaryNeverPromoted=$true;scope='real Windows process crashes and atomic file replacement; not a physical power-cut test'}
$crashReport | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $crashOut 'report.json') -Encoding utf8NoBOM
$crashReport | ConvertTo-Json -Depth 5
