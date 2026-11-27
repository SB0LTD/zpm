# ROBOTIS factory bootloader uploader; application code is full Sig.
# Hold PUSH SW2 while pressing RESET, then use its COM port. No DFU/mass erase.
param(
    [Parameter(Mandatory=$true)][string]$BootloaderPort,
    [Parameter(Mandatory=$true)][string]$Uploader,
    [string]$Image = (Join-Path $PSScriptRoot '../../.build/slowwire/opencr.bin')
)
$ErrorActionPreference = 'Stop'
if ($BootloaderPort -notmatch '^COM[1-9][0-9]*$') { throw 'Pass the OpenCR factory bootloader COM port' }
$taskImagePath = (Resolve-Path -LiteralPath $Image).Path
$taskProgram = (Resolve-Path -LiteralPath $Uploader).Path
$taskBytes = [IO.File]::ReadAllBytes($taskImagePath)
if ($taskBytes.Length -lt 64 -or $taskBytes.Length -gt 512KB) { throw 'Invalid OpenCR application size' }
$taskReset = [BitConverter]::ToUInt32($taskBytes, 4)
if ([BitConverter]::ToUInt32($taskBytes, 0) -ne 0x20050000 -or ($taskReset -band 1) -ne 1 -or $taskReset -lt 0x08040001 -or $taskReset -ge 0x080c0000) { throw 'Not an OpenCR application at 0x08040000' }
# Exact ROBOTIS platform.txt application upload recipe. It handles the firmware
# transfer/verification protocol and metadata; do not substitute a raw DFU erase.
& $taskProgram $BootloaderPort '115200' $taskImagePath '1'
if ($LASTEXITCODE -ne 0) { throw "OpenCR upload failed ($LASTEXITCODE)" }
