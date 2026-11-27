# Build all executable code with Sig. PowerShell only orchestrates compilation.
param([string]$Compiler = 'sig', [string]$Objcopy = 'llvm-objcopy')
$ErrorActionPreference = 'Stop'
$taskRepo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$taskOutput = Join-Path $taskRepo '.build/slowwire'
New-Item -ItemType Directory -Force $taskOutput | Out-Null
function Invoke-Checked([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program exited $LASTEXITCODE" }
}
Push-Location $taskRepo
try {
    Invoke-Checked $Compiler @('test','slowwire_tests.sig')
    Invoke-Checked $Compiler @('test','opencr_tests.sig')
    Invoke-Checked $Compiler @('build-exe','-OReleaseSmall','-target','thumb-freestanding-eabi','-mcpu','cortex_m0plus','-fno-entry',"-femit-bin=$taskOutput/boot2.elf",'-T','examples/slowwire/boot2.ld','examples/slowwire/boot2.sig')
    Invoke-Checked $Compiler @('build-exe','-OReleaseSmall','-target','thumb-freestanding-eabi','-mcpu','cortex_m0plus','-fno-entry',"-femit-bin=$taskOutput/firmware.elf",'-T','examples/slowwire/flash.ld','--dep','zpm_slowwire','-Mroot=examples/slowwire/main.sig','-Mzpm_slowwire=slowwire.sig')
    Invoke-Checked $Compiler @('build-exe','-OReleaseSmall','-target','thumb-freestanding-eabi','-mcpu','cortex_m0plus','-fno-entry',"-femit-bin=$taskOutput/openrb.elf",'-T','examples/slowwire/openrb.ld','--dep','zpm_slowwire','-Mroot=examples/slowwire/openrb.sig','-Mzpm_slowwire=slowwire.sig')
    Invoke-Checked $Compiler @('build-exe','-OReleaseSmall','-target','thumb-freestanding-eabi','-mcpu','cortex_m7','-fno-entry',"-femit-bin=$taskOutput/opencr.elf",'-T','examples/slowwire/opencr.ld','--dep','zpm_slowwire','-Mroot=examples/slowwire/opencr.sig','-Mzpm_slowwire=slowwire.sig')
    Invoke-Checked $Compiler @('build-obj','-OReleaseSmall','-target','thumb-freestanding-eabi','-mcpu','cortex_m7',"-femit-bin=$taskOutput/opencr-driver-check.o",'--dep','opencr','-Mroot=examples/slowwire/opencr_driver_check.sig','-Mopencr=opencr.sig')
    foreach ($taskTool in @('uf2_pack','host')) {
        $taskName = if ($taskTool -eq 'host') { 'slowwire-host' } else { 'slowwire-uf2' }
        Invoke-Checked $Compiler @('build-exe','-OReleaseSafe','-lkernel32',"-femit-bin=$taskOutput/$taskName.exe",'--dep','zpm_slowwire',"-Mroot=examples/slowwire/$taskTool.sig",'-Mzpm_slowwire=slowwire.sig')
    }
    Invoke-Checked $Objcopy @('-O','binary',"$taskOutput/boot2.elf","$taskOutput/boot2.bin")
    Invoke-Checked $Objcopy @('-O','binary',"$taskOutput/firmware.elf","$taskOutput/firmware.bin")
    Invoke-Checked $Objcopy @('-O','binary',"$taskOutput/openrb.elf","$taskOutput/openrb.bin")
    Invoke-Checked $Objcopy @('-O','ihex',"$taskOutput/openrb.elf","$taskOutput/openrb.hex")
    Invoke-Checked $Objcopy @('-O','binary',"$taskOutput/opencr.elf","$taskOutput/opencr.bin")
    Invoke-Checked $Objcopy @('-O','ihex',"$taskOutput/opencr.elf","$taskOutput/opencr.hex")
    $taskOpencrImage = [IO.File]::ReadAllBytes("$taskOutput/opencr.bin")
    $taskOpencrReset = [BitConverter]::ToUInt32($taskOpencrImage, 4)
    if ($taskOpencrImage.Length -gt 512KB -or [BitConverter]::ToUInt32($taskOpencrImage, 0) -ne 0x20050000 -or ($taskOpencrReset -band 1) -ne 1 -or $taskOpencrReset -lt 0x08040001 -or $taskOpencrReset -ge 0x080c0000) { throw 'Invalid OpenCR application vector or reserved-sector boundary' }
    $taskImage = [IO.File]::ReadAllBytes("$taskOutput/openrb.bin")
    $taskSp = [BitConverter]::ToUInt32($taskImage, 0)
    $taskReset = [BitConverter]::ToUInt32($taskImage, 4)
    if ($taskImage.Length -gt (256KB - 8KB) -or $taskSp -ne 0x20008000 -or ($taskReset -band 1) -ne 1 -or $taskReset -lt 0x2001 -or $taskReset -ge 0x40000) { throw 'Invalid OpenRB application vector or image size' }
    Invoke-Checked "$taskOutput/slowwire-uf2.exe" @("$taskOutput/boot2.bin","$taskOutput/firmware.bin","$taskOutput/slowwire.uf2")
    Invoke-Checked "$taskOutput/slowwire-host.exe" @('--self-test')
    $taskEvidence = [ordered]@{
        compiler = (& $Compiler version | Out-String).Trim()
        core_contracts = 'PASS'
        host_self_test = 'PASS'
        firmware_cross_compile = 'PASS'
        openrb_image_vectors = 'PASS - application 0x2000, SP 0x20008000, Thumb reset within flash'
        opencr_contracts = 'PASS'
        opencr_driver_api_compile = 'PASS - Cortex-M7 coverage object; never executed'
        opencr_image_vectors = 'PASS - application 0x08040000, SP 0x20050000, sector 7 reserved'
        native_sb0_usb_host = 'PENDING - OpenRB/OpenCR need CDC ACM; U2D2 needs FTDI USB serial'
        physical_boot = 'NOT TESTED - no OpenRB/OpenCR/Pico attached'
        physical_actuation = 'NOT TESTED - no servo fixture attached'
        uf2_sha256 = (Get-FileHash "$taskOutput/slowwire.uf2" -Algorithm SHA256).Hash
        openrb_sha256 = (Get-FileHash "$taskOutput/openrb.bin" -Algorithm SHA256).Hash
        opencr_sha256 = (Get-FileHash "$taskOutput/opencr.bin" -Algorithm SHA256).Hash
        opencr_peripherals = 'NOT TESTED - USB/UART/CAN/ADC/PWM/I2C/SPI/IMU/RTC/storage hardware pending'
        u2d2_hardware = 'NOT TESTED - host compiled, no U2D2 attached'
        created_utc = [DateTime]::UtcNow.ToString('o')
    }
    $taskEvidence | ConvertTo-Json | Set-Content -Encoding utf8 "$taskOutput/validation.json"
    Write-Host "Ready for isolated Pico USB bring-up: $taskOutput/slowwire.uf2"
    Write-Host "OpenRB application (factory bootloader preserved): $taskOutput/openrb.bin"
    Write-Host "U2D2 direct host: $taskOutput/slowwire-host.exe --u2d2 COM7"
    Write-Host "OpenCR application: $taskOutput/opencr.bin; host --opencr COM7"
} finally { Pop-Location }
