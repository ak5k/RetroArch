# run_ui_tests.ps1 — UI recording tests for fix/recording-hw-cores
# Runs Tests 3-4 from the test plan.
# Tests 3-4: LAZY INIT path — the key fix in this PR.
#
# Manual steps for Tests 3-4 (UI record):
#   1. Wait for LRPS2 to boot to PS2 BIOS menu
#   2. Press F1 to open RetroArch menu
#   3. Go to Recording → Start Recording
#   4. Wait ~10 seconds (optionally drag-resize window to test resize)
#   5. F1 → Recording → Stop Recording
#   6. Close RetroArch (Esc or menu quit)

$ErrorActionPreference = "Stop"
$timeout = 120000  # 2 min — generous for manual interaction

$core = "cores/pcsx2_libretro.dll"

$tests = @(
    @{
        Name       = "UI vulkan (lazy init)"
        Num        = 3
        Cfg        = "vulkan.cfg"
        LazyMsg    = "Re.*initialized async readback"
        Instructions = "Boot, then F1 -> Recording -> Start Recording`nWait ~10s, then F1 -> Stop Recording, then close."
    }
    @{
        Name       = "UI glcore (lazy init)"
        Num        = 4
        Cfg        = "glcore.cfg"
        LazyMsg    = "Re.*initialized async PBO readback"
        Instructions = "Boot, then F1 -> Recording -> Start Recording`nWait ~10s, then F1 -> Stop Recording, then close."
    }
)

Write-Host ""

foreach ($i in 0..($tests.Count - 1)) {
    $t   = $tests[$i]
    $num = $t.Num
    Write-Host "=== Test $num`: $($t.Name) ===" -ForegroundColor Yellow

    if (-not (Test-Path $t.Cfg)) {
        Write-Host "  [SKIP] Config file '$($t.Cfg)' not found." -ForegroundColor Red
        Write-Host ""
        continue
    }

    # Clean slate: logs, generated configs, shader caches
    Remove-Item logs\retroarch.log          -ErrorAction SilentlyContinue
    Remove-Item retroarch.cfg               -ErrorAction SilentlyContinue
    Remove-Item config -Recurse -Force      -ErrorAction SilentlyContinue
    Remove-Item system\pcsx2\cache -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "  Launching RetroArch (NO -r flag — lazy init path)" -ForegroundColor Cyan
    $t.Instructions -split "`n" | ForEach-Object { Write-Host "  >>> $_" -ForegroundColor Cyan }
    Write-Host ""

    $args = @(
        "-L", $core,
        "--appendconfig", $t.Cfg,
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

        # Check for lazy-init message (the key indicator)
        $lazyInit = Select-String -Path $logFile -Pattern $t.LazyMsg -CaseSensitive:$false
        if ($lazyInit) {
            Write-Host "  [OK] Lazy init confirmed:" -ForegroundColor Green
            $lazyInit | ForEach-Object { Write-Host "    $($_.Line)" -ForegroundColor Green }
        } else {
            Write-Host "  [WARN] Lazy init message not found — was recording started from the menu?" -ForegroundColor Red
        }

        # Show recording-related lines
        $recLines = Select-String -Path $logFile `
            -Pattern "Recording|readback|async|gpu_record" -CaseSensitive:$false |
            ForEach-Object { $_.Line }

        if ($recLines) {
            Write-Host "  Recording-related log lines:" -ForegroundColor Gray
            $recLines | ForEach-Object { Write-Host "    $_" }
        }

        # Check for errors
        $errors = Select-String -Path $logFile `
            -Pattern "VK_ERROR|\[ERROR\]|BLACK|DEVICE_LOST" -CaseSensitive:$false |
            Where-Object { $_.Line -notmatch "IsoFS" } |
            ForEach-Object { $_.Line }

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

# Final cleanup
Remove-Item retroarch.cfg -ErrorAction SilentlyContinue

Write-Host "=== All UI tests complete ===" -ForegroundColor Cyan
