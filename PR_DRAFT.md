## Fix GPU recording performance with Vulkan & GL2/3

GPU recording falls back to synchronous readback, causing poor performance. Async readback is never initialized because video driver init runs before recording is set up.

CLI `-r` handler had no-op bug (`if (enable) enable = true`) that prevented `rec_st->enable` from being set, breaking async readback init when `video_gpu_record = true` is set in config.

Adds lazy init of async readback in `read_viewport()` for Vulkan and GL2/3. Readback is set up on first frame where recording is active, and torn down when recording stops.

Adds padding for odd viewport dimensions up to even in FFmpeg recording driver. Subsampled formats (420/422) need even sizes.
