# ak5k_run_cli_tests.ps1 — Thin wrapper: launches ak5k_run_cli_tests.sh
# under MSYS2 UCRT64 so there is a single cross-platform test script.

$ErrorActionPreference = "Stop"

$msys2Root = if ($env:MSYS2_ROOT) { $env:MSYS2_ROOT } else { "C:\msys64" }
$shell     = "$msys2Root\msys2_shell.cmd"

if (-not (Test-Path $shell)) {
    Write-Host "[ERROR] MSYS2 not found at $msys2Root" -ForegroundColor Red
    Write-Host "Install MSYS2 or set MSYS2_ROOT to its location." -ForegroundColor Red
    exit 1
}

# Convert the repo root to an MSYS2 path  (D:\foo\bar  →  /d/foo/bar)
$repoWin  = Split-Path -Parent $MyInvocation.MyCommand.Definition
$repoPosix = "/" + ($repoWin -replace '\\','/' -replace '^([A-Za-z]):','$1')
# Lowercase only the drive letter:  /D/...  →  /d/...
$repoPosix = $repoPosix -replace '^/([A-Z])/', { '/' + $_.Groups[1].Value.ToLower() + '/' }

$scriptPath = "$repoPosix/ak5k_run_cli_tests.sh"

Write-Host "=== Launching tests under MSYS2 UCRT64 ===" -ForegroundColor Cyan
Write-Host "  MSYS2 root : $msys2Root"
Write-Host "  Script     : $scriptPath"
Write-Host ""

# CHERE_INVOKING=1 keeps the current working directory.
# -defterm -no-start  runs inside the current console (no new window).
# -ucrt64             selects the UCRT64 environment.
# -shell bash         ensures bash is the shell.
# -c "..."            runs our script.
& $shell -defterm -no-start -ucrt64 -shell bash -c "cd '$repoPosix' && bash '$scriptPath'"

$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "[FAIL] Tests exited with code $exitCode" -ForegroundColor Red
} else {
    Write-Host ""
    Write-Host "[OK] Tests completed successfully." -ForegroundColor Green
}
exit $exitCode
