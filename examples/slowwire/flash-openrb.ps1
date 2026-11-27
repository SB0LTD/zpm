# Uses the ROBOTIS-supported bossac-1.7.0-arduino3 SAM-BA uploader.
# The application is full Sig; the existing factory bootloader is retained.
param(
    [Parameter(Mandatory=$true)][string]$BootloaderPort,
    [Parameter(Mandatory=$true)][string]$Bossac,
    [string]$Image = (Join-Path $PSScriptRoot '../../.build/slowwire/openrb.bin')
)
$ErrorActionPreference = 'Stop'
if ($BootloaderPort -notmatch '^COM[1-9][0-9]*$') { throw 'Pass the COM port visible after double-tapping RESET, e.g. COM8' }
$taskImagePath = (Resolve-Path -LiteralPath $Image).Path
$taskProgram = (Resolve-Path -LiteralPath $Bossac).Path
$taskBytes = [IO.File]::ReadAllBytes($taskImagePath)
if ($taskBytes.Length -lt 64 -or $taskBytes.Length -gt (256KB - 8KB)) { throw 'Application image size invalid' }
$taskReset = [BitConverter]::ToUInt32($taskBytes, 4)
if ([BitConverter]::ToUInt32($taskBytes, 0) -ne 0x20008000 -or ($taskReset -band 1) -ne 1 -or $taskReset -lt 0x2001 -or $taskReset -ge 0x40000) { throw 'Not an OpenRB image linked at 0x2000' }
# This is the exact upload recipe from ROBOTIS platform.txt. Use its supported
# uploader, whose SAMD21 monitor support applies the 8 KiB application offset.
# An arbitrary upstream bossac version may require different offset options.
& $taskProgram '--port' $BootloaderPort '-U' 'true' '-i' '-e' '-w' '-v' $taskImagePath '-R'
if ($LASTEXITCODE -ne 0) { throw "OpenRB upload/verify failed ($LASTEXITCODE)" }
