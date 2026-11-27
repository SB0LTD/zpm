param([string]$Source='src/mesh_lab.sig',[string]$Output='sig-out/bin/mesh-lab.exe',[string]$Target)
$ErrorActionPreference='Stop'
$meshRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$meshPlatform=if($Target -match 'linux'){'src/transport/linux_platform.sig'}else{'src/platform/win32.sig'}
$meshModules=[ordered]@{
 mesh_overlay='src/core/mesh_overlay.sig';mesh_network='src/transport/mesh_network.sig';mesh_transport='src/transport/mesh_transport.sig';
 mesh_history='src/core/mesh_history.sig';mesh_sync='src/core/mesh_sync.sig';mesh_file='src/platform/mesh_file.sig';fixed_journal='src/platform/fixed_journal.sig';mesh_test_records='tests/mesh_test_records.sig';mesh_lab_support='src/mesh_lab_support.sig';
 conn='src/transport/conn.sig';streams='src/transport/streams.sig';datagram='src/transport/datagram.sig';packet='src/transport/packet.sig';
 recovery='src/transport/recovery.sig';transport_crypto='src/transport/crypto.sig';crypto='src/platform/crypto.sig';
 tls13='src/transport/tls13.sig';telemetry='src/transport/telemetry.sig';udp='src/transport/udp.sig';crypto_stream='src/transport/crypto_stream.sig';win32=$meshPlatform
}
$meshDeps=@{
 mesh_sync=@('mesh_history');mesh_file=@('fixed_journal');fixed_journal=@('win32');mesh_test_records=@('mesh_history');mesh_lab_support=@('win32');
 mesh_network=@('mesh_overlay','mesh_transport','conn','streams','udp','win32');mesh_transport=@('conn','streams','datagram','packet','win32');
 conn=@('win32','packet','transport_crypto','recovery','streams','datagram','telemetry','udp','crypto_stream');streams=@('packet');
 datagram=@('packet');recovery=@('packet');transport_crypto=@('win32','packet','crypto','tls13');crypto=@('win32');udp=@('win32')
}
$meshArgs=@('build-exe','-j1','-O','ReleaseSafe',"-femit-bin=$([IO.Path]::GetFullPath((Join-Path $meshRoot $Output)))")
if($Target){$meshArgs+=@('-target',$Target)}
foreach($meshName in $meshModules.Keys){$meshArgs+=@('--dep',$meshName)}
$meshArgs+="-Mroot=$meshRoot/$Source"
foreach($meshName in $meshModules.Keys){foreach($meshDep in $meshDeps[$meshName]){$meshArgs+=@('--dep',$meshDep)};$meshArgs+="-M${meshName}=$meshRoot/$($meshModules[$meshName])"}
& sig @meshArgs
if($LASTEXITCODE -ne 0){throw 'Mesh lab compilation failed'}
