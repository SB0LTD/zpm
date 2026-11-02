# Run the quantized-kernel tests and the LFM3 contract on emulated AArch64
# (QEMU `virt`, -cpu max) built for the Surface Laptop's Snapdragon X
# features, from an x86 Windows host. runner.sig is the bare-metal test
# runner; each suite prints its tests and the script fails on the first
# suite that does not pass.
#
#   tools/aarch64_qemu/run.ps1 [-Optimize Debug] [-Cpu <mcpu>] [-HostRunner]
#
# -HostRunner also builds tools/lfm3_run.sig for Windows on ARM
# (sig-out/aarch64/lfm3-run.exe) to benchmark on the Surface itself.
# Needs sig on PATH (or $env:SIG) and QEMU's qemu-system-aarch64 on PATH,
# in C:\Program Files\qemu, or in $env:QEMU.

param(
    [ValidateSet("Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall")]
    [string]$Optimize = "ReleaseFast",
    [string]$Cpu = "generic+v8_6a+dotprod+i8mm+bf16+fullfp16",
    [switch]$HostRunner
)

$ErrorActionPreference = "Stop"
$repo = Resolve-Path (Join-Path $PSScriptRoot "../..")
Push-Location $repo
try {
    $sig = if ($env:SIG) { $env:SIG } else { (Get-Command sig).Source }
    $qemu = if ($env:QEMU) { $env:QEMU }
        elseif (Get-Command qemu-system-aarch64 -ErrorAction SilentlyContinue) { (Get-Command qemu-system-aarch64).Source }
        else { "C:\Program Files\qemu\qemu-system-aarch64.exe" }
    $lib = (& $sig env | Select-String '\.lib_dir = "(.*)"').Matches[0].Groups[1].Value -replace '\\\\', '\'
    $out = Join-Path $repo "sig-out/aarch64"
    New-Item -ItemType Directory -Force $out | Out-Null

    # Module name -> source and imports, as wired in build.sig.
    $modules = [ordered]@{
        sig_math         = @("src/core/sig_math.sig")
        sig_mem          = @("src/core/sig_mem.sig")
        gguf             = @("src/core/gguf.sig", "sig_math", "sig_mem")
        lfm3_plan        = @("src/core/lfm3_plan.sig", "sig_math", "sig_mem", "gguf")
        quantized_linear = @("src/core/quantized_linear.sig")
        transformer_ops  = @("src/core/transformer_ops.sig", "sig_math")
        lfm3_executor    = @("src/core/lfm3_executor.sig", "sig_math", "gguf", "lfm3_plan", "quantized_linear", "transformer_ops")
        tokenizer_index  = @("src/core/tokenizer_index.sig", "gguf", "sig_math", "sig_mem")
        tokenizer        = @("src/core/tokenizer.sig", "sig_math", "sig_mem", "gguf", "tokenizer_index")
        unicode_class    = @("src/core/unicode_class.sig")
        lfm3_tokenizer   = @("src/core/lfm3_tokenizer.sig", "sig_mem", "gguf", "tokenizer", "unicode_class")
        worker_thread    = @("src/platform/worker_thread.sig")
        sig_process      = @("$lib/sig/process.sig")
    }

    # sig arguments for a root file and its imports, transitively.
    function Module-Arguments([string]$Root, [string[]]$Imports) {
        $needed = [System.Collections.Generic.HashSet[string]]::new()
        $pending = [System.Collections.Generic.Stack[string]]::new()
        foreach ($name in $Imports) { $pending.Push($name) }
        while ($pending.Count -gt 0) {
            $name = $pending.Pop()
            if ($needed.Add($name)) { $modules[$name] | Select-Object -Skip 1 | ForEach-Object { $pending.Push($_) } }
        }
        $arguments = @($Imports | ForEach-Object { "--dep", $_ }) + "-Mroot=$Root"
        foreach ($name in $modules.Keys) {
            if (-not $needed.Contains($name)) { continue }
            $arguments += @($modules[$name] | Select-Object -Skip 1 | ForEach-Object { "--dep", $_ }) + "-M$name=$($modules[$name][0])"
        }
        return $arguments
    }

    $suites = @(
        @{ Name = "quantized_linear"; Root = "src/core/quantized_linear.sig"; Imports = @() },
        @{ Name = "lfm3"; Root = "tests/test_lfm3.sig"; Imports = @("gguf", "lfm3_plan", "lfm3_executor", "lfm3_tokenizer", "quantized_linear") }
    )
    foreach ($suite in $suites) {
        $elf = Join-Path $out "$($suite.Name)-tests.elf"
        Write-Host "`n=== $($suite.Name) ($Optimize, $Cpu) ===" -ForegroundColor Cyan
        & $sig test -target aarch64-freestanding-none "-mcpu=$Cpu" -O $Optimize @(Module-Arguments $suite.Root $suite.Imports) `
            --test-runner tools/aarch64_qemu/runner.sig --test-no-exec "-femit-bin=$elf" --image-base 0x40080000
        if ($LASTEXITCODE -ne 0) { throw "$($suite.Name): build failed" }
        & $qemu -M virt -cpu max -m 1G -nographic -semihosting -kernel $elf
        if ($LASTEXITCODE -ne 0) { throw "$($suite.Name): failed on AArch64 (exit $LASTEXITCODE)" }
    }

    if ($HostRunner) {
        $exe = Join-Path $out "lfm3-run.exe"
        $imports = @("sig_process", "gguf", "lfm3_plan", "lfm3_executor", "lfm3_tokenizer", "tokenizer_index", "worker_thread")
        & $sig build-exe -target aarch64-windows "-mcpu=$Cpu" -O $Optimize @(Module-Arguments "tools/lfm3_run.sig" $imports) "-femit-bin=$exe"
        if ($LASTEXITCODE -ne 0) { throw "lfm3-run: build failed" }
        Write-Host "`nWindows on ARM runner: $exe"
    }
    Write-Host "`nAll AArch64 suites passed." -ForegroundColor Green
} finally {
    Pop-Location
}
