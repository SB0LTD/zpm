param([ValidatePattern('^[a-z0-9-]{1,48}$')][string]$Session=('history-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),[ValidateRange(1024,65000)][int]$BasePort=47300,[ValidateRange(35,60)][int]$OutageSeconds=40)
$ErrorActionPreference='Stop'
$historyRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$historyOut=Join-Path $historyRoot "sig-out/mesh-history/$Session"
if(Test-Path -LiteralPath $historyOut){throw 'Choose a fresh session to preserve existing journals and evidence'}
New-Item -ItemType Directory -Path $historyOut -Force | Out-Null
$historyExe=Join-Path $historyRoot 'sig-out/bin/mesh-history-lab.exe'
$historyProcesses=@{}
function Set-HistoryCommand([int]$Identity,[byte]$Value){
 $historyCommand=Join-Path $historyOut "node-$Identity/command.bin"
 [IO.File]::WriteAllBytes("$historyCommand.pending",[byte[]]@($Value))
 Move-Item -LiteralPath "$historyCommand.pending" -Destination $historyCommand -Force
}
function Start-HistoryParticipant([int]$Identity,[int]$Epoch,[bool]$Create,[string]$Tag){
 $historyWork=Join-Path $historyOut "node-$Identity"
 New-Item -ItemType Directory -Path $historyWork -Force | Out-Null
 $historyEpochPath=Join-Path $historyWork 'epoch.txt';$historyPrevious=if(Test-Path -LiteralPath $historyEpochPath){[ulong](Get-Content -LiteralPath $historyEpochPath -Raw)}else{0}
 if($Epoch -le $historyPrevious){throw 'Incarnation must increase'}
 $historyFile=[IO.File]::Open("$historyEpochPath.pending",[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$historyBytes=[Text.Encoding]::UTF8.GetBytes([string]$Epoch);$historyFile.Write($historyBytes,0,$historyBytes.Length);$historyFile.Flush($true)}finally{$historyFile.Dispose()}
 Move-Item -LiteralPath "$historyEpochPath.pending" -Destination $historyEpochPath -Force
 $historyProcess=Start-Process -FilePath $historyExe -ArgumentList @("--id=$Identity","--epoch=$Epoch","--base=$BasePort",'--seconds=180',"--create=$([int]$Create)") -WorkingDirectory $historyWork -WindowStyle Hidden -RedirectStandardOutput (Join-Path $historyOut "$Tag.out.log") -RedirectStandardError (Join-Path $historyOut "$Tag.log") -PassThru
 $historyProcesses[$Identity]=$historyProcess;return $historyProcess
}
function Wait-HistoryViews([int[]]$Identities,[string[]]$Tags,[string]$Values,[int]$Seconds=30){
 if($Identities.Count -eq 0 -or $Identities.Count -ne $Tags.Count){throw 'Invalid convergence wait targets'}
 Write-Output "Waiting for durable values $Values on nodes $($Identities -join ',')"
 $historyDeadline=[DateTime]::UtcNow.AddSeconds($Seconds)
 do{
  $historyReady=$true
  for($historyIndex=0;$historyIndex -lt $Identities.Count;$historyIndex++){
   $historyIdentity=$Identities[$historyIndex];$historyProcesses[$historyIdentity].Refresh()
   if($historyProcesses[$historyIdentity].HasExited){throw "Participant $historyIdentity exited unexpectedly; inspect its log"}
   $historyLog=Get-Content -LiteralPath (Join-Path $historyOut "$($Tags[$historyIndex]).log") -Raw -ErrorAction SilentlyContinue
   if([string]::IsNullOrEmpty($historyLog) -or ![regex]::IsMatch($historyLog,"values=$([regex]::Escape($Values)) ")){$historyReady=$false}
  }
  if(!$historyReady){Start-Sleep -Milliseconds 100}
 }while(!$historyReady -and [DateTime]::UtcNow -lt $historyDeadline)
 if(!$historyReady){throw "Replicas did not reach $Values before the deadline"}
}
function Verify-HistoryPhase([string]$Tag,[string]$Values){
 $historyProofDeadline=[DateTime]::UtcNow.AddSeconds(30)
 do{
  $historyProof=& node (Join-Path $PSScriptRoot 'verify-mesh-history.mjs') $historyOut $Tag $Values 2>&1
  $historyProofExit=$LASTEXITCODE
  if($historyProofExit -eq 0){$historyProof;return}
  Start-Sleep -Milliseconds 200
 }while([DateTime]::UtcNow -lt $historyProofDeadline)
 $historyProof | Select-Object -Last 12
 throw "Independent persisted-state verification failed: $Tag"
}
try{
 foreach($historyIdentity in 0..3){New-Item -ItemType Directory -Path (Join-Path $historyOut "node-$historyIdentity") -Force | Out-Null;Set-HistoryCommand $historyIdentity 4;$null=Start-HistoryParticipant $historyIdentity 1 $true "node-$historyIdentity"}
 Wait-HistoryViews @(0,1,2,3) @('node-0','node-1','node-2','node-3') '4,4,4,4'
 Verify-HistoryPhase 'baseline' '4,4,4,4'
 $historyVictim=$historyProcesses[0];Stop-Process -Id $historyVictim.Id;$historyVictim.WaitForExit();$historyStopped=[DateTime]::UtcNow
 foreach($historyIdentity in 1..3){Set-HistoryCommand $historyIdentity 12}
 Wait-HistoryViews @(1,2,3) @('node-1','node-2','node-3') '4,12,12,12'
 while(([DateTime]::UtcNow-$historyStopped).TotalSeconds -lt $OutageSeconds){Start-Sleep -Milliseconds 200}
 $historyRestart=Start-HistoryParticipant 0 2 $false 'node-0-restarted'
 Wait-HistoryViews @(0,1,2,3) @('node-0-restarted','node-1','node-2','node-3') '4,12,12,12'
 Verify-HistoryPhase 'long-outage' '4,12,12,12'
 $historyRecoveryLog=Get-Content -LiteralPath (Join-Path $historyOut 'node-0-restarted.log') -Raw
 if($historyRecoveryLog -notmatch 'own-cursor=4' -or $historyRecoveryLog -notmatch 'snapshots=[1-9]'){throw 'Missing durable cursor or snapshot recovery evidence'}
 Set-HistoryCommand 0 12
 Wait-HistoryViews @(0,1,2,3) @('node-0-restarted','node-1','node-2','node-3') '12,12,12,12'
 Verify-HistoryPhase 'converged' '12,12,12,12'
 $historySecond=$historyProcesses[2];Stop-Process -Id $historySecond.Id;$historySecond.WaitForExit();$null=Start-HistoryParticipant 2 2 $false 'node-2-restarted'
 Wait-HistoryViews @(2) @('node-2-restarted') '12,12,12,12'
 $historyLinkDeadline=[DateTime]::UtcNow.AddSeconds(30)
 do{
  $historySecondLog=Get-Content -LiteralPath (Join-Path $historyOut 'node-2-restarted.log') -Raw
  $historyLinked=![string]::IsNullOrEmpty($historySecondLog) -and $historySecondLog -match 'HISTORY view id=2 links=[1-4] .*values=12,12,12,12 '
  if(!$historyLinked){Start-Sleep -Milliseconds 100}
 }while(!$historyLinked -and [DateTime]::UtcNow -lt $historyLinkDeadline)
 if(!$historyLinked -or $historySecondLog -notmatch 'own-cursor=12'){throw 'Second restart did not recover its cursor and authenticate a peer'}
 Verify-HistoryPhase 'restarted-again' '12,12,12,12'
 $historyReport=@{pass=$true;session=$Session;participants=4;outageSeconds=$OutageSeconds;transportCacheLeaseSeconds=30;retainedEventsPerStream=4;bootstrapForceKilled=$true;restartedPid=$historyRestart.Id;recoveryUsedSignedSnapshots=$true;persistentCursorsRecovered=$true;independentReports=@('baseline-report.json','long-outage-report.json','converged-report.json','restarted-again-report.json');authority='synthetic single-writer counters only'}
 $historyReport | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $historyOut 'report.json') -Encoding utf8NoBOM
 $historyReport | ConvertTo-Json -Depth 5
}finally{
 foreach($historyProcess in $historyProcesses.Values){$historyProcess.Refresh();if(!$historyProcess.HasExited){Stop-Process -Id $historyProcess.Id}}
}
