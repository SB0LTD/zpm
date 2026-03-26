# Run all transport + registry tests via zig test CLI
# Workaround for zig build test exit code 148 (build runner stack overflow)

$ErrorActionPreference = "Stop"
Push-Location $PSScriptRoot

$failed = 0

function Run-Test {
    param([string]$Name, [string]$ArgString)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    $proc = Start-Process -FilePath "zig" -ArgumentList $ArgString -NoNewWindow -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        Write-Host "FAIL: $Name (exit $($proc.ExitCode))" -ForegroundColor Red
        $script:failed++
    }
}

# Layer 0: no deps
Run-Test "packet" "test src/transport/packet.zig"
Run-Test "telemetry" "test src/transport/telemetry.zig"

# Layer 1: depends on packet
Run-Test "recovery" "test --dep packet -Mroot=src/transport/recovery.zig -Mpacket=src/transport/packet.zig"
Run-Test "streams" "test --dep packet -Mroot=src/transport/streams.zig -Mpacket=src/transport/packet.zig"
Run-Test "datagram" "test --dep packet -Mroot=src/transport/datagram.zig -Mpacket=src/transport/packet.zig"
Run-Test "udp" "test --dep win32 -Mroot=src/transport/udp.zig -lws2_32 -lkernel32 -Mwin32=src/platform/win32.zig -lkernel32"

Run-Test "transport_crypto" "test --dep win32 --dep packet --dep crypto -Mroot=src/transport/crypto.zig -lbcrypt -lsecur32 -lkernel32 -Mwin32=src/platform/win32.zig -lkernel32 -Mpacket=src/transport/packet.zig --dep win32 -Mcrypto=src/platform/crypto.zig -lbcrypt -lkernel32"

Run-Test "appmap" "test --dep streams --dep datagram --dep packet -Mroot=src/transport/appmap.zig --dep packet -Mstreams=src/transport/streams.zig --dep packet -Mdatagram=src/transport/datagram.zig -Mpacket=src/transport/packet.zig"

Run-Test "conn" "test --dep win32 --dep packet --dep transport_crypto --dep recovery --dep streams --dep datagram --dep telemetry --dep udp -Mroot=src/transport/conn.zig -lws2_32 -lbcrypt -lsecur32 -lkernel32 -Mwin32=src/platform/win32.zig -lkernel32 -Mpacket=src/transport/packet.zig --dep win32 --dep packet --dep crypto -Mtransport_crypto=src/transport/crypto.zig -lbcrypt -lsecur32 -lkernel32 --dep win32 -Mcrypto=src/platform/crypto.zig -lbcrypt -lkernel32 --dep packet -Mrecovery=src/transport/recovery.zig --dep packet -Mstreams=src/transport/streams.zig --dep packet -Mdatagram=src/transport/datagram.zig -Mtelemetry=src/transport/telemetry.zig --dep win32 -Mudp=src/transport/udp.zig -lws2_32 -lkernel32"

Run-Test "scheduler" "test --dep win32 --dep packet --dep streams --dep datagram --dep recovery --dep transport_crypto --dep udp --dep telemetry -Mroot=src/transport/scheduler.zig -lkernel32 -lws2_32 -lbcrypt -lsecur32 -Mwin32=src/platform/win32.zig -lkernel32 -Mpacket=src/transport/packet.zig --dep packet -Mstreams=src/transport/streams.zig --dep packet -Mdatagram=src/transport/datagram.zig --dep packet -Mrecovery=src/transport/recovery.zig --dep win32 --dep packet --dep crypto -Mtransport_crypto=src/transport/crypto.zig -lbcrypt -lsecur32 -lkernel32 --dep win32 -Mcrypto=src/platform/crypto.zig -lbcrypt -lkernel32 --dep win32 -Mudp=src/transport/udp.zig -lws2_32 -lkernel32 -Mtelemetry=src/transport/telemetry.zig"

Run-Test "registry" "test --dep conn --dep appmap --dep streams --dep datagram --dep win32 -Mroot=src/pkg/registry.zig -lws2_32 -lbcrypt -lsecur32 -lkernel32 --dep win32 --dep packet --dep transport_crypto --dep recovery --dep streams --dep datagram --dep telemetry --dep udp -Mconn=src/transport/conn.zig -lws2_32 -lbcrypt -lsecur32 -lkernel32 --dep streams --dep datagram --dep packet -Mappmap=src/transport/appmap.zig --dep packet -Mstreams=src/transport/streams.zig --dep packet -Mdatagram=src/transport/datagram.zig -Mpacket=src/transport/packet.zig -Mwin32=src/platform/win32.zig -lkernel32 --dep win32 --dep packet --dep crypto -Mtransport_crypto=src/transport/crypto.zig -lbcrypt -lsecur32 -lkernel32 --dep win32 -Mcrypto=src/platform/crypto.zig -lbcrypt -lkernel32 --dep packet -Mrecovery=src/transport/recovery.zig -Mtelemetry=src/transport/telemetry.zig --dep win32 -Mudp=src/transport/udp.zig -lws2_32 -lkernel32"

if ($failed -gt 0) {
    Write-Host "`n=== $failed module(s) FAILED ===" -ForegroundColor Red
    Pop-Location
    exit 1
}

Write-Host "`n=== All tests passed! ===" -ForegroundColor Green
Pop-Location
