# Native sokol_gfx port

A native Zig translation of the bundled `sokol_gfx.h` by Andre Weissflog. The
original header remains the implementation reference. There are no C imports, C
compilation steps or extern Sokol functions; driver APIs are called through native
Zig function pointers (GL, Vulkan, WebGPU), COM vtables (D3D11) or the Objective-C
runtime (Metal, Apple targets only).

Reference header SHA-256: `6af70de1a768ac3ff85f4c0a145c2e8e702abd5f101c2ad005b69ef69d5094f0`.

## Layout

| Source section | Native code |
| --- | --- |
| Public types and constants, 2364–5934 | `types.zig`, `enums.zig`, `constants.zig` |
| Log items and messages, 5092–5700, 8229–8265 | `enums.zig` (`LogItem`), `log.zig` (generated messages) |
| Internal structs and state, 6983–7210, 8130–8230 | `core.zig` (resources with `slot`/`cmn`, references, state) |
| Pools, references, helpers, 8373–9267 | `pool.zig`, `core.zig` |
| Format and layout calculations, 9269–9693 | `formats.zig` |
| Dummy backend, 9813–10029 | `backends/dummy.zig` (no-ops in `backend.zig`) |
| GL/GLES, 10037–13486 | `backends/gl/` (incl. the Win32 loader in `win32_loader.zig`) |
| D3D11, 13487–16009 | `backends/d3d11/` |
| Metal, 16010–18427 | `backends/metal/` |
| WebGPU, 18428–20693 | `backends/wgpu/` |
| Vulkan, 20694–24132 | `backends/vulkan/` |
| Generic backend dispatch, 24132–24741 | `backend.zig` |
| Validation, 24749–26691 | `validation.zig` (all 399 `VALIDATE_*` checks) |
| Defaults and resource lifecycle, 26699–27409 | `defaults.zig`, `api.zig` |
| Public API, 27418–29545 | `api.zig`, exported by `root.zig` (154/154 entry points) |

`backends/CONTRACT.md` describes the interface between the core and a backend.

## Native API choices

The build exposes the module `sokol_gfx`. Descriptors are passed by value, function
names are camelCase and type names PascalCase. The backend is chosen at setup and
dispatched through a tagged union; the original picks one at compile time:

```zig
const gfx = @import("sokol_gfx");
try gfx.setup(allocator, .vulkan, .{ .environment = .{ .vulkan = .{ ... } } });
defer gfx.shutdown();
```

- Setup takes a `std.mem.Allocator`; legacy allocation callbacks in `Desc.allocator`
  return `error.UseZigAllocator`. Setup returns typed errors instead of asserting
  on missing environments (`error.MissingGlProcAddress`, `error.MissingVulkanLoader`, ...).
- Driver functions come from the application, like a GL loader:
  `environment.gl.get_proc_address`, `environment.vulkan.get_instance_proc_addr`
  (`vkGetInstanceProcAddr`), `environment.wgpu.get_proc_address`. On Windows, GL core
  falls back to resolving through opengl32.dll like the original. Note that
  wgpu-native v29's `wgpuGetProcAddress` is unimplemented; resolve with `dlsym`
  (see `tools/wgpu_smoke.zig`).
- Build options: `-Ddebug=<bool>` is `SOKOL_DEBUG` (default on in Debug and
  ReleaseSafe: validation layer, log message strings, debug labels);
  `-Dvalidate_non_fatal=true` is `SOKOL_VALIDATE_NON_FATAL`. Without it a failed
  validation logs the failing items and then `VALIDATION_FAILED` at panic level,
  which aborts when no logger is installed. The unit tests build non-fatal.
- Resources keep their descriptor with defaults applied and all borrowed pointers
  cleared, in addition to the common state of the original.
- Trace hooks are always available (`SOKOL_TRACE_HOOKS` is not needed).

## Deliberate deviations from the header

- WebGPU bindgroup cache invalidation: the original mask includes the binding
  byte, so only binding-0 entries were invalidated and pipeline entries never;
  the port ignores the binding byte. Failed bindgroups are discarded on cache hit
  instead of asserting.
- WebGPU `DEPTH_STENCIL` is only reported renderable when the device has the
  depth32float-stencil8 feature, which WebGPU requires for that format.
- View validation rejects negative storage-buffer offsets (the original's
  unsigned conversion lets some through).
- Vulkan backend setup releases everything it created when it fails partway.
- Metal command buffers and encoders are retained/released explicitly rather
  than relying on autorelease pools; `@available` checks become
  `respondsToSelector:` probes.

## Verification

| Command | What it checks |
| --- | --- |
| `zig build test` | 57 unit tests: pools, defaults, validation diagnostics, lifecycle, GL/D3D11 mocks (Debug/Safe: 57 pass; Fast/Small: 44 pass, 13 validation tests skip) |
| `zig build test-gl` (`-- --legacy`) | GL 4.6 and GLES 3.2 (and 3.3 / ES 3.0) through surfaceless EGL on Mesa |
| `zig build test-vk` | Vulkan, 10 scenarios with exact readback |
| `WGPU_NATIVE_LIB=... zig build test-wgpu` | WebGPU through wgpu-native, 14 scenarios, both bindgroup cache modes |
| `zig build check-d3d11` | builds the D3D11 smoke executable (run it under Windows or Wine/DXVK) |
| `zig build check-metal` | type-checks the Metal backend for aarch64 macOS and iOS |
| `python3 tools/port_coverage.py` | public entry-point coverage |

Observed in this environment (Linux, Mesa 26.2.4, AMD Radeon RENOIR):

- **GL/GLES**: triangles with exact readback, indexed/instanced/base-vertex draws,
  transient uploads, buffer-to-image copies, texture sampling, MSAA resolve,
  compute storage buffers and images with memory barriers.
- **D3D11** (Wine + DXVK 2.7.1, feature level 11.1): the same scenario set with exact
  readback. This is Windows API execution through Wine, not native Windows.
- **Vulkan** (RADV and lavapipe, with and without the Khronos validation layer,
  zero validation messages): compute-to-fragment storage buffers, transient vertex
  and image writes over several frames, unsealed writes and sealing, buffer and
  buffer-to-image copies from staging and GPU buffers, depth and stencil, 4x MSAA
  with resolve, render-to-texture, compute-written storage images, resource
  destruction and recreation over 10 frames, blending and scissor.
- **WebGPU** (wgpu-native v29.0.1.1 on RADV, uncaptured-error callback fails the
  run): the same scenario set plus uniform ring offsets (200 uniform updates per
  frame), triangle strips with 16-bit indices, cube and array textures.
- **Metal**: type-checked for macOS and iOS only. Enum values were checked against
  Apple's headers by hand. It has not run on Apple hardware; the riskiest parts are
  `objc_msgSend` struct arguments, the completion-handler block literal and
  object lifetimes.

## Not yet verified

- Metal at runtime.
- D3D11 and GL on native Windows (D3D11 ran through Wine/DXVK only; the Win32 GL
  loader is compile-checked).
- Swapchain passes on Vulkan and WebGPU with a real surface (tests use offscreen
  targets and app-provided images), Vulkan and WebGPU debug labels/groups,
  depth-only (non-stencil) attachments, and Vulkan on drivers other than Mesa.
