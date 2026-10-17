# zicr

zicr is a rendering library for Zig projects.

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
- **Correctness is checked, not assumed.** Every backend runs the same scene suite
  and is compared with CPU-computed results, with the native validation layers of
  each API enabled. The core is fuzzed against the original C implementation.
- **It goes beyond sokol.** zicr has a D3D12 backend (sokol has none), GPU readback
  (`Device.readBuffer`, `Device.readImage`), runtime backend selection and a shader
  build pipeline integrated with `zig build`.
- **Performance is a goal, not a side effect.** The target is to match or beat C
  sokol_gfx on the same workloads; that baseline is still to be measured (TODO.md).

Once the GPU layer is solid on every platform, the renderer is built on top of it.

## Status

| Backend | State | Verified on |
| --- | --- | --- |
| OpenGL 4.x / GLES 3.x | ported, 29/29 scenes | Mesa 26.2 (AMD RADV RENOIR), surfaceless EGL |
| Vulkan 1.3 | ported, 29/29 scenes, validation layer clean | RADV and lavapipe |
| WebGPU (native) | ported, 29/29 scenes | wgpu-native v29 on Linux |
| Direct3D 11 | ported, 29/29 scenes | Wine 11 + DXVK 2.7.1 (not native Windows yet) |
| Direct3D 12 | new, 29/29 scenes | Wine 11 + vkd3d-proton (not native Windows yet) |
| Metal | ported, type-checked only | never run: no Apple hardware yet |
| WebGL2 | not started | |
| WebGPU (browser) | not started | |

Other tests: 207/207 upstream sokol_gfx tests ported from C, 65 unit and API
tests, and differential fuzzing against C sokol_gfx.h (10,000 runs × 500 steps,
no divergence).

The open work, known bugs and design concerns are in [TODO.md](TODO.md).

## Using it

```zig
const gpu = @import("zicr").gpu;

var dev = try gpu.Device.init(allocator, .{
    .backend = .{ .vulkan = .{
        .get_instance_proc_addr = vkGetInstanceProcAddr,
        .instance = instance,
        .physical_device = physical_device,
        .device = device,
        .queue = queue,
        .queue_family_index = family,
    } },
});
defer dev.deinit();

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

zicr does not create windows or GPU devices. The application (or a windowing
library) creates them and passes the native handles in `BackendOptions`. The
test harnesses in `tools/harness/` show how to create a device for each API.

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

The generated module has one namespace per program, with bind-slot constants and
`desc(backend) ?gpu.ShaderDesc`.

## Building and testing

Requires Zig 0.17.

| Step | What it does |
| --- | --- |
| `zig build check` | compile the library and all tests |
| `zig build test` | unit and public API tests |
| `zig build test-upstream` | the tests ported from upstream `sokol_gfx_test.c` |
| `zig build test-diff` | differential fuzzing against the C header (`-- --runs N --steps N --seed N`) |
| `zig build test-scenes` | the scene suite on this platform's backends (`-- --backend vulkan --filter texture`) |
| `zig build check-scenes-windows` | build the scene suite for Windows (D3D11, D3D12) |
| `zig build test-gl`, `test-vk`, `test-wgpu` | per-backend smoke tests |
| `zig build check-d3d11` | build the D3D11 smoke test for Windows |
| `zig build check-metal` | type-check the Metal backend for macOS and iOS |

Backend-specific setup (validation layers, wgpu-native, Wine) is described in
TODO.md, "Test environment".

## Layout

```
src/zicr.zig                 library root (zicr.gpu)
src/gpu/gpu.zig              the public Zig-first API
src/gpu/internal.zig         the raw sokol-shaped API (zicr.gpu.raw)
src/gpu/core.zig, pool.zig   state, resources, generation-checked handle pools
src/gpu/validation.zig       all 399 sokol validation checks, plus zicr's own
src/gpu/backend.zig          runtime backend dispatch
src/gpu/backends/            one directory per backend; CONTRACT.md is the interface
tools/scenes/                the cross-backend scene suite and its shaders
tools/harness/               device creation per backend for the scene suite
tools/shdc/                  sokol-shdc output → Zig module generator
tools/diff/                  differential fuzzer against C sokol_gfx.h
sokol_gfx.h                  the reference implementation (test tooling only)
PORTING.md                   how the port maps to the C header
```

## License

See [LICENSE](LICENSE). sokol_gfx.h is by Andre Weissflog under the zlib/libpng
license; zicr's GPU layer is derived from it.
