# zicr

zicr aims to give Zig projects a fast, correct rendering library with a portable,
Zig-native GPU layer as its foundation.

## Objective

zicr aims to be the rendering library a Zig project reaches for: fast at what it
does, correct on every platform it claims to support, and designed for Zig rather
than wrapped around a C API.

It is built bottom-up. The renderer (scenes, materials, render graphs, whatever
the higher layers turn out to be) can only be as good as what it stands on, so the
first goal is the lowest layer: a thin, explicit, portable GPU abstraction,
`zicr.gpu`, over every modern graphics API:

| Platform | Backends |
| --- | --- |
| Windows | Direct3D 12, Vulkan (Direct3D 11 until D3D12 is proven, see TODO.md) |
| Linux, Android | Vulkan, OpenGL / OpenGL ES |
| macOS, iOS | Metal |
| Web | WebGPU, WebGL2 |

The GPU layer started as a complete port of Andre Weissflog's
[sokol_gfx.h](https://github.com/floooh/sokol) to Zig, because sokol_gfx is a
small, battle-tested design that already solves resource pools, validation and
backend portability well. zicr is not a sokol fork, though:

- **The public API is Zig-first.** `zicr.gpu` uses a `Device` object, error unions,
  slices, optionals, tagged unions and pass objects. The sokol-shaped API survives
  only as `zicr.gpu.raw` for the port's own tests.
- **Correctness is checked against results.** Backends share a scene suite with
  CPU-computed expectations. Available native validation is counted, and the
  status table distinguishes runtime evidence from cross-compilation. The core
  is fuzzed against the original C implementation.
- **It goes beyond sokol.** zicr has a D3D12 backend (sokol has none), GPU readback
  (`Device.readBuffer`, `Device.readImage`, owned readback tickets), runtime backend selection and a shader
  build pipeline integrated with `zig build`.
- **Performance is a goal, not a side effect.** The target is to match or beat C
  sokol_gfx on the same workloads; the first measured GL baseline and profile are in [bench/RESULTS.md](bench/RESULTS.md).

Once the GPU layer is solid on every platform, the renderer is built on top of it.

## Status

| Backend | State | Verified on |
| --- | --- | --- |
| OpenGL / GLES | 64-scene coverage, capability skips explicit | Mesa 26.2.4 RENOIR; strict GL3.3/ES3.0; debug output; Xvfb window swaps and final pixels |
| Vulkan 1.3 | descriptor sets and descriptor buffers tested | RADV/lavapipe, synchronization validation; Windows via Wine; lavapipe X11 acquire/present/readback |
| WebGPU (native) | 64-scene coverage, capability skips explicit | wgpu-native v29 and Dawn 67d4d6e on Linux; error scopes, asynchronous maps and full portable scenes |
| Direct3D 11 | 57 passed, 7 capability skips | Wine 11 + DXVK; portable limits, async tickets; native Windows remains unverified |
| Direct3D 12 | 59 passed, 5 capability skips | Wine 11 + vkd3d-proton; portable limits, async tickets; native Windows GPU validation remains required |
| Metal | all scene bodies cross-compiled | macOS arm64/x86-64 and iOS arm64; Apple runtime remains unverified |
| WebGL2 | Chromium software 46 pass/19 skip; hardware 44/21; Firefox 46/19 | Pixel comparisons, exact diagnostics, 32 canvas presentation frames and final-pixel readback |
| WebGPU (browser) | Chromium software 56 pass/9 skip; hardware 55/10 | SwiftShader and AMD adapter; asynchronous maps, uncaptured errors, canvas presentation/readback |

Scene totals vary with advertised features; a capability skip is not runtime
coverage of that feature. Browser totals include a separate canvas test. Current
Windows totals are from Wine, whose D3D12 InfoQueue is unavailable. Strict native
Windows/Apple validation workflows exist but have not run remotely. The exact
commands and dated evidence are in [tasks/TODO_COMPLETION.md](tasks/TODO_COMPLETION.md).

Core/upstream checks, public API docs and Windows/Apple cross-checks pass. The
core differential test runs 10,000 streams × 500 steps against C; real-backend
robustness coverage additionally executes 128 frames and 4096 seeded draws with
resource recycling on each available API.

The open work, known bugs and design concerns are in [TODO.md](TODO.md).

## Using it

```zig
const std = @import("std");
const gpu = @import("zicr").gpu;

var dev = try gpu.Device.init(allocator, .{
    .backend = .{ .vulkan = .{
        .get_instance_proc_addr = @ptrCast(vkGetInstanceProcAddr),
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = queue,
        .queue_family_index = family,
    } },
});
defer dev.deinit();

// shader_desc declares a float2 vertex input and a vec4 uniform at slot 0.
const shader = try dev.createShader(shader_desc);
defer dev.destroy(shader);
const pipeline = try dev.createPipeline(.{
    .shader = shader,
    .vertex_attrs = &.{.{ .format = .float2 }},
    .colors = &.{.{ .format = swapchain.color_format }},
    .depth = .{ .format = .none },
});
defer dev.destroy(pipeline);

const vbuf = try dev.createBuffer(.{ .usage = .{ .vertex = true }, .data = std.mem.sliceAsBytes(&vertices) });
defer dev.destroy(vbuf);

var pass = dev.beginPass(.{ .target = .{ .swapchain = swapchain } });
pass.setPipeline(pipeline);
pass.setBindings(.{ .vertex_buffers = &.{.{ .buffer = vbuf }} });
pass.setUniforms(0, &params);
pass.draw(.{ .count = 3 });
pass.end();
dev.commit();
```

This sequence is compiled in `tools/module_check.zig`. The application supplies
validated native handles, a loader function pointer, a color-only swapchain,
vertex data, and the shader description generated by the build step below.
Create every resource, including its pipeline, with the same Device.

The GPU layer is also available as a standalone build module:

```zig
// build.zig
exe.root_module.addImport("gpu", zicr_dep.module("gpu"));
// application source
const gpu = @import("gpu");
```

`@import("gpu")` and `@import("zicr").gpu` share the same types and device identity
allocator when obtained from the same dependency.

zicr does not create windows or GPU devices. The application (or a windowing
library) creates them and passes the native handles in `BackendOptions`. The
test harnesses in `tools/harness/` show how to create a device for each API.

For Windows hosts, `gpu.raw.native.dxgi.Preferred.init(.high_performance, index)`
shows `IDXGIFactory6::EnumAdapterByGpuPreference`; `.minimum_power` is also
available. Keep the returned owner alive through device destruction, test the
chosen adapter with device creation, and enumerate another index or use WARP if
it is unsuitable. The D3D12 test host tries the preferred adapter, the default
adapter on older DXGI, then WARP; `--backend d3d12_warp` forces software validation.


Shaders are written once in [sokol-shdc](https://github.com/floooh/sokol-tools)
annotated GLSL and compiled for every backend at build time:

```zig
// build.zig of a project depending on zicr
const zicr_dep = b.dependency("zicr", .{});
const zicr = @import("zicr");
if (zicr.addShaderModule(b, zicr_dep, .{ .input = b.path("src/shaders.glsl"), .zicr = zicr_dep.module("zicr") })) |shaders| {
    exe.root_module.addImport("shaders", shaders);
}
```

Set `ShaderOptions.compiler` to a host-native sokol-shdc executable `LazyPath`
for an individual call, or use `-Dshader-compiler=/path/to/sokol-shdc` for the
repository's shader steps. A consuming build can configure the dependency with
`.{ .@"shader-compiler" = b.path("tools/sokol-shdc") }`. The override bypasses the
bundled lazy dependency, and unsupported hosts can still use the library without
executing shader steps. `ShaderOptions.slangs` selects a colon-separated target
subset for feature-specific programs; omitted backends return null from `desc`.

The generated module has one namespace per program, with bind-slot constants and
`desc(backend) ?gpu.ShaderDesc`. Render programs also expose `glsl330`, an
explicit GLSL 3.30 descriptor for GL 3.3 contexts. It preserves attribute/output
locations and links varyings by name; newer language operations still require a
newer context and are rejected by its shader compiler. Compute remains GL 4.3.

Initial Vulkan and D3D12 buffer/image uploads batch automatically until `commit`
or a readback flush. Input bytes are copied before creation/write returns, so
caller memory can be released immediately. Vulkan uses fence-owned staging chunks;
`copy_staging_buffer_size` sets the normal chunk size, with extra chunks for larger
batches. The next reuse of a completed frame retires extra chunks. Commit periodically
during large asset-loading bursts to bound pending staging memory.

## Browser builds and readback

`zig build check-scenes-web` installs a freestanding `wasm32` module and its
JavaScript bridges in `zig-out/web`. Serve that directory over HTTP, then open
`index.html?backend=webgl2` or `index.html?backend=wgpu`. WebGPU needs a secure
context (localhost counts). There is no Emscripten dependency.

`gpu.web.glProcAddress` and `gpu.web.wgpuProcAddress` resolve the wasm imports.
The browser owns the WebGL2 context or WebGPU device. See
[`tools/web/main.zig`](tools/web/main.zig) for the wasm exports and
[`tools/web/scenes.js`](tools/web/scenes.js) for host initialization. The WebGPU
bridge decodes structs using metadata generated from the backend's actual Zig
bindings. It implements the subset of webgpu.h used by zicr, not a general C ABI.

WebGPU readback must yield to the event loop. Commit the producer work, request a
ticket, then poll it on subsequent frames:

```zig
var read = try dev.requestReadBuffer(buffer, 0, byte_count);
// Keep `read` between frames. It owns its output and must not be copied.
if (try read.poll()) |bytes| {
    consume(bytes);
    read.deinit();
}
```

`requestReadImage(image, region, layout)` returns the same ticket type. Release
all tickets before the device and keep its allocator alive until device teardown.
Requests submit copies without waiting for completion on Vulkan, GL/GLES,
D3D11, D3D12, Metal and WebGPU. Cancelled tickets retain native resources until
the GPU finishes. Browser WebGPU's synchronous reads return `ReadFailed`
instead of spinning. WebGL2 reads use canonical RGBA formats and repack channels;
exact readback of packed `rgb10a2` and `rg11b10f` is unsupported.

GL/GLES without native texture views emulate sampled mip ranges using base/max
levels. One backing texture must use the same range on every bound unit in a
draw; conflicting ranges skip the draw with a diagnostic. Layer subsets require
native texture views and fail creation otherwise. `Features.gl_texture_views`
reports independent native view objects. Absolute attachment/readback mip levels
remain independent of the last sampled range.

Multiple independent `Device` objects can coexist. Each device belongs to its
creating thread; use separate devices on separate threads. Native handles shared
between devices still require synchronization by the application. Public resource
handles carry their device identity and cannot be used across devices.

`Device.status()` reports sticky device loss. An optional `on_device_lost` callback
runs once on the owning thread when the device is next polled or used. Recover by
recreating the native device and a fresh `Device`, then rebuilding its resources.
Callbacks must not reenter or destroy their device. Forward host-owned native or
browser WebGPU loss callbacks and WebGL context-loss events with `notifyLost`;
keep that forwarding valid only while the Device is alive.
Unsealed buffers/images must be sealed before draws use them; such draws are
skipped while initialization is incomplete.

## Building and testing

Requires Zig 0.17.

| Step | What it does |
| --- | --- |
| `zig build docs` | generate Zig API documentation in `zig-out/docs` |
| `zig build check` | compile unit and upstream tests against the library |
| `zig build test` | unit and public API tests |
| `zig build test-upstream` | the tests ported from upstream `sokol_gfx_test.c` |
| `zig build test-diff` | differential fuzzing against the C header (`-- --runs N --steps N --seed N`) |
| `zig build test-scenes` | the scene suite on this platform's backends (`-- --backend vulkan --filter texture`) |
| `zig build check-scenes-web` | build and install the freestanding browser scene runner and bridges |
| `zig build test-web` | run WebGL2 and WebGPU in an isolated headless Chromium process (Node required; `CHROMIUM` selects the executable) |
| `zig build test-web-webgl2`, `test-web-wgpu` | run one browser backend |
| `zig build test-firefox-webgl2`, `test-firefox-wgpu` | isolated Firefox runs (`FIREFOX` selects executable); WebGPU adapter unavailable in the tested headless setup |
| `zig build test-web-hardware-webgl2`, `test-web-hardware-wgpu` | require a hardware Chromium adapter and record its identity |
| `zig build check-scenes-windows` | build Windows D3D11/D3D12/Vulkan scenes and window hosts |
| `zig build test-gl`, `test-vk`, `test-wgpu` | per-backend smoke tests |
| `zig build check-d3d11` | build the D3D11 smoke test for Windows |
| `zig build check-metal` | check all Metal scenes on macOS arm64/x86-64 and iOS arm64, plus the macOS window ABI |
| `zig build test-scenes -- --backend gl --window-smoke --require-native-validation` | native window presentation and final-pixel verification; select a supported platform backend |
| `zig build bench-tools` | build native C/raw/public benchmark tools; see [bench/README.md](bench/README.md) for provider/SDK options |

Backend-specific setup (validation layers, wgpu-native, Wine) is described in
[tasks/VERIFICATION.md](tasks/VERIFICATION.md), with the original environment
notes retained in TODO.md.

## Layout

```
src/zicr.zig                 library root (zicr.gpu)
src/gpu/root.zig             the standalone gpu module and public Zig-first API
src/gpu/internal.zig         the raw sokol-shaped API (zicr.gpu.raw)
src/gpu/core.zig, pool.zig   state, resources, generation-checked handle pools
src/gpu/validation.zig       all 399 sokol validation checks, plus zicr's own
src/gpu/backend.zig          runtime backend dispatch
src/gpu/backends/            one directory per backend; CONTRACT.md is the interface
tools/scenes/                the cross-backend scene suite and its shaders
tools/harness/               device creation per backend for the scene suite
tools/web/                   freestanding wasm entry, browser bridges and test runner
tools/shdc/                  sokol-shdc output → Zig module generator
tools/diff/                  differential fuzzer against C sokol_gfx.h
tools/bench/, bench/         checked native performance tools, raw samples and profiles
tools/webgpu/                native provider ABI audit and Dawn reproduction
.github/workflows/gpu.yml    Linux, Windows and macOS validation gates
sokol_gfx.h                  the reference implementation (test tooling only)
PORTING.md                   how the port maps to the C header
```

## License

See [LICENSE](LICENSE). sokol_gfx.h is by Andre Weissflog under the zlib/libpng
license; zicr's GPU layer is derived from it.
