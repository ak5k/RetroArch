## Fix GPU recording with Vulkan & GL2/3

GPU recording falls back to synchronous readback, causing frame drops. Async readback is never initialized because video driver init runs before recording is set up.

CLI `-r` handler had no-op (`if (enable) enable = true`) that prevented `rec_st->enable` from being set, breaking async readback init when `video_gpu_record = true` in config.

Adds lazy init of async readback in `read_viewport()` for Vulkan and GL2/3. Readback is set up on first frame where recording is active, and torn down when recording stops.

Also adds padding for odd viewport dimensions up to even in FFmpeg driver. Subsampled formats (420/422) need even sizes and libx264 rejects odd dimensions.
