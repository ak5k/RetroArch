# build.ps1 — Build RetroArch using MSYS2 UCRT64
$env:MSYSTEM = "UCRT64"
$env:CHERE_INVOKING = "1"
& C:\msys64\usr\bin\bash.exe -lc "cd /d/dev/projects/RetroArch && make -j8 2>&1 | tail -5"
