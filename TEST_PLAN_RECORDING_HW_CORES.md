# Quick Test: Recording with HW-Rendered Cores

**Branch:** `fix/recording-hw-cores`

## Background — Init Paths

There are two distinct readback initialization paths, and tests must cover both:

1. **Eager init (CLI `-r`):** When recording is requested on the command line, `rec_st->enable` is
   already `true` when the video driver initializes. `vulkan_init_readback()` / `gl3_init_pbo_readback()`
   succeeds on the first call inside the driver's `init()` function. The lazy-init branch in
   `read_viewport()` is never reached because `VK_FLAG_READBACK_STREAMED` / PBO state is already set.

2. **Lazy init (UI menu start — the actual fix):** When recording is started from the menu *after*
   the core and driver are already running, `rec_st->enable` was `false` during driver init, so
   readback was **not** initialized. The first call to `read_viewport()` detects this and lazily
   initializes readback. **This is the path that was broken before this PR** (caused
   `VK_ERROR_DEVICE_LOST` on Vulkan, black frames on GLCore).

## Prerequisites

- RetroArch built from this branch with FFmpeg support
- `pcsx2_libretro.dll` (LRPS2) — renderer set to **Auto** so the core follows whatever
  video driver RetroArch uses
- PS2 BIOS files in `system/pcsx2/bios/` — no game ROM needed, LRPS2 boots to BIOS menu

> **Note:** `video_gpu_record` does not need to be set explicitly — it is forced to `true`
> automatically when the core uses a HW render context (see `record_driver.c` line 208–212).

## Setup

Create a minimal appendconfig per driver, e.g. `vulkan.cfg`:
```
video_driver = "vulkan"
log_verbosity = "true"
log_to_file = "true"
log_to_file_timestamp = "false"
config_save_on_exit = "false"
```

And `glcore.cfg` with `video_driver = "glcore"` (same logging settings).

Use `--appendconfig` to override only these settings without touching the main config.
Use `--max-frames=300` for CLI tests so RetroArch exits cleanly and FFmpeg finalizes
the recording. Logs are written to `logs/retroarch.log`. Recordings go to `recordings/`.

Example PowerShell one-liner for automated CLI tests:

```powershell
$p = Start-Process -FilePath ".\retroarch.exe" -ArgumentList `
  "-L","cores/pcsx2_libretro.dll","--appendconfig","vulkan.cfg","-r","rec.mkv", `
  "--max-frames=300","-v" -PassThru
$p.WaitForExit(30000)
if (!$p.HasExited) { Stop-Process -Id $p.Id -Force }
# Check logs/retroarch.log and recordings/*.mkv
```

---

## Tests

### 1. CLI recording — vulkan (eager init)

```
retroarch -L cores/pcsx2_libretro.dll --appendconfig vulkan.cfg -r rec.mkv -v --log-file=logs/test1.log
```

Where `vulkan.cfg` contains:
```
video_driver = "vulkan"
```

Run ~10 s, close normally (Esc or menu quit). The actual recording output ends up in
`recordings/` (the initial file from `-r` is mostly empty due to driver reinit).

**Expected log:** `[Recording] Recording to ... @ WxH`. No async-readback lazy-init
message (readback is initialized eagerly during driver init when `-r` is used).  
**Pass:** output file in `recordings/` plays back correctly, no `VK_ERROR_DEVICE_LOST`.

### 2. CLI recording — glcore (eager init)

```
retroarch -L cores/pcsx2_libretro.dll --appendconfig glcore.cfg -r rec.mkv -v --log-file=logs/test2.log
```

Where `glcore.cfg` contains:
```
video_driver = "glcore"
```

Run ~10 s, close normally.

**Expected log:** `[Recording] Recording to ... @ WxH`. No PBO lazy-init message.  
**Pass:** output file in `recordings/` plays back correctly.

### 3. UI start/stop recording — vulkan (lazy init, **key test**)

Launch **without** `-r`:

```
retroarch -L cores/pcsx2_libretro.dll --appendconfig vulkan.cfg -v --log-file=logs/test3.log
```

Once the core is running, open the menu (F1) → Recording → Start Recording.
Record ~10 s, then menu → Stop Recording. Close RetroArch.

**Expected log:** `[Vulkan] (Re)initialized async readback for recording.` — confirms the lazy-init
path is exercised.  
**Pass:** output file is valid, no `VK_ERROR_DEVICE_LOST`, readback resources cleaned up on stop.

### 4. UI start/stop recording — glcore (lazy init, **key test**)

Same as test 3 but with `--appendconfig glcore.cfg`.

```
retroarch -L cores/pcsx2_libretro.dll --appendconfig glcore.cfg -v --log-file=logs/test4.log
```

**Expected log:** `[GLCore] (Re)initialized async PBO readback for recording.`  
**Pass:** output file is valid, no black frames.

### 5. Resize during recording — vulkan

Start recording (either via `-r` or via menu), drag-resize the window, continue ~5 s, stop.

**Expected:** lazy-reinit of readback if viewport dimensions change.  
**Pass:** no crash, no `VK_ERROR_DEVICE_LOST`, output is playable.

### 6. Resize during recording — glcore

Same as test 5 with GLCore.  
**Pass:** no crash, output is playable.

---

## Results

| # | Test | Driver | Init Path | Result | Notes |
|---|------|--------|-----------|--------|-------|
| 1 | CLI record | vulkan | eager | | |
| 2 | CLI record | glcore | eager | | |
| 3 | UI record | vulkan | **lazy** | | Key test for the PR fix |
| 4 | UI record | glcore | **lazy** | | Key test for the PR fix |
| 5 | Resize | vulkan | lazy reinit | | |
| 6 | Resize | glcore | lazy reinit | | |
