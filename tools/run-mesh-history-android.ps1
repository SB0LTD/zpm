param(
 [Parameter(Mandatory=$true)][ValidatePattern('^[a-zA-Z0-9._:-]+$')][string]$Serial,
 [ValidatePattern('^[a-z0-9-]{1,48}$')][string]$Session=('android-history-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),
 [string]$WindowsAddress,
 [string]$AndroidAddress,
 [string]$AndroidBinary='sig-out/bin/mesh-history-mobile-arm64',
 [string]$WindowsBinary='sig-out/bin/mesh-history-mobile.exe',
 [string]$Adb="$env:LOCALAPPDATA/Android/Sdk/platform-tools/adb.exe"
)
$ErrorActionPreference='Stop'
$labRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$labOut=Join-Path $labRoot "sig-out/mesh-history/$Session"
$labRemote="/data/local/tmp/$Session"
if(Test-Path -LiteralPath $labOut){throw 'Choose a fresh session; existing evidence is preserved'}
New-Item -ItemType Directory -Path $labOut | Out-Null
$labPids=@{}
$labWindows=@{}
$labCross=![string]::IsNullOrEmpty($WindowsAddress)
if($labCross -ne (![string]::IsNullOrEmpty($AndroidAddress))){throw 'Supply both WindowsAddress and AndroidAddress for cross-device testing'}
function Convert-LabAddress([string]$Address){
 $labIp=[Net.IPAddress]::Parse($Address)
 if($labIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){throw 'IPv4 required'}
 $labBytes=$labIp.GetAddressBytes()
 if(!(($labBytes[0] -eq 10) -or ($labBytes[0] -eq 192 -and $labBytes[1] -eq 168) -or ($labBytes[0] -eq 172 -and $labBytes[1] -ge 16 -and $labBytes[1] -le 31))){throw 'Explicit private LAN addresses required'}
 return ([ulong]$labBytes[0]*16777216+[ulong]$labBytes[1]*65536+[ulong]$labBytes[2]*256+$labBytes[3])
}
$labLanArgs=''
if($labCross){$labHostIp=Convert-LabAddress $WindowsAddress;$labPhoneIp=Convert-LabAddress $AndroidAddress;$labLanArgs=" --lan=1 --address=$labPhoneIp --seed=$labHostIp"}
function Invoke-LabAdb([string[]]$Arguments){
 $labResult=& $Adb -s $Serial @Arguments 2>&1
 if($LASTEXITCODE -ne 0){throw "ADB failed: $($labResult -join ' ')"}
 return $labResult
}
function Invoke-LabShell([string]$Command){Invoke-LabAdb @('shell',$Command)}
function Set-LabCommand([int]$Id,[byte]$Value){
 $labCommand=Join-Path $labOut "command-$Id.bin"
 [IO.File]::WriteAllBytes($labCommand,[byte[]]@($Value))
 if($labCross -and $Id -lt 2){
  $labDestination=Join-Path $labOut "node-$Id/command.bin"
  [IO.File]::WriteAllBytes("$labDestination.pending",[byte[]]@($Value))
  Move-Item -LiteralPath "$labDestination.pending" -Destination $labDestination -Force
  return
 }
 $null=Invoke-LabAdb @('push',$labCommand,"$labRemote/node-$Id/command.pending")
 $null=Invoke-LabShell "mv $labRemote/node-$Id/command.pending $labRemote/node-$Id/command.bin"
}
function Start-LabPeer([int]$Id,[int]$Epoch,[int]$Create,[string]$Tag){
 if($labCross -and $Id -lt 2){
  $labWindows[$Id]=Start-Process -FilePath (Join-Path $labRoot $WindowsBinary) -ArgumentList @("--id=$Id","--epoch=$Epoch","--create=$Create",'--seconds=600','--base=48300','--lan=1',"--address=$labHostIp","--seed=$labHostIp") -WorkingDirectory (Join-Path $labOut "node-$Id") -WindowStyle Hidden -RedirectStandardError (Join-Path $labOut "$Tag.log") -RedirectStandardOutput (Join-Path $labOut "$Tag.out.log") -PassThru
  return
 }
 # Epochs are explicit and increasing within this fresh, uniquely named fixture.
 $labLaunch='cd {0}/node-{1} || exit 1; nohup ../mesh-history-lab --id={1} --epoch={2} --create={3} --seconds=600 --base=48300 > {0}/{4}.log 2>&1 < /dev/null & echo $!'
 $labPidText=Invoke-LabShell (($labLaunch -f $labRemote,$Id,$Epoch,$Create,$Tag).Replace(" --seconds=600", "$labLanArgs --seconds=600"))
 $labCandidates=@($labPidText | Where-Object {$_ -match '^\d+$'})
 if($labCandidates.Count -ne 1){throw "Expected one owned process for node $Id; got $($labPidText -join ',')"}
 $labPids[$Id]=[int]$labCandidates[0]
}
function Stop-LabPeer([int]$Id){
 if($labWindows.ContainsKey($Id)){
  $labProcess=$labWindows[$Id];$labProcess.Refresh()
  if(!$labProcess.HasExited){Stop-Process -Id $labProcess.Id;$labProcess.WaitForExit()}
  $labWindows.Remove($Id)
 }
 if($labPids.ContainsKey($Id)){
  $labPid=$labPids[$Id]
  $null=Invoke-LabShell "if [ `"`$(readlink /proc/$labPid/cwd)`" = `"$labRemote/node-$Id`" ]; then kill -9 $labPid; fi"
  $labPids.Remove($Id)
 }
}
function Wait-LabViews([string[]]$Tags,[string]$Values,[bool]$RequireLinks=$false){
 $labDeadline=[DateTime]::UtcNow.AddSeconds(45)
 do{
  $labReady=$true
  foreach($labTag in $Tags){
   $labTagId=[int]([regex]::Match($labTag,'node-(\d)').Groups[1].Value)
   if($labCross -and $labTagId -lt 2){
    $labProcess=$labWindows[$labTagId];$labProcess.Refresh();if($labProcess.HasExited){throw "Windows peer $labTagId exited; inspect its log"}
    $labLog=Get-Content -LiteralPath (Join-Path $labOut "$labTag.log") -Raw -ErrorAction SilentlyContinue
   }else{
    $labLog=(Invoke-LabShell "cat $labRemote/$labTag.log") -join "`n"
    $labLog | Set-Content -LiteralPath (Join-Path $labOut "$labTag.log") -Encoding utf8NoBOM
   }
   if([string]::IsNullOrEmpty($labLog)){$labReady=$false;continue}
   $labPattern=if($RequireLinks){"HISTORY view .*links=[1-4] .*values=$([regex]::Escape($Values)) "}else{"values=$([regex]::Escape($Values)) "}
   if($labLog -notmatch $labPattern){$labReady=$false}
  }
  if($labReady){return}
  Start-Sleep -Milliseconds 250
 }while([DateTime]::UtcNow -lt $labDeadline)
 throw "Android peers did not reach $Values; inspect preserved logs"
}
function Verify-LabPhase([string]$Tag,[string]$Values){
 $labDeadline=[DateTime]::UtcNow.AddSeconds(30)
 do{
  foreach($labId in 0..3){
   $labDir=Join-Path $labOut "node-$labId"
   New-Item -ItemType Directory -Path $labDir -Force | Out-Null
   if($labCross -and $labId -lt 2){continue}
   $null=Invoke-LabAdb @('pull',"$labRemote/node-$labId/node-history.bin",(Join-Path $labDir 'node-history.bin'))
  }
  $labProof=& node (Join-Path $PSScriptRoot 'verify-mesh-history.mjs') $labOut $Tag $Values 2>&1
  if($LASTEXITCODE -eq 0){$labProof;return}
  Start-Sleep -Milliseconds 250
 }while([DateTime]::UtcNow -lt $labDeadline)
 throw "Independent Android journal verification failed: $labProof"
}
try{
 $labEmulator=((Invoke-LabShell 'getprop ro.kernel.qemu') -join '').Trim() -eq '1'
 $null=Invoke-LabShell "test ! -e $labRemote && mkdir $labRemote"
 $labBinary=Join-Path $labRoot $AndroidBinary
 $labBinaryHash=(Get-FileHash -LiteralPath $labBinary -Algorithm SHA256).Hash.ToLowerInvariant()
 $labWindowsHash=if($labCross){(Get-FileHash -LiteralPath (Join-Path $labRoot $WindowsBinary) -Algorithm SHA256).Hash.ToLowerInvariant()}else{$null}
 $null=Invoke-LabAdb @('push',$labBinary,"$labRemote/mesh-history-lab")
 $null=Invoke-LabShell "chmod 700 $labRemote/mesh-history-lab"
 foreach($labId in 0..3){
  New-Item -ItemType Directory -Path (Join-Path $labOut "node-$labId") -Force | Out-Null
  if(!$labCross -or $labId -ge 2){$null=Invoke-LabShell "mkdir $labRemote/node-$labId"}
  Set-LabCommand $labId 4;Start-LabPeer $labId 1 1 "node-$labId"
 }
 Wait-LabViews @('node-0','node-1','node-2','node-3') '4,4,4,4'
 Verify-LabPhase 'baseline' '4,4,4,4'
 Stop-LabPeer 0
 $labOffline=[DateTime]::UtcNow
 foreach($labId in 1..3){Set-LabCommand $labId 12}
 Wait-LabViews @('node-1','node-2','node-3') '4,12,12,12'
 while(([DateTime]::UtcNow-$labOffline).TotalSeconds -lt 40){Start-Sleep -Milliseconds 250}
 Start-LabPeer 0 2 0 'node-0-restarted'
 Wait-LabViews @('node-0-restarted','node-1','node-2','node-3') '4,12,12,12'
 Verify-LabPhase 'long-outage' '4,12,12,12'
 $labRecovery=Get-Content -LiteralPath (Join-Path $labOut 'node-0-restarted.log') -Raw
 if($labRecovery -notmatch 'own-cursor=4' -or $labRecovery -notmatch 'snapshots=[1-9]'){throw 'Missing snapshot and persistent cursor recovery evidence'}
 Set-LabCommand 0 12
 Wait-LabViews @('node-0-restarted','node-1','node-2','node-3') '12,12,12,12'
 Verify-LabPhase 'converged' '12,12,12,12'
 Stop-LabPeer 2
 Start-LabPeer 2 2 0 'node-2-restarted'
 Wait-LabViews @('node-2-restarted') '12,12,12,12' $true
 if((Get-Content -LiteralPath (Join-Path $labOut 'node-2-restarted.log') -Raw) -notmatch 'own-cursor=12'){throw 'Second restart did not load its committed cursor'}
 Verify-LabPhase 'restarted-again' '12,12,12,12'
 $labReport=@{pass=$true;serial=$Serial;session=$Session;date=(Get-Date -Format yyyy-MM-dd);participants=4;outageSeconds=40;androidDeviceTested=$true;physicalDevice=(!$labEmulator);arm64Sha256=$labBinaryHash;windowsSha256=$labWindowsHash;signedSnapshotRecovery=$true;secondRestartAuthenticated=$true;solanaSettlement=$false;crossDevice=$labCross;windowsAddress=$WindowsAddress;androidAddress=$AndroidAddress;scope='headless native infrastructure; app lifecycle and Solana settlement are not exercised'}
 $labReport | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $labOut 'report.json') -Encoding utf8NoBOM
 $labReport | ConvertTo-Json
}finally{
 foreach($labId in @($labPids.Keys)+@($labWindows.Keys)){Stop-LabPeer $labId}
}
