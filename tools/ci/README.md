# CI and native validation gates

`.github/workflows/gpu.yml` runs core/upstream/safe-mode tests, differential
stress, software GL/GLES/Vulkan scenes with native validation, strict GL 3.3 and
GLES 3.0 contexts, Chromium WebGL2/WebGPU, Windows D3D11 and D3D12 WARP, and
macOS Metal scenes. `check-metal` forces all scene bodies on macOS ARM64/x86_64
and iOS ARM64 without linking frameworks on the cross-build host.

`install_zig.py` pins Zig 0.17.0 and verifies each downloaded archive against the
[official release index](https://ziglang.org/download/index.json). Its `--dry-run`
prints the archive/checksum without downloading. The checkout action uses the
[v4.2.2 commit](https://github.com/actions/checkout/releases/tag/v4.2.2).

The Windows runtime job requires the DirectX Graphics Tools capability and an
available D3D12 WARP device with debug/GPU validation. The Metal runtime job
requires a real Metal device and requests API and shader validation. Missing
requirements fail these jobs. A macOS hosted VM may have no Metal GPU; use a
hardware-backed self-hosted runner for that gate. A successful cross-build does
not satisfy either native runtime gate.

These workflow files have been checked locally but have not run on GitHub. No
native Windows or Apple result is claimed. Linux locally verifies the actual
scene tools and backend behavior; runner-image package and hosted GPU availability
remain CI execution checks. Firefox WebGPU and mobile devices remain external
gates. Native Dawn, both Vulkan descriptor strategies and hardware Chromium have
separate local passing runs; they are not implicitly covered by software CI jobs. Use the explicit
hardware-browser build steps on a suitable host.

Local installer verification: the Linux archive downloaded, matched its pinned
SHA-256, extracted, and reported Zig 0.17.0. macOS/Windows archive execution remains
a platform CI check.

Presentation gates use `--window-smoke`: Linux X11/EGL and Vulkan through an owned
Xvfb display; Windows flip-model D3D11/D3D12 WARP; macOS NSWindow/CAMetalLayer.
Each renders 32 frames and verifies a pixel in the final presentation source.
Linux is runtime-verified locally; Windows DXGI under this Wine/Xvfb environment
currently faults after monitor metadata errors, and Apple execution remains an
external gate. A successful cross-build does not close either runtime gate.

The Vulkan WSI host additionally requires VK_EXT_swapchain_maintenance1 (and its
surface dependencies). It uses one render-finished semaphore and presentation
fence per image, waits those fences before recycling/teardown, and fails clearly
when the optional host extensions are unavailable. The headless Vulkan backend
still defaults to portable descriptor sets and does not require these WSI
extensions. See https://docs.vulkan.org/guide/latest/swapchain_semaphore_reuse.html.
