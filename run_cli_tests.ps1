# run_cli_tests.ps1 — CLI recording tests for fix/recording-hw-cores
# Runs Test 1 (vulkan), Test 2 (glcore), and Test 3 (gl) from the test plan.

$ErrorActionPreference = "Stop"
$timeout = 60000  # ms to wait for RetroArch to exit

$maxFrames = 300
$defaultCore    = "cores/pcsx2_libretro.dll"
$swanstationRom = "D:\PELIT\retroarch\data\roms\psx\ff7_1.cue"

$tests = @(
    @{ Name = "CLI vulkan"; Cfg = "vulkan.cfg"; LogPattern = "vulkan"; Renderer = "Auto"; RecFile = "recordings/vulkan.mkv" }
    @{ Name = "CLI glcore"; Cfg = "glcore.cfg"; LogPattern = "glcore"; Renderer = "Auto"; RecFile = "recordings/glcore.mkv" }
    @{ Name = "CLI gl";     Cfg = "gl2.cfg";    LogPattern = "gl2";    RecFile = "recordings/gl.mkv"
       Core = "cores/swanstation_libretro.dll"; Content = $swanstationRom }
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

    # Choose core and content for this test
    $core    = if ($t.Core)    { $t.Core }    else { $defaultCore }
    $content = if ($t.Content) { $t.Content } else { $null }

    # Clean slate: logs, generated configs, shader caches
    Remove-Item logs\retroarch.log          -ErrorAction SilentlyContinue
    Remove-Item retroarch.cfg               -ErrorAction SilentlyContinue
    Remove-Item config -Recurse -Force      -ErrorAction SilentlyContinue
    Remove-Item system\pcsx2\cache -Recurse -Force -ErrorAction SilentlyContinue

    # Set core options for this test
    if ($t.Renderer) {
        $optDir = "config\LRPS2"
        $optFile = "$optDir\LRPS2.opt"
        New-Item -ItemType Directory -Path $optDir -Force | Out-Null
        Set-Content -Path $optFile -Value "pcsx2_renderer = `"$($t.Renderer)`""
    }
    if ($core -match "swanstation") {
        $optDir = "config\SwanStation"
        $optFile = "$optDir\SwanStation.opt"
        New-Item -ItemType Directory -Path $optDir -Force | Out-Null
        Set-Content -Path $optFile -Value 'swanstation_GPU_Renderer = "Software"'
    }

    $recFile = $t.RecFile
    New-Item -ItemType Directory -Path (Split-Path $recFile) -Force | Out-Null
    $args = @(
        "-L", $core,
        "--appendconfig", $t.Cfg,
        "-r", $recFile,
        "--max-frames=$maxFrames",
        "-v"
    )
    if ($content) { $args += $content }

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

    # --- Check recording ---
    if (Test-Path $recFile) {
        $rec = Get-Item $recFile
        Write-Host "  Recording: $($rec.Name) ($([math]::Round($rec.Length/1KB, 1)) KB)"
        if ($rec.Length -lt 1024) {
            Write-Host "  [FAIL] Recording too small — likely not finalized." -ForegroundColor Red
        } else {
            Write-Host "  [PASS]" -ForegroundColor Green
        }
    } else {
        Write-Host "  [FAIL] No recording found ($recFile)." -ForegroundColor Red
    }

    Write-Host ""
}

# Final cleanup (keep recordings/ and driver .mkv files)
Remove-Item retroarch.cfg -ErrorAction SilentlyContinue
Remove-Item config -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "=== All CLI tests complete ===" -ForegroundColor Cyan
