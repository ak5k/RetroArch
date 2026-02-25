# run_cli_tests.ps1 — CLI recording tests for fix/recording-hw-cores
# Runs Test 1 (vulkan), Test 2 (glcore), and Test 3 (gl2) from the test plan.

$ErrorActionPreference = "Stop"
$timeout = 60000  # ms to wait for RetroArch to exit

$core = "cores/pcsx2_libretro.dll"
$maxFrames = 300

$tests = @(
    @{ Name = "CLI vulkan"; Cfg = "vulkan.cfg"; LogPattern = "vulkan"; Renderer = "Auto" }
    @{ Name = "CLI glcore"; Cfg = "glcore.cfg"; LogPattern = "glcore"; Renderer = "Auto" }
    @{ Name = "CLI gl2";    Cfg = "gl2.cfg";    LogPattern = "gl2";    Renderer = "OpenGL" }
)

Write-Host ""

# --- Run each test ---
foreach ($i in 0..($tests.Count - 1)) {
    $t    = $tests[$i]
    $num  = $i + 1
    Write-Host "=== Test $num`: $($t.Name) ===" -ForegroundColor Yellow

    # Verify appendconfig exists
    if (-not (Test-Path $t.Cfg)) {
        Write-Host "  [SKIP] Config file '$($t.Cfg)' not found." -ForegroundColor Red
        Write-Host ""
        continue
    }

    # Clean slate: logs, dummy rec file, generated configs, shader caches
    Remove-Item logs\retroarch.log          -ErrorAction SilentlyContinue
    Remove-Item rec.mkv                     -ErrorAction SilentlyContinue
    Remove-Item retroarch.cfg               -ErrorAction SilentlyContinue
    Remove-Item config -Recurse -Force      -ErrorAction SilentlyContinue
    Remove-Item system\pcsx2\cache -Recurse -Force -ErrorAction SilentlyContinue

    # Set LRPS2 renderer for this test
    $optDir = "config\LRPS2"
    $optFile = "$optDir\LRPS2.opt"
    New-Item -ItemType Directory -Path $optDir -Force | Out-Null
    Set-Content -Path $optFile -Value "pcsx2_renderer = `"$($t.Renderer)`""

    $args = @(
        "-L", $core,
        "--appendconfig", $t.Cfg,
        "-r", "rec.mkv",
        "--max-frames=$maxFrames",
        "-v"
    )

    $p = Start-Process -FilePath ".\retroarch.exe" -ArgumentList $args -PassThru
    $exited = $p.WaitForExit($timeout)
    if (-not $exited) {
        Write-Host "  [WARN] RetroArch did not exit within $($timeout/1000)s — killing" -ForegroundColor Red
        Stop-Process -Id $p.Id -Force
    }

    # --- Analyse log ---
    $logFile = "logs\retroarch.log"
    if (Test-Path $logFile) {
        $logSize = (Get-Item $logFile).Length
        Write-Host "  Log: $logFile ($logSize bytes)"

        $errors = Select-String -Path $logFile `
            -Pattern "VK_ERROR|\[ERROR\]|BLACK" -CaseSensitive:$false |
            Where-Object { $_.Line -notmatch "IsoFS" } |
            ForEach-Object { $_.Line }

        $recLines = Select-String -Path $logFile `
            -Pattern "Recording|readback|async|gpu_record" -CaseSensitive:$false |
            ForEach-Object { $_.Line }

        if ($recLines) {
            Write-Host "  Recording-related log lines:" -ForegroundColor Gray
            $recLines | ForEach-Object { Write-Host "    $_" }
        }

        if ($errors) {
            Write-Host "  [FAIL] Errors found:" -ForegroundColor Red
            $errors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
        } else {
            Write-Host "  [OK] No errors in log." -ForegroundColor Green
        }
    } else {
        Write-Host "  [WARN] No log file found." -ForegroundColor Red
    }

    # --- Check recordings ---
    $recs = Get-ChildItem recordings\*.mkv -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
    if ($recs) {
        $latest = $recs[0]
        Write-Host "  Recording: $($latest.Name) ($([math]::Round($latest.Length/1KB, 1)) KB)"
        if ($latest.Length -lt 1024) {
            Write-Host "  [FAIL] Recording too small — likely not finalized." -ForegroundColor Red
        } else {
            Write-Host "  [PASS]" -ForegroundColor Green
        }
    } else {
        Write-Host "  [FAIL] No recording found in recordings/." -ForegroundColor Red
    }

    Write-Host ""
}

# Final cleanup — restore LRPS2 renderer to Auto
$optDir = "config\LRPS2"
$optFile = "$optDir\LRPS2.opt"
if (Test-Path $optDir) {
    Set-Content -Path $optFile -Value 'pcsx2_renderer = "Auto"'
}
Remove-Item rec.mkv       -ErrorAction SilentlyContinue
Remove-Item retroarch.cfg -ErrorAction SilentlyContinue

Write-Host "=== All CLI tests complete ===" -ForegroundColor Cyan
