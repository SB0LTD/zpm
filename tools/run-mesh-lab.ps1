param([ValidatePattern('^[a-z0-9-]{1,48}$')][string]$Session=('mesh-'+(Get-Date -Format 'yyyyMMdd-HHmmss')),[ValidateRange(1024,65000)][int]$BasePort=47200,[ValidateRange(0,3)][int]$Victim=0)
$ErrorActionPreference='Stop'
$meshRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$meshOut=Join-Path $meshRoot "sig-out/mesh-lab/$Session"
if(Test-Path -LiteralPath (Join-Path $meshOut 'report.json')){throw 'Session already has a report; choose a fresh session to preserve evidence'}
New-Item -ItemType Directory -Path $meshOut -Force | Out-Null
$meshExe=Join-Path $meshRoot 'sig-out/bin/mesh-lab.exe'
$meshProcesses=@{}
function Start-MeshParticipant([int]$Identity,[string]$Tag){
 $meshCounterPath=Join-Path $meshOut "epoch-$Identity.txt"
 $meshEpoch=if(Test-Path -LiteralPath $meshCounterPath){1+[ulong](Get-Content -LiteralPath $meshCounterPath -Raw)}else{1}
 $meshCounterTemp="$meshCounterPath.pending"
 $meshStream=[IO.File]::Open($meshCounterTemp,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
 try{$meshBytes=[Text.Encoding]::UTF8.GetBytes([string]$meshEpoch);$meshStream.Write($meshBytes,0,$meshBytes.Length);$meshStream.Flush($true)}finally{$meshStream.Dispose()}
 Move-Item -LiteralPath $meshCounterTemp -Destination $meshCounterPath -Force
 $meshProcess=Start-Process -FilePath $meshExe -ArgumentList @("--id=$Identity","--epoch=$meshEpoch","--base=$BasePort",'--count=4','--seconds=30') -WorkingDirectory $meshRoot -WindowStyle Hidden -RedirectStandardOutput (Join-Path $meshOut "$Tag.out.log") -RedirectStandardError (Join-Path $meshOut "$Tag.log") -PassThru
 $meshProcesses[$Identity]=$meshProcess
 return $meshProcess
}
try{
 foreach($meshIdentity in 0..3){$null=Start-MeshParticipant $meshIdentity "node-$meshIdentity"}
 $meshConnectDeadline=[DateTime]::UtcNow.AddSeconds(15)
 do{
  $meshReady=$true
  foreach($meshIdentity in 0..3){if((Get-Content -LiteralPath (Join-Path $meshOut "node-$meshIdentity.log") -Raw) -notmatch 'known=true'){$meshReady=$false}}
  if(!$meshReady){Start-Sleep -Milliseconds 100}
 }while(!$meshReady -and [DateTime]::UtcNow -lt $meshConnectDeadline)
 if(!$meshReady){throw 'Participants did not converge before the crash test'}
 Start-Sleep -Seconds 8
 $meshVictim=$meshProcesses[$Victim]
 Stop-Process -Id $meshVictim.Id
 $meshVictim.WaitForExit()
 $meshCrashAt=[DateTime]::UtcNow.ToString('o')
 # Keep the other independent processes running through liveness expiry.
 Start-Sleep -Seconds 7
 $meshPartial=[byte[]]::new(32);foreach($meshIdentity in 0..3){$meshPartial[$meshIdentity*8]=if($meshIdentity -eq $Victim){2}else{3}}
 $meshPartialHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($meshPartial)).ToLowerInvariant()
 foreach($meshIdentity in 0..3){if($meshIdentity -ne $Victim){
  $meshSurvivorLog=Get-Content -LiteralPath (Join-Path $meshOut "node-$meshIdentity.log") -Raw
  if($meshSurvivorLog -notmatch "state=$meshPartialHash"){throw "Survivor $meshIdentity did not progress while node $Victim was down"}
 }}
 $meshRestart=Start-MeshParticipant $Victim "node-$Victim-restarted"
 $meshDeadline=[DateTime]::UtcNow.AddSeconds(40)
 do{
  $meshFinished=$true
  foreach($meshProcess in $meshProcesses.Values){$meshProcess.Refresh();if(!$meshProcess.HasExited){$meshFinished=$false}}
  if(!$meshFinished){Start-Sleep -Milliseconds 100}
 }while(!$meshFinished -and [DateTime]::UtcNow -lt $meshDeadline)
 if(!$meshFinished){throw 'Mesh lab exceeded its bounded runtime'}
 $meshViews=@()
 foreach($meshIdentity in 0..3){
  $meshProcess=$meshProcesses[$meshIdentity];$meshProcess.WaitForExit()
  if($meshProcess.ExitCode -ne 0){throw "Participant $meshIdentity failed: $($meshProcess.ExitCode)"}
  $meshTag=if($meshIdentity -eq $Victim){"node-$Victim-restarted"}else{"node-$meshIdentity"}
  $meshLog=Get-Content -LiteralPath (Join-Path $meshOut "$meshTag.log") -Raw
  if($meshLog -notmatch 'LAB end id=\d+ complete=true'){throw "Incomplete participant $meshIdentity"}
  $meshMatches=[regex]::Matches($meshLog,'LAB view id=\d+ links=\d+ elapsed=\d+ known=true complete=true state=([0-9a-f]{64})')
  if($meshMatches.Count -eq 0){throw 'Missing final synthetic state hash'}
  $meshViews+=@{id=$meshIdentity;pid=$meshProcess.Id;hash=$meshMatches[$meshMatches.Count-1].Groups[1].Value;log="$meshTag.log"}
 }
 $meshCanonical=[byte[]]::new(32);foreach($meshIdentity in 0..3){$meshCanonical[$meshIdentity*8]=3}
 $meshHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($meshCanonical)).ToLowerInvariant()
 foreach($meshView in $meshViews){if($meshView.hash -ne $meshHash){throw 'Synthetic replicas did not match the independent canonical hash'}}
 $meshReport=@{pass=$true;session=$Session;participants=4;transport='real loopback UDP/QUIC/TLS + pinned Ed25519 session authentication';forcedCrash=$true;crashedIdentity=$Victim;bootstrapStopped=($Victim -eq 0);survivorProgressHash=$meshPartialHash;crashAt=$meshCrashAt;restartedPid=$meshRestart.Id;stateHash=$meshHash;views=$meshViews;authority='synthetic idempotent records only; no game or Solana settlement'}
 $meshReport | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $meshOut 'report.json') -Encoding utf8NoBOM
 $meshReport | ConvertTo-Json -Depth 6
}finally{
 foreach($meshProcess in $meshProcesses.Values){$meshProcess.Refresh();if(!$meshProcess.HasExited){Stop-Process -Id $meshProcess.Id}}
}
