# zicr TODO, concerns and implementation notes

This document collects everything that is still open in zicr's GPU layer: the work
planned next, the guides for the two browser backends, the concerns about each
existing backend (including bugs found by reading the code that the scene suite
does not catch yet), test gaps, and the test environment. It is meant to be read
by whoever picks up the next piece of work, so it errs on the side of detail.

File references are written as `path:line` against commit `254976a` ("Add the
D3D12 backend"); line numbers drift as code changes, so search for the quoted code
if a line doesn't match.

Contents:

1. [The main objective](#1-the-main-objective)
2. [Where things stand](#2-where-things-stand)
3. [WebGL2 in the browser](#3-webgl2-in-the-browser)
4. [WebGPU in the browser](#4-webgpu-in-the-browser)
5. [A browser test harness](#5-a-browser-test-harness)
6. [Direct3D 12 concerns](#6-direct3d-12-concerns)
7. [Direct3D 11 concerns and its removal](#7-direct3d-11-concerns-and-its-removal)
8. [Vulkan](#8-vulkan)
9. [WebGPU (native)](#9-webgpu-native)
10. [OpenGL and GLES](#10-opengl-and-gles)
11. [Metal](#11-metal)
12. [Core and public API](#12-core-and-public-api)
13. [Shader pipeline](#13-shader-pipeline)
14. [Test suite gaps](#14-test-suite-gaps)
15. [Performance](#15-performance)
16. [Documentation and housekeeping](#16-documentation-and-housekeeping)
17. [Test environment](#17-test-environment)
18. [Sources](#18-sources)

---

## 1. The main objective

> zicr isn't just a sokol fork. It's supposed to be a rendering library for Zig
> projects, one that's so good and performant at what it does. But for that to
> happen, the very low level layers have to be built first. Then we can go on
> with the goal of the renderer.

That sentence decides most trade-offs in this document:

- **The GPU layer comes first, and it has to be trustworthy.** A renderer built on
  a GPU layer that is "probably right" on half its platforms inherits every one of
  its bugs, and they surface far from their cause (a black texture in a material
  system is much harder to trace than a failing scene in a 50-line test). So every
  backend must pass the same scene suite with its native validation enabled before
  higher layers rely on it.
- **Zig-first, not C-shaped.** The public API (`src/gpu/gpu.zig`) is the product.
  The sokol-shaped internal API (`zicr.gpu.raw`) exists so the port can be checked
  against sokol's own tests and against the C implementation; it is not something
  users should touch.
- **Modern APIs are the targets.** D3D12, Vulkan, Metal and WebGPU are the primary
  backends. OpenGL stays only because WebGL2 is still the widest-reaching browser
  API and GLES is still needed on part of Android; D3D11 goes once D3D12 is proven
  (section 7).
- **Fast, and measured.** "Best and fastest" needs numbers: the C sokol_gfx
  baseline on the same scenes (section 15) is the first yardstick, real renderer
  workloads the second.
- **Correctness is checked against something outside zicr.** Upstream sokol tests,
  differential fuzzing against C sokol_gfx.h, CPU-computed scene expectations, and
  each API's own validation layer. When a check can't run (Metal without Apple
  hardware, the D3D12 info queue under vkd3d-proton) this document says so,
  instead of counting a pass that didn't happen.

---

## 2. Where things stand

| Backend | Code | Scene suite (29 scenes) | Native validation | Verified on |
| --- | --- | --- | --- | --- |
| OpenGL 4.6 | port of sokol | 29/29 | none (GL has no validation layer; KHR_debug is not wired up, see 10.4) | Mesa 26.2.4, AMD RENOIR |
| GLES 3.2 | port of sokol | 29/29 | none | Mesa 26.2.4 |
| GL 3.3 / GLES 3.0 ("legacy") | port of sokol | smoke tests only | none | Mesa 26.2.4 |
| Vulkan 1.3 | port of sokol | 29/29 | Khronos validation layer, clean | RADV (AMD), lavapipe (CPU) |
| WebGPU, native | port of sokol | 29/29 | wgpu error callbacks, clean | wgpu-native v29.0.1.1 |
| D3D11 | port of sokol | 29/29 | none under DXVK | Wine 11 + DXVK 2.7.1 |
| D3D12 | new (no sokol code) | 29/29 | info queue unavailable; Vulkan layer under vkd3d-proton shows only vkd3d-proton's own errors | Wine 11 + vkd3d-proton (from Proton Experimental) |
| Metal | port of sokol | not run | n/a | type-checked for macOS and iOS only |
| WebGL2 | not started | | | |
| WebGPU, browser | not started | | | |

Scenes (`tools/scenes/scenes.zig`): clear, triangles, indexed_uint16,
indexed_uint32_base_vertex, instancing, uniform_updates, scissor, viewport,
blend_alpha, blend_max, depth_test, stencil, texture_2d, texture_mip_levels,
texture_array, texture_3d, texture_cube, render_to_texture, msaa_resolve,
multiple_render_targets, write_buffer_transient, write_image_transient,
write_unsealed, copy_buffer_to_buffer, copy_buffer_to_image, render_formats,
compute_buffer, compute_image, compute_to_vertex.

Other suites:

- `zig build test`: 56 unit tests (`src/gpu/tests.zig`) and 9 public API tests
  (`src/gpu/api_tests.zig`).
- `zig build test-upstream`: 207 tests ported from upstream
  `tests/functional/sokol_gfx_test.c`, 0 skipped, 1500 assertions (the same count
  as the C file).
- `zig build test-diff`: the differential fuzzer (`tools/diff/fuzz.zig`) drives
  zicr's core and C sokol_gfx.h (compiled only into the tool) with the same random
  command streams on the dummy backend and compares every resource state, log item
  and handle. 10,000 runs × 500 steps found no divergence after the fixes below.

Bugs the test work found and fixed (useful as a picture of what kind of bugs the
suites catch):

- A negative `color_count` asserted instead of reaching validation (upstream tests).
- `imageCopySize` lacked C's `size_t` wraparound for negative pitches (fuzzer).
- The image default pixel format ignored C's preference order, color before depth
  (fuzzer).
- Two upstream C sokol bugs, fixed in the port: the WebGPU bind group cache
  invalidation mask, and `depth32float_stencil8` feature gating.
- GLES readback: `glGetBufferSubData` resolves through EGL on Mesa but does
  nothing on GLES; GLES now always maps (`src/gpu/backends/gl/backend.zig:599`).
- D3D12: descriptor heap start handles are returned through a hidden out pointer
  (section 6.1), and views must read the resolved descriptor, not the raw one.
- A compute shader named a storage image `target`, which is a reserved word in
  WGSL (section 13.3).

---

## 3. WebGL2 in the browser

The plan is to run the existing GL backend in the browser through WebGL2, with our
own small JavaScript shim instead of Emscripten. This section is a guide to doing
that; it lists everything in the current GL backend that will not survive contact
with WebGL2.

### 3.1 How the GL backend gets its functions

The GL backend never links against a GL library. Every function goes through
`environment.gl.get_proc_address`, resolved once at setup:

```zig
// src/gpu/backends/gl/dispatch.zig:139
pub fn load(get_proc: GetProcAddress, user_data: ?*anyopaque) Dispatch {
    @setEvalBranchQuota(100_000);
    var result: Dispatch = .{};
    inline for (@typeInfo(Dispatch).@"struct".field_names) |name| {
        const symbol = "gl" ++ .{std.ascii.toUpper(name[0])} ++ name[1..];
        if (get_proc(symbol, user_data)) |address| @field(result, name) = @ptrCast(@alignCast(address));
    }
    return result;
}
```

So the web port does not touch the backend's call sites at all. It needs:

1. A wasm build of the scene runner (or of a test app): target
   `wasm32-freestanding`, with `std.heap.wasm_allocator`.
2. One `extern "gl"` declaration per GL function the backend uses (the field list
   of `Dispatch` in `src/gpu/backends/gl/dispatch.zig` is the complete list):

   ```zig
   extern "gl" fn glBindBuffer(target: u32, buffer: u32) void;
   extern "gl" fn glBufferData(target: u32, size: isize, data: ?*const anyopaque, usage: u32) void;
   // ...
   ```

3. A `get_proc_address` that maps names to those externs. It can be generated at
   comptime from the `Dispatch` fields, so the list can't drift:

   ```zig
   fn getProcAddress(name: [:0]const u8, _: ?*anyopaque) ?*const anyopaque {
       inline for (@typeInfo(web_gl).@"struct".decls) |decl| {
           if (std.mem.eql(u8, name, decl.name)) return @ptrCast(&@field(web_gl, decl.name));
       }
       return null;
   }
   ```

   Taking the address of an imported function is fine in wasm: the linker puts
   it in the function table and the pointer is a table index. `call_conv` in
   `dispatch.zig:5` is `.c` on wasm, which is what wasm imports use.
4. A JavaScript object passed as the `gl` import namespace when instantiating the
   module, implementing every function on top of a `WebGL2RenderingContext`.

### 3.2 Things in the GL backend that are keyed on Emscripten

The port kept sokol's web-specific behavior, but it tests for Emscripten by OS
tag, and a `wasm32-freestanding` build is not `.emscripten`:

```zig
// src/gpu/backends/gl/backend.zig:72
var extensions: caps.Extensions = .{ .etc2 = gles and builtin.os.tag != .emscripten };
// src/gpu/backends/gl/backend.zig:91
if (builtin.os.tag == .emscripten and extensions.colorbuffer_float) extensions.colorbuffer_half_float = true;
// src/gpu/backends/gl/backend.zig:98
.separate_buffer_types = gles and builtin.os.tag == .emscripten,
```

These correspond to sokol_gfx.h lines 11099-11103 (`separate_buffer_types`),
11114-11118 (no ETC2 on the web) and 11154-11162 (on WebGL2,
`EXT_color_buffer_float` covers the 16-bit float formats too). Replace the test
with something like `const is_web = builtin.cpu.arch.isWasm();` in one place and
use it in all three. All three are real WebGL2 rules:

- `separate_buffer_types`: WebGL2 forbids binding a buffer to `ELEMENT_ARRAY_BUFFER`
  if it was ever bound to another target, and vice versa (WebGL 2.0 spec section
  5.1, "Buffer Object Binding"). zicr's validation then rejects buffers that are
  both index and vertex/storage buffers.
- ETC2: WebGL2 removed the GLES 3.0 guarantee; ETC2 only exists behind
  `WEBGL_compressed_texture_etc`.
- Half float render targets: covered by `EXT_color_buffer_float` on WebGL2.

sokol also disables `glGetError` checks on the web because each call is a
synchronous round trip (sokol_gfx.h:6944-6950). The port doesn't call
`glGetError` in its normal paths, so nothing needs to change, but keep it that way.

### 3.3 Version and extension queries

`src/gpu/backends/gl/backend.zig:53-58` reads `GL_MAJOR_VERSION`/`GL_MINOR_VERSION`
with `glGetIntegerv`, requires at least 3.0 for GLES, and enables features from
the version (`compute` at 3.1, `draw_base_vertex` and `colorMaski` at 3.2). The
shim must report 3.0 for WebGL2, whatever `gl.getParameter(gl.VERSION)` says
("WebGL 2.0 (OpenGL ES 3.0 Chromium)"). Reporting anything higher would make the
backend require `glDispatchCompute`, `glDrawElementsBaseVertex` and others that do
not exist.

Extensions are enumerated with `GL_NUM_EXTENSIONS` and `glGetStringi`
(`backend.zig:73-89`) and matched by substring. WebGL has neither, so the shim has
to fake them from `gl.getSupportedExtensions()`. Two important differences from
desktop GL:

- **WebGL extensions must be enabled.** On desktop GL every listed extension is
  usable. On WebGL an extension does nothing until `gl.getExtension(name)` was
  called. The shim should call `getExtension` for each name as it reports it, so
  that what the backend sees is actually enabled.
- **Names differ.** WebGL names have no `GL_` prefix (`EXT_color_buffer_float`,
  `WEBGL_compressed_texture_s3tc`, `EXT_texture_filter_anisotropic`). The substring
  patterns in `backend.zig:78-84` (`"_color_buffer_float"`,
  `"_compressed_texture_s3tc"`, `"_texture_filter_anisotropic"`, ...) already match
  them, which is how sokol's code worked on the web too.
- `glGetStringi` returns a C string pointer. The shim has to put each name into
  wasm memory: export an allocation function from the wasm module, or pre-allocate
  a string table at init, encode each name with `TextEncoder`, and return the
  pointer. Those strings must live as long as the backend might read them (the
  backend only uses them during init, so one table freed after setup works).

### 3.4 Objects are not integers in WebGL

GL uses integer names for objects; WebGL uses JavaScript objects (`WebGLBuffer`,
`WebGLTexture`, `WebGLFramebuffer`, `WebGLRenderbuffer`, `WebGLSampler`,
`WebGLProgram`, `WebGLShader`, `WebGLVertexArrayObject`,
`WebGLUniformLocation`). The backend stores names as `u32` (for example
`texture_views: [2]u32` in `src/gpu/backends/gl/resources.zig:54`), so the shim
needs handle tables, which is what Emscripten's `GL.buffers`, `GL.textures`, etc.
do:

```js
class Table {
  constructor() { this.objects = [null]; this.free = []; } // 0 stays "no object"
  add(object) {
    const id = this.free.length ? this.free.pop() : this.objects.length;
    this.objects[id] = object;
    return id;
  }
  get(id) { return id === 0 ? null : this.objects[id]; }
  remove(id) { this.objects[id] = null; this.free.push(id); }
}
const buffers = new Table(), textures = new Table(); // ... one per kind

// glGenBuffers(n, *u32): write new ids into wasm memory
glGenBuffers(n, ptr) {
  const ids = new Uint32Array(memory.buffer, ptr, n);
  for (let i = 0; i < n; i++) ids[i] = buffers.add(gl.createBuffer());
},
glDeleteBuffers(n, ptr) {
  const ids = new Uint32Array(memory.buffer, ptr, n);
  for (const id of ids) { gl.deleteBuffer(buffers.get(id)); buffers.remove(id); }
},
glBindBuffer(target, id) { gl.bindBuffer(target, buffers.get(id)); },
```

The backend requires the `gen*` variants (`genBuffers`, `genTextures`,
`genVertexArrays`, `genFramebuffers`, `genRenderbuffers`, `genSamplers`, see the
`require` list in `backend.zig:61`), so those are the ones to implement on top of
`create*`. `glGetUniformLocation` returns an `i32` in GL; store the
`WebGLUniformLocation` objects in a table per program and return indices, as
Emscripten does.

### 3.5 Memory views from JavaScript

- Every pointer argument is an offset into the wasm memory. Create typed array
  views (`new Uint8Array(memory.buffer, ptr, len)`) at call time, never cache
  them: `memory.grow` detaches the old `ArrayBuffer`, and any cached view then
  throws or reads zeros. This is the single most common bug in hand-written wasm
  GL shims.
- `glShaderSource(shader, count, const char**, const int*)` passes an array of
  string pointers and an optional array of lengths: read each pointer with a
  `Uint32Array` view, decode with `TextDecoder`, and join.
- `glGetShaderInfoLog`/`glGetProgramInfoLog` write into a caller buffer: encode
  with `TextEncoder.encodeInto`, NUL-terminate, and write the length.
- `glTexImage*`, `glTexSubImage*`, `glBufferData`, `glBufferSubData`: pass
  `Uint8Array` views of the right range. WebGL2 also has overloads taking a source
  offset into an `ArrayBufferView`, which avoids an extra view per call.
- `glGetIntegerv(name, *i32)` writes into memory; most parameters map to
  `gl.getParameter(name)`, but a few return typed arrays (`VIEWPORT`,
  `MAX_VIEWPORT_DIMS`) or objects (bindings), which need special cases.

### 3.6 Functions WebGL2 does not have

The GLES 3.0 path of the backend mostly sticks to WebGL2-compatible functions, but
these need attention:

| Backend uses | WebGL2 | What to do |
| --- | --- | --- |
| `glMapBufferRange` / `glUnmapBuffer` (GLES readback, `backend.zig:604-607`) | not available | WebGL2 has `gl.getBufferSubData(target, srcByteOffset, dstView)`. Change `readBuffer` so a web build uses `getBufferSubData` (expose it as `glGetBufferSubData` in the shim); the current `if (!self.gles)` guard at `backend.zig:600` would skip it, so the condition needs `or is_web`. |
| `glSamplerParameterfv` (border color) | not available (no border color in WebGL) | `image_clamp_to_border` is already false on GLES (`backend.zig:93`); implement it as a no-op in the shim so `require` passes. |
| `glGetStringi` | not available | fake it (section 3.3) |
| `glGetBufferSubData` with `copy_read_buffer` | available | WebGL2 may warn about a performance stall when reading a buffer the GPU still uses; acceptable for readback. |
| `glDrawElementsBaseVertex` etc. | only via `WEBGL_draw_instanced_base_vertex_base_instance` (Chromium, behind a flag in some versions) | `draw_base_vertex` stays false at version 3.0; the `indexed_uint32_base_vertex` scene should skip. |
| `glInvalidateFramebuffer` | available | |
| `GL_PRIMITIVE_RESTART_FIXED_INDEX` | always on in WebGL2; enabling or disabling it is an invalid enum | the backend never touches it today; keep it that way. |
| `glTexStorage2D/3D` | available | required on GLES (`backend.zig:70`). |

### 3.7 Readback and pixel formats

`readImage` uses `glReadPixels` through the backend's framebuffer. WebGL2 accepts
only `RGBA`/`UNSIGNED_BYTE` (normalized fixed point), `RGBA_INTEGER` with
`INT`/`UNSIGNED_INT` (integer formats), `RGBA`/`FLOAT` (float formats, only with
`EXT_color_buffer_float`), plus one implementation-chosen format/type pair
(`IMPLEMENTATION_COLOR_READ_FORMAT`/`TYPE`). Reading an `R8` or `RG16F` target
directly with its own format, which desktop GL allows, fails on WebGL. The
`render_formats` scene reads several formats back, so either read as RGBA and
repack on the CPU in the backend's web path, or let that scene check only what
WebGL can read. Depth and stencil cannot be read with `readPixels` at all on
WebGL2.

### 3.8 Context creation

```js
const gl = canvas.getContext('webgl2', {
  antialias: false,          // zicr does its own MSAA through resolve attachments
  depth: true, stencil: true,
  alpha: true,
  premultipliedAlpha: false,
  preserveDrawingBuffer: false, // true only for tests that read the canvas
  powerPreference: 'high-performance',
});
```

The default framebuffer is the canvas: a swapchain pass on GL binds framebuffer 0
(`Swapchain.Native.gl`), which is the canvas drawing buffer in WebGL. The browser
presents it when control returns to the event loop, so a frame is
`requestAnimationFrame(frame)` → wasm `frame()` → `dev.commit()`. There is no
`present` call.

### 3.9 The Zig side of a freestanding build

- `std.log` and panics need a target: define `pub const std_options` with a
  `logFn` that calls an imported `console_log(ptr, len)`, and a `panic` handler that
  calls an imported `abort`-like function.
- `std.heap.wasm_allocator` grows memory with `memory.grow`; this is where cached
  JS views break (3.5).
- The scene suite's `main` uses `std.process.Init` and command line arguments;
  a web entry point should expose `export fn run(filter_ptr, filter_len) u32` (or
  similar) instead, and report results through an import.
- Shaders: WebGL2 is GLSL ES 3.00, which is the `glsl300es` slang already built for
  the non-compute shader file (`build.zig:180-181`). The compute shader file only
  has `glsl310es`, so the compute scenes must skip on WebGL (they already skip
  when `features.compute` is false).

### 3.10 Sources for this section

- WebGL 2.0 specification, especially section 5 "Differences between WebGL and
  OpenGL ES 3.0": <https://registry.khronos.org/webgl/specs/latest/2.0/>
- MDN WebGL2RenderingContext (method list, `getBufferSubData`):
  <https://developer.mozilla.org/en-US/docs/Web/API/WebGL2RenderingContext>
- MDN on `EXT_color_buffer_float` (also cited in sokol_gfx.h:11156):
  <https://developer.mozilla.org/en-US/docs/Web/API/EXT_color_buffer_float>
- Emscripten's WebGL library, the reference for handle tables and string handling:
  <https://github.com/emscripten-core/emscripten/blob/main/src/lib/libwebgl.js>
- `WEBGL_draw_instanced_base_vertex_base_instance`:
  <https://registry.khronos.org/webgl/extensions/WEBGL_draw_instanced_base_vertex_base_instance/>
- WebGL best practices (stalls, readback):
  <https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/WebGL_best_practices>

---

## 4. WebGPU in the browser

The native WebGPU backend (`src/gpu/backends/wgpu/`) talks to `webgpu.h`, the C
API of wgpu-native and Dawn. In the browser, WebGPU is a JavaScript API, so the
same backend needs a shim that implements the `webgpu.h` functions on top of
`navigator.gpu`. This is more work than the WebGL shim, for two reasons:
descriptors are nested C structs, and several operations are asynchronous.

### 4.1 How the backend gets its functions

Like GL, everything goes through `environment.wgpu.get_proc_address`:

```zig
// src/gpu/backends/wgpu/sdk.zig:948
pub fn loadProcs(get_proc_address: *const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque, user_data: ?*anyopaque) error{WgpuInitFailed}!Procs {
```

Each function in `Procs` is required (`orelse return error.WgpuInitFailed`), except
`wgpuDevicePoll`, which is optional (`backend.zig:128`). The approach is the same
as section 3.1: `extern "webgpu"` declarations, a comptime-generated
`get_proc_address`, and a JS import object.

### 4.2 Descriptors are C structs

`webgpu.h` passes descriptors as pointers to C structs, with nested pointers,
arrays, `WGPUStringView` (pointer + length) strings, and `nextInChain` chains of
extension structs (for example `WGPUShaderSourceWGSL` chained into
`WGPUShaderModuleDescriptor`). The JS side must decode them from wasm memory into
the JS dictionary that `GPUDevice.createRenderPipeline` and friends expect. That
decoding is most of the work, and every layout must match the Zig declarations in
`src/gpu/backends/wgpu/sdk.zig` exactly (field offsets, padding, enum values, which
differ between `webgpu.h` versions and the JS string enums).

Two ways to make it manageable:

- **Generate the decoders.** `sdk.zig` already declares every struct. A small Zig
  build tool can walk those types with `@typeInfo`, emit their offsets
  (`@offsetOf`) and field types, and generate the JS readers, so the layouts can't
  drift. Enums map from the numeric `webgpu.h` values to the JS string values
  (`WGPUTextureFormat_RGBA8Unorm` → `"rgba8unorm"`), which can be a generated table
  too.
- **Or reuse Dawn's `emdawnwebgpu`.** Dawn maintains the `webgpu.h`-on-JavaScript
  implementation that Emscripten uses (`library_webgpu.js` and its generated
  struct info). Even if zicr doesn't use Emscripten, that code is the best
  reference for every decoding rule and every enum mapping, and it tracks the
  current `webgpu.h`.

Objects again need handle tables (section 3.4): `WGPUDevice`, `WGPUBuffer`,
`WGPUTexture`, etc. are opaque pointers in C; on the web they become integer ids
into a JS table, which works because the backend never dereferences them.
Reference counting (`wgpu*AddRef`/`wgpu*Release`) has to be emulated: keep a
count per table entry and call `destroy()` where WebGPU has it
(`GPUBuffer.destroy`, `GPUTexture.destroy`) when it reaches zero.

### 4.3 Asynchronous operations: the real design question

The browser never lets wasm block until the GPU or the WebGPU implementation
finishes something; promises only resolve when control returns to the event loop.
Three places in zicr assume they can wait:

1. **Device creation.** `navigator.gpu.requestAdapter()` and
   `adapter.requestDevice()` return promises. This one is easy: do it in
   JavaScript before calling into wasm, and pass the device handle in, the same way
   the native harness passes a ready `WGPUDevice`.
2. **Buffer mapping for readback.** `Device.readBuffer`/`readImage` are
   synchronous. The backend maps a buffer and spins until the callback fires:

   ```zig
   // src/gpu/backends/wgpu/backend.zig:1580-1597
   fn awaitMap(self: *Backend, buf: sdk.Buffer, size: usize) bool {
       var wait: MapWait = .{};
       _ = self.procs.wgpuBufferMapAsync(buf, map_mode_read, 0, size, .{
           .mode = callback_mode_allow_spontaneous,
           .callback = onMapped,
           .userdata1 = &wait,
       });
       var spins: usize = 0;
       while (!@atomicLoad(bool, &wait.done, .acquire)) : (spins += 1) {
           if (spins > max_map_spins) return false;
           ...
   ```

   In a browser this loop never sees the callback: `GPUBuffer.mapAsync` resolves
   only after wasm returns. It spins `1 << 26` times and returns false. Options:

   - **Async readback API.** Add a non-blocking readback to the public API:
     `dev.requestRead(buffer, ...)` returns a ticket, `dev.pollRead(ticket)` returns
     the data once ready. It is also the better API on native backends: a
     renderer reading back GPU picking results or GPU timings should not stall
     the CPU on every read either. The synchronous `readBuffer` stays for tests and
     tools.
   - **JSPI (JavaScript Promise Integration).** Lets a wasm import suspend the wasm
     stack until a promise resolves, so `awaitMap` could call an import that awaits
     `mapAsync`. It keeps the synchronous API working unchanged, but it is a new
     wasm feature (shipped in Chrome; check the support status for other browsers
     before depending on it), and every export on the call path must be wrapped
     with `WebAssembly.promising`.
   - **Run in a worker with `Atomics.wait`.** The GPU device lives on the main
     thread or in another worker that resolves the promise and wakes the waiter
     through a `SharedArrayBuffer`. This needs cross-origin isolation headers
     (COOP/COEP) on the page, and moving GPU objects between workers is not allowed,
     so the design gets complicated fast.

   The async readback API is the recommendation: it is the right API for a
   renderer anyway, and the browser forces the question now.
3. **Error scopes.** `pushErrorScope`/`popErrorScope` return promises too. The
   native harness uses the uncaptured error callback; on the web, use
   `device.addEventListener('uncapturederror', ...)` and count errors in JS, which
   is asynchronous but enough for a test harness that waits a frame before
   reading the count.

### 4.4 Other differences from wgpu-native

- `wgpuDevicePoll` doesn't exist on the web (it is a wgpu-native extension). The
  backend already treats it as optional (`backend.zig:103-104, 128`).
- `wgpuGetProcAddress` is unimplemented in wgpu-native v29 (the harness uses
  `dlsym`), irrelevant on the web since the shim provides `get_proc_address`.
- `depth32float-stencil8` and other optional features must be requested in
  `requestDevice({ requiredFeatures })` in JS; the backend reads the device's
  features, so request everything the adapter has that zicr can use.
- Limits: browser WebGPU defaults are conservative (for example 8 storage
  buffers per shader stage, 256 MiB `maxBufferSize`, 128 MiB
  `maxStorageBufferBindingSize`); request the adapter's limits in
  `requiredLimits` if the scenes need more.
- The canvas: the swapchain is a `GPUCanvasContext` configured with
  `navigator.gpu.getPreferredCanvasFormat()` (usually `bgra8unorm`), and each frame
  takes `context.getCurrentTexture().createView()` as the swapchain view.
  `defaults.color_format` is required on WebGPU (`gpu.zig`, `Options.defaults`) and
  must match.
- WGSL reserved words: browsers enforce the same reserved word list wgpu-native
  does (section 13.3).

### 4.5 Sources for this section

- WebGPU specification: <https://www.w3.org/TR/webgpu/>
- WGSL specification (reserved words section): <https://www.w3.org/TR/WGSL/>
- `webgpu.h` headers: <https://github.com/webgpu-native/webgpu-headers>
- Dawn's Emscripten bindings (`emdawnwebgpu`):
  <https://dawn.googlesource.com/dawn/+/refs/heads/main/src/emdawnwebgpu/>
- JS Promise Integration proposal: <https://github.com/WebAssembly/js-promise-integration>
  and the V8 introduction: <https://v8.dev/blog/jspi>
- MDN `GPUBuffer.mapAsync`: <https://developer.mozilla.org/en-US/docs/Web/API/GPUBuffer/mapAsync>
- Browser support status: <https://caniuse.com/webgpu> and the WebGPU
  implementation status page: <https://github.com/gpuweb/gpuweb/wiki/Implementation-Status>

---

## 5. A browser test harness

The 29 scenes are the acceptance test for both browser backends, like every other
backend. What is needed:

1. A wasm build of the scene runner, `zig build check-scenes-web` or similar,
   producing `zicr-scenes.wasm` from a web entry point (section 3.9).
2. A static page (`tools/web/index.html` + `scenes.js`) that loads the wasm,
   creates the WebGL2 context or WebGPU device, instantiates the module with the
   shim imports, runs the scenes, and writes the results somewhere a test runner can
   read them (for example `window.__zicr_results` and the console).
3. A headless browser runner. Chromium with Playwright or Puppeteer (both Node) is
   the usual choice; a TypeScript runner script fits the "TS for tooling" idea.
   Chromium flags that matter in CI and on Linux:
   - WebGPU on Linux: `--enable-unsafe-webgpu --enable-features=Vulkan` (check
     current flags; they change between Chromium versions).
   - Headless GPU: `--use-angle=vulkan` or `--use-gl=angle`; without a GPU,
     SwiftShader (`--use-angle=swiftshader`, `--enable-unsafe-swiftshader`) gives a
     CPU WebGL2 and WebGPU implementation, the browser equivalent of lavapipe.
4. A `zig build test-web` step that serves the files (a tiny HTTP server, since
   `file://` pages can't fetch wasm in Chromium) and runs the runner.

Run the same scenes under at least Chromium and Firefox (WebGL2 everywhere;
WebGPU where shipped), since browser WebGL implementations (ANGLE in Chromium,
native GL or ANGLE in Firefox) differ in exactly the corners the scenes test
(readback formats, extension sets).

---

## 6. Direct3D 12 concerns

D3D12 is the only backend that is not a port: sokol_gfx has no D3D12 backend, so
there is no upstream code, test or user base behind it. It was written from
`src/gpu/backends/d3d12/DESIGN.md` and passes the 29 scenes under Wine with
vkd3d-proton. That is real evidence, but narrower than it sounds: vkd3d-proton is
a translation layer to Vulkan, not a Windows driver, and the D3D12 debug layer
did not run (6.10). Treat D3D12 as "works on one implementation, unreviewed
elsewhere" until it has run on native Windows.

### 6.1 Struct returns through COM: fixed, worth knowing

The first run crashed inside `d3d12core.dll`. `ID3D12DescriptorHeap::
GetCPUDescriptorHandleForHeapStart` and `GetGPUDescriptorHandleForHeapStart` return
a struct (`D3D12_CPU_DESCRIPTOR_HANDLE`, 8 bytes). The MSVC C++ ABI returns
structs from member functions through a hidden pointer, even when they would fit
in a register, so calling them like a C function that returns the struct in RAX
jumps to garbage. The fix:

```zig
// src/gpu/backends/d3d12/sdk.zig:393-403
pub fn heapStartCpu(object: *Object) CpuHandle {
    var out: CpuHandle = 0;
    _ = invoke(9, *const fn (*Object, *CpuHandle) callconv(call_conv) *CpuHandle, object, .{&out});
    return out;
}
```

This is a long-standing trap for anyone calling D3D12 from C (the old C headers
declared these methods wrongly; newer Windows SDK headers and the DirectX-Headers
repository fixed the C declarations). Any future method that returns a struct
(`ID3D12Resource::GetDesc`, `ID3D12Heap::GetDesc`, `ID3D12Device::
GetResourceAllocationInfo`, `GetAdapterLuid`, `GetCustomHeapProperties`) needs the
same treatment. A comptime check in `sdk.zig` that refuses `invoke` with a
struct return type would make the mistake impossible.

### 6.2 Suspected bug: deferred release can free resources the GPU still uses

**Found by reading the code; not reproduced by a scene yet.**

`releaseLater` tags a COM object with "the next fence value":

```zig
// src/gpu/backends/d3d12/backend.zig:297-300
pub fn releaseLater(self: *Backend, object: ?*sdk.Object) void {
    const value = object orelse return;
    self.deferred.append(self.allocator, .{ .fence_value = self.fence_value + 1, .item = .{ .object = value } }) catch sdk.release(value);
}
```

`fence_value + 1` is meant to be the value the current frame signals at
`submitFrame` (`backend.zig:259-268`). But one-shot submissions also increment the
same fence (`endOneShot`, `backend.zig:287-294`). Sequence:

1. The frame list records a draw that uses buffer B. `fence_value` is N.
2. B is destroyed. It is deferred with value N + 1.
3. Still in the same frame, another buffer is created with initial data. Its
   one-shot upload signals N + 1 and waits for it.
4. `commit` submits the frame list and signals N + 2.
5. The next `acquireFrame` calls `collectDeferred`: completed ≥ N + 1, so B is
   released, but the frame list using B (signal N + 2) may still be running on the
   GPU.

The same applies to `freeDescriptorLater` (`backend.zig:303-308`) for CPU
descriptors, though those are less dangerous since shader-visible copies are made
at bind time. Fix options: tag deferred items with a "pending frame" marker and
assign the real fence value in `submitFrame`; or give one-shot submissions their
own fence; or tag items with `max(fence_value + 1, value the current frame will
signal)` by recording the frame's value when it is acquired. A scene that destroys
a resource after using it and then creates a resource with data in the same frame
would catch it (section 14).

Also: when `deferred.append` fails, the code releases immediately
(`catch sdk.release(value)`), which is a use-after-free on the GPU in exactly the
out-of-memory situation; it should wait for idle first (`collectDeferred(true)`)
instead.

### 6.3 Suspected issue: one-shot writes reorder against the open frame

Unsealed writes and initial data go through a separate command list that executes
immediately (`commands.zig:365-377`), while the frame's command list executes only
at `commit`. Two consequences when a resource is used in the open frame before a
one-shot write to it in the same frame:

- **Ordering.** In program order the draw comes before the write, but on the GPU
  the write executes first, so the draw sees the new data. D3D11's
  `UpdateSubresource` and GL's `glBufferSubData` are ordered with draws, so the
  same program behaves differently on D3D12.
- **State tracking.** The tracked `D3D12_RESOURCE_STATES` reflect recording order
  across both lists. If the frame list recorded `COPY_DEST → VERTEX_AND_CONSTANT`
  and then the one-shot records `VERTEX_AND_CONSTANT → COPY_DEST`, the one-shot's
  "before" state is wrong at the time it executes (the frame list hasn't run). The
  debug layer reports this as an invalid barrier; drivers may corrupt or hang.

Whether this can happen depends on whether an unsealed resource can be bound
before it is sealed. `gpu.zig:679` accepts handles in the `.unsealed` state, so it
looks possible. Either validate that unsealed resources can't be used in passes
(the clean rule: unsealed = CPU-initialization phase), or make one-shot writes
submit the open frame list first (then the write runs after the earlier draws), or
record unsealed writes into the frame list through the upload ring like transient
writes. Decide the rule in the public API docs, then add a scene for it.

### 6.4 One-shot uploads stall the CPU

Every buffer or image created with data, and every unsealed write, does
`ExecuteCommandLists` + `Signal` + wait (`endOneShot`). Loading 1,000 textures
means 1,000 full GPU round trips. Fine for tests; slow for a renderer loading a
scene. Better: batch uploads into one list per frame (or per "upload batch") and
submit them before the frame's list, or use a separate copy queue
(`D3D12_COMMAND_LIST_TYPE_COPY`) with a fence the direct queue waits on
(`ID3D12CommandQueue::Wait`), which overlaps uploads with rendering. Vulkan's
backend has the same one-shot design, inherited from sokol; it should get the
same treatment.

### 6.5 Whole-resource state tracking

Each buffer and image tracks one state for the whole resource (DESIGN.md
"Resource states"). That can't express a texture whose mip 0 is a shader resource
while mip 1 is a render target (mip generation by rendering, or rendering into one
array layer while sampling another). Today validation rejects binding an image that is
also an attachment of the current pass (`validate_abnd_texture_binding_vs_color_attachment`
and its depth/resolve variants), so the scenes can't hit it, but a renderer will
want it. Per-subresource tracking (or enhanced barriers,
6.8) will be needed eventually.

### 6.6 Root signatures and descriptor copies

- Root signature version 1.0 (`D3D12SerializeRootSignature`) treats all descriptors
  as volatile. Version 1.1 (`D3D12SerializeVersionedRootSignature`) lets the
  driver assume descriptors and data are static while a command list executes
  (`DATA_STATIC_WHILE_SET_AT_EXECUTE` is the 1.1 default), which some drivers use for
  optimizations. Moving to 1.1 is a small change.
- `applyBindings` allocates fresh shader-visible descriptor ranges and copies all
  descriptors from the CPU heaps on every call (`CopyDescriptorsSimple`). That's the
  simple and correct approach; the costs are per-draw descriptor copies and heap
  pressure. Caching tables keyed by the binding set, or moving to bindless
  (shader model 6.6 `ResourceDescriptorHeap`) later, are the fast paths.
- The shader-visible sampler heap can hold at most 2048 samplers. Check what the
  backend does when a frame's ring slice runs out (the Vulkan backend logs
  `vulkan_descriptor_buffer_overflow`); it should log a D3D12 equivalent and skip
  the draw, never write past the ring.

### 6.7 Shaders: FXC and shader model 5.0 only

D3D12 shaders are compiled at runtime with `D3DCompile` from `d3dcompiler_47.dll`
(shared code in `src/gpu/backends/d3d11/compiler.zig:18-19`) to DXBC shader model
5.0. That works on every D3D12 device, but:

- FXC is frozen. Shader model 6.x (wave intrinsics, 16-bit types, bindless
  `ResourceDescriptorHeap`, mesh and amplification shaders, ray tracing) needs DXC
  and DXIL. sokol-shdc only emits HLSL 4/5 source today, so moving to SM6 means
  either compiling sokol-shdc's HLSL with DXC (the HLSL dialect is close enough
  for simple shaders) or another shader route (section 13.4).
- Runtime compilation costs startup time and needs `d3dcompiler_47.dll` present
  (it ships with Windows 10+). Compiling to bytecode at build time is better;
  sokol-shdc's bytecode output needs a Windows host, so a cross-platform build
  would need DXC (which runs on Linux) or bundling FXC bytecode produced on a
  Windows CI runner.
- Shader compile errors on D3D12 are logged with the D3D11 compiler's log items
  (`d3d11_*`), which is confusing in diagnostics. Give the shared compiler a log
  item set per backend, or neutral `hlsl_*` items.

### 6.8 Barriers

The backend uses legacy resource barriers (`ResourceBarrier` with
`D3D12_RESOURCE_STATES`). Enhanced barriers (Agility SDK, `ID3D12GraphicsCommandList7::
Barrier`) are closer to Vulkan's sync2 model (separate sync, access and layout),
avoid some unnecessary flushes, and make per-subresource layouts natural. They
need a recent Agility SDK/driver, so they'd be an optional fast path, not a
replacement.

### 6.9 Texture footprints are computed by hand

The design said `GetCopyableFootprints`; the implementation computes footprints
analytically (256-byte row pitch alignment, 512-byte placement alignment,
`commands.zig:330-335`). That's correct for the formats the scenes use, but
`GetCopyableFootprints` is the authority, and the hand-written version should be
checked against it for block-compressed formats (rows are block rows, BC1 is 8
bytes per 4×4 block) and 3D textures. A unit test calling both on Windows would
settle it. Also note `memory.zig:53`: `free_list.append(...) catch {}` silently
loses a descriptor slot when the append fails.

### 6.10 Validation coverage

- vkd3d-proton does not implement `ID3D12InfoQueue`, so the harness counts 0
  native errors there (`tools/harness/d3d12.zig`: "hardware (info queue
  unavailable)"). A passing D3D12 scene run under Wine is therefore not evidence of
  clean API usage.
- As a substitute, the Khronos Vulkan validation layer was run under vkd3d-proton:
  about 135 error groups per run, all from vkd3d-proton's own translation (image
  layouts with value 1000620000, private `pNext` structures with type 1000584002,
  memory allocate flags 0xa), none pointing at zicr's resource states or
  descriptors. That rules out gross misuse, not subtle D3D12 rule violations.
- On native Windows, run with the debug layer and also **GPU-based validation**
  (`ID3D12Debug1::SetEnableGPUBasedValidation(TRUE)`), which checks descriptor
  contents and resource states at execution time and catches what the CPU-side
  layer can't. Enable DRED (Device Removed Extended Data) to get breadcrumbs when
  a device is removed.

### 6.11 Things not exercised at all

- **Swapchain passes.** The code path exists (`commands.zig:64-80`: RTV/DSV in
  reserved per-frame slots, `PRESENT` ↔ `RENDER_TARGET` transitions) but no scene
  renders to a real swapchain. Flip-model swapchains (`DXGI_SWAP_EFFECT_FLIP_DISCARD`)
  cannot be multisampled, so MSAA rendering to the screen needs a resolve target,
  which the API supports (`resolve_target`). Add a windowed smoke test (section 14).
- **Device removal.** Nothing handles `DXGI_ERROR_DEVICE_REMOVED` /
  `DEVICE_HUNG`. A renderer needs to at least report it; recovering means
  recreating the device and all resources, which the public API has no story for
  yet (same for Vulkan `VK_ERROR_DEVICE_LOST` and WebGPU device loss).
- **Adapter choice.** The harness uses the default adapter at feature level 11_0
  with no WARP fallback. The library itself takes the device from the
  application, so this only matters for the harness and for documentation: show
  how to pick an adapter with `IDXGIFactory6::EnumAdapterByGpuPreference`.
- **Readback** waits for the GPU to be idle, by design (synchronous API).

### 6.12 Testing it under Wine: what to know

Wine's built-in `d3d12` (vkd3d) needs Wine's own `dxgi.dll`. On this Fedora system
the `wine-dxgi` alternative points to DXVK's `dxgi.dll`
(`/etc/alternatives/wine-dxgi`), which lacks the interface vkd3d needs
(`IDXGIVkInteropAdapter`), so `D3D12CreateDevice` fails with `E_NOINTERFACE`. The
workaround used, without root: copy vkd3d-proton's `d3d12.dll` and
`d3d12core.dll` (from Steam's Proton Experimental,
`files/lib/wine/vkd3d-proton/x86_64-windows/`) next to the test executable and run
with `WINEDLLOVERRIDES="d3d12,d3d12core=n"`. vkd3d-proton works on top of DXVK's
DXGI. See section 17 for the full command.

### 6.13 Sources for this section

- `GetCPUDescriptorHandleForHeapStart`:
  <https://learn.microsoft.com/en-us/windows/win32/api/d3d12/nf-d3d12-id3d12descriptorheap-getcpudescriptorhandleforheapstart>
- DirectX-Headers (current C/C++ headers): <https://github.com/microsoft/DirectX-Headers>
- Uploading texture data and footprint alignments:
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/upload-and-readback-of-texture-data>
- Root signatures and version 1.1:
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signatures> and
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/root-signature-version-1-1>
- Resource barriers: <https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-resource-barriers-to-synchronize-resource-states-in-direct3d-12>
- Enhanced barriers: <https://microsoft.github.io/DirectX-Specs/d3d/D3D12EnhancedBarriers.html>
- GPU-based validation: <https://learn.microsoft.com/en-us/windows/win32/direct3d12/using-d3d12-debug-layer-gpu-based-validation>
- DRED: <https://learn.microsoft.com/en-us/windows/win32/direct3d12/use-dred>
- DirectX Shader Compiler (DXC): <https://github.com/microsoft/DirectXShaderCompiler>
- vkd3d-proton: <https://github.com/HansKristian-Work/vkd3d-proton>
- Flip model and MSAA: <https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-flip-model>

---

## 7. Direct3D 11 concerns and its removal

The decision is to remove D3D11 once D3D12 works. These are the concerns to weigh
before and while doing that.

### 7.1 D3D11 has also never run on native Windows

D3D11 passes 29/29 under Wine + DXVK, which translates D3D11 to Vulkan. That
tests zicr's use of the D3D11 API against DXVK's interpretation of it, not against
Microsoft's runtime or a Windows driver. The D3D11 debug layer
(`D3D11_CREATE_DEVICE_DEBUG`) didn't run either. So today both Windows backends
share the same caveat; neither is a better-verified fallback than the other.

### 7.2 D3D12 reuses D3D11 code

The D3D12 backend imports from the D3D11 directory:

- `src/gpu/backends/d3d11/compiler.zig`: the `D3DCompile` loader and HLSL
  compilation (6.7).
- `src/gpu/backends/d3d11/convert.zig`: DXGI format and enum conversions.
- `src/gpu/backends/d3d11/constants.zig`: DXGI constants.
- `src/gpu/backends/d3d11/sdk.zig`: `Object`, `Guid`, `invoke`, `release` and blob
  helpers (the COM calling machinery).
- `WindowsLibrary` (DLL loading) used by both and by the GL Win32 loader.

So "remove D3D11" is really "move the shared DXGI/COM/HLSL code to
`src/gpu/backends/dxgi/` (or `windows/`), then delete the D3D11-only parts":
`backend.zig`, `resources.zig`, the D3D11 parts of `sdk.zig`, the D3D11 log items
(`d3d11_*` in `enums.zig` and `log.zig`), `types.zig`'s `D3d11Environment`/
`D3d11Swapchain`, `BackendOptions.d3d11` in `gpu.zig`, the `.d3d11` arms in
`backend.zig`, `core.zig`'s `Native.d3d11`, `tools/d3d11_smoke.zig`,
`tools/harness/d3d11.zig`, the `check-d3d11` build step, and the `.d3d11` entries
in `platform_variants` (`tools/scenes/main.zig:28`). Validation keeps working
through `isD3d()`; check every `.d3d11` comparison in `validation.zig` and
`defaults.zig` (`git grep -n d3d11`).

Note that `e.Backend` values are part of the internal enum layout ported from
sokol (`d3d12 = 9`). Removing `d3d11` from the public enum is fine; renumbering the
internal one would break the upstream tests' expectations, so leave the internal
value in place or keep it as an unused tag.

### 7.3 What D3D11 still does that D3D12 doesn't

Removing D3D11 is a product decision, and these are the costs:

- **Reach.** D3D11 runs on Windows 7+ and on hardware back to feature level 10;
  D3D12 needs Windows 10+ and a D3D12 driver. Steam's hardware survey shows that
  nearly all gaming PCs today run Windows 10/11 with D3D12-capable GPUs, so the
  practical loss is small, but not zero (old laptops, some VMs, Remote Desktop
  sessions on older servers).
- **WARP.** D3D11's WARP software rasterizer is the universal fallback on
  machines without a usable GPU (CI runners, VMs). D3D12 has WARP too
  (`IDXGIFactory4::EnumWarpAdapter`), so this is covered, but the harness doesn't
  implement it yet (6.11). GitHub's Windows runners have no GPU, so WARP is how CI
  would run the scenes there.
- **Maturity.** D3D11's port is sokol's code, used in production by many
  projects. D3D12 is new and has two suspected bugs today (6.2, 6.3).
- **Simplicity.** D3D11 drivers do the memory management, hazard tracking and
  residency that D3D12 makes the application do. Every D3D12 bug class in this
  document (deferred release, state tracking, ordering) is impossible on D3D11.

Recommendation: before deleting D3D11, (1) fix 6.2 and 6.3, (2) run the scene
suite on native Windows with the D3D12 debug layer and GPU-based validation, and
(3) add D3D12 WARP to the harness so CI can run it. Then delete D3D11 in one
commit that moves the shared code. Keeping D3D11 in git history means it can be
restored if a real user needs it.

### 7.4 D3D11-specific notes, in case it stays longer

- `d3dcompiler_47.dll` runtime compilation, same as 6.7.
- `BackendOptions.d3d11.shader_debugging` exists; D3D12 has no equivalent option
  yet (it would compile with `D3DCOMPILE_DEBUG | D3DCOMPILE_SKIP_OPTIMIZATION`).

---

## 8. Vulkan

### 8.1 It requires `VK_EXT_descriptor_buffer`

The Vulkan backend (ported from sokol) uses descriptor buffers, not descriptor
sets:

```zig
// src/gpu/backends/vulkan/backend.zig:115
d.vkGetDescriptorEXT == null or d.vkCmdBindDescriptorBuffersEXT == null or d.vkCmdSetDescriptorBufferOffsetsEXT == null)
```

and it also needs Vulkan 1.3 core features: dynamic rendering, synchronization2,
buffer device address. Descriptor buffers are supported on recent desktop
drivers (Mesa RADV/ANV, NVIDIA, AMD), but coverage on Android and on some older
Windows drivers is poor. Check <https://vulkan.gpuinfo.org/> for the current
numbers before deciding. A descriptor-set fallback (classic
`vkUpdateDescriptorSets` or `VK_KHR_push_descriptor`, which is widely supported
including on Android) is needed for Vulkan to be "the Android backend". The
descriptor layout logic is localized in the backend, so the fallback can be a
second binding strategy selected at init.

### 8.2 No Vulkan on Windows in the scene suite

`tools/harness/vulkan.zig` uses `std.DynLib`, which Zig 0.17 doesn't support on
Windows, so the harness is Linux-only (`harness.zig`: `if (builtin.os.tag ==
.linux)`), and the Windows scene build drops the `vulkan` variant even though
`platform_variants` lists it. Fix: load `vulkan-1.dll` with `WindowsLibrary`
(already used by the D3D backends and the GL Win32 loader), the same way the D3D12
harness loads `d3d12.dll`.

### 8.3 Verified on two drivers, both Mesa

RADV and lavapipe are both Mesa. NVIDIA's and Intel's (ANV) drivers, MoltenVK on
macOS and Android drivers (Qualcomm Adreno, ARM Mali) have different bugs and
stricter or looser behavior. The validation layer catches most portability
issues, but running on at least one non-Mesa driver matters.

### 8.4 Smaller items

- Synchronization validation (`VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT`)
  is not enabled in the harness; it finds missing barriers and hazards that the
  default validation doesn't. Enable it for a run and fix what it reports.
- The one-shot staging copies wait on the GPU, like D3D12 (6.4).
- Pipeline caches (`VkPipelineCache`) are not used; creating many pipelines at
  load time would benefit, and persisting the cache across runs is a common
  startup optimization.

---

## 9. WebGPU (native)

- **wgpu-native only.** Dawn (Chrome's implementation, also usable natively) has
  not been tried. Both implement `webgpu.h`, but they disagree in corners
  (default limits, error reporting, how callbacks fire). Running the scenes on
  Dawn would catch zicr code that depends on wgpu-native behavior, and Dawn is
  closer to what the browser backend will see.
- **The map wait spins.** `awaitMap` (`backend.zig:1580-1597`) polls with
  `wgpuDevicePoll` when the library has it, and otherwise spins up to `1 << 26`
  times with `spinLoopHint`. With Dawn, the right tool is `wgpuInstanceWaitAny` with
  a `WGPUFuture` (`WGPUCallbackMode_WaitAnyOnly`), the standard `webgpu.h` way to
  block on a future. Moving to futures would make the backend portable across
  wgpu-native and Dawn.
- **`wgpuGetProcAddress` is unimplemented in wgpu-native v29**, so the harness
  resolves functions with `dlsym`. Applications using zicr with wgpu-native need to
  know this; document it in the `BackendOptions.wgpu` doc comment.
- **Validation errors abort the process.** A WGSL error in a shader made
  wgpu-native panic in `wgpuQueueSubmit` and abort the whole scene run (13.3). The
  harness can't recover in-process. Use an error scope around shader module and
  pipeline creation (or `wgpuShaderModuleGetCompilationInfo`), so zicr's
  `createShader` fails cleanly instead of the submit aborting later.
- **`webgpu.h` churn.** The header changed significantly in 2024-2025
  (`WGPUStringView`, callback info structs, futures). The bindings in `sdk.zig`
  match wgpu-native v29; pin the version in the docs and expect to update the
  bindings with each wgpu-native/Dawn release until webgpu.h is declared stable.

---

## 10. OpenGL and GLES

### 10.1 Why GL stays

The original intent was to drop OpenGL as an old API. It stays for two reasons:
WebGL2 is the most widely available browser graphics API, and the WebGL2 backend
is the GLES path of the GL backend; and part of the Android market still lacks a
usable Vulkan driver. Desktop GL itself is the least important GL target: on
Windows, D3D12 and Vulkan cover it; on macOS, GL is deprecated and stuck at 4.1;
on Linux, Vulkan covers it.

### 10.2 Texture views need GL 4.3

Views with a mip or layer range need `glTextureView` (GL 4.3,
`backend.zig:69`). Without it, which includes all of GLES and WebGL2, a view's mip
range is ignored and the whole texture is bound (documented sokol behavior). The
`texture_mip_levels` scene gates that check. An emulation is possible with
`GL_TEXTURE_BASE_LEVEL`/`GL_TEXTURE_MAX_LEVEL` set at bind time (works on GLES
3.0 and WebGL2 for mip ranges, not for layer ranges), at the cost of state
changes when the same texture is bound through different views.

### 10.3 macOS GL

macOS supports only GL 4.1 core: no compute, no storage buffers, no texture
views, no base instance. The Metal backend is the macOS target; GL on macOS is
not worth testing beyond "it compiles".

### 10.4 No GL debug output in the harness

The GL harness counts no native errors (GL has no validation layer). Wiring
`KHR_debug` (`glDebugMessageCallback`, with a debug context created through EGL)
into `tools/harness/egl.zig` would give GL the same "native errors fail the scene"
rule as Vulkan and WebGPU. Mesa's debug output reports many real misuse cases.

### 10.5 GL legacy contexts

GL 3.3 and GLES 3.0 contexts (`gl_legacy`, `gles_legacy` variants) pass the smoke
tests but aren't in the default scene run. Add them to `platform_variants` on
Linux (GLES 3.0 is also the closest native approximation of WebGL2).

---

## 11. Metal

The Metal backend is a port of sokol's and has been type-checked for macOS and
iOS (`zig build check-metal`), but it has never run. Type checking catches
signature errors, not wrong Objective-C selectors, wrong enum values or wrong
struct layouts. One class of errors was already found by review (the ETC2/EAC/ASTC
pixel format values were wrong and are fixed: `EAC_R11Unorm = 170`, ...,
`ASTC_4x4_LDR = 204`). Expect more of the same.

What's needed:

- A Metal harness context (`tools/harness/metal.zig`): `MTLCreateSystemDefaultDevice`,
  plus the scene runner built for macOS.
- A Mac to run it on. GitHub's `macos-14` and later runners are Apple Silicon;
  check that they expose a Metal device in CI before relying on them.
- Metal's API validation (`MTL_DEBUG_LAYER=1`) and shader validation
  (`MTL_SHADER_VALIDATION=1`) environment variables, counted as native errors like
  the other harnesses do.
- iOS: the simulator has its own Metal implementation with different limits
  (sokol already special-cases it); a device run is the real test.

Until it runs, Metal should be listed as unverified, as the README does.

---

## 12. Core and public API

### 12.1 One device per process

The public API wraps sokol's global state:

```zig
// src/gpu/gpu.zig:235, 283-284
var context: ?Context = null;
...
pub fn init(allocator: std.mem.Allocator, options: Options) InitError!Device {
    if (context != null) return error.DeviceAlreadyExists;
```

and the core keeps a single global `State` (`core.state()`). So zicr supports
exactly one device per process. For a rendering library that's a real limit:
tools with several windows on different GPUs, an editor with an offscreen device
for thumbnails, tests that run in parallel threads, and libraries that use zicr
internally while the application uses it too all need several devices. Making
`State` a field of `Device` (and passing it through the core instead of the global)
is a large mechanical change in `core.zig`, `api.zig`, `validation.zig` and the
backends, best done before the renderer is written on top.

### 12.2 Threading

Nothing in zicr is thread-safe, as in sokol. That's a fine rule for a first
version, but it must be documented in the public API, and the renderer will want
at least: resource creation from loader threads, and command recording on
several threads (D3D12, Vulkan and Metal all support it natively). The design of
the per-device state (12.1) should leave room for it.

### 12.3 Readback is synchronous

`Device.readBuffer`/`readImage` wait for the GPU. That is correct for tests and
for tools, wrong for a renderer's per-frame reads (GPU picking, occlusion results,
timings), and impossible in the browser (4.3). Add an asynchronous readback API.

### 12.4 Errors and device loss

Resource creation returns `error.PoolExhausted`, `error.InvalidDescriptor`,
`error.CreationFailed`. Commands with invalid state are skipped and reported.
What's missing: a way to learn that the device is lost (D3D12 removed, Vulkan
`VK_ERROR_DEVICE_LOST`, WebGPU device lost, GL context lost on the web, which
WebGL does routinely when the tab is backgrounded on mobile) and a recovery story.

### 12.5 Validation policy

`Options.validation` is `.off`, `.report` or `.fatal`, applied at runtime by
`validated()` (`gpu.zig:272-280`). Validation code is compiled out entirely
without the `debug` build option. Make sure the default (fatal in debug builds,
off in release) is what users expect, and document that the diagnostics callback
receives every message.

### 12.6 Limits and features

`portable_limits` clamps limits to what every backend supports, which is what a
renderer that wants identical behavior everywhere should use. The scene suite
should run at least once with `portable_limits = true` to keep that path honest.

---

## 13. Shader pipeline

### 13.1 How it works

`build.zig` runs sokol-shdc (fetched as the lazy dependency `sokol_tools_bin`,
`build.zig.zon`) with `-f bare_yaml` for every backend's slang at once, then
`tools/shdc/main.zig` reads the YAML and the generated sources and emits one Zig
module per input file. Slang sets (`build.zig:178-181`):

- render shaders: `glsl410:glsl300es:hlsl5:metal_macos:metal_ios:metal_sim:wgsl:spirv_vk`
- compute shaders: `glsl430:glsl310es:hlsl5:metal_macos:metal_ios:metal_sim:wgsl:spirv_vk`

### 13.2 Concerns

- **External binary.** sokol-shdc is a prebuilt binary from a pinned commit of
  `sokol-tools-bin` for Linux, macOS (x64/arm64) and Windows. It works, but
  zicr's build depends on a binary blob, and hosts without a prebuilt (Linux on
  RISC-V, FreeBSD) can't build shaders. Longer term, a Zig-native shader pipeline
  (13.4) removes it.
- **YAML parsing.** `tools/shdc/main.zig` parses a subset of YAML, written for
  sokol-shdc's output, including a quirk where some values have a trailing `;`.
  A sokol-shdc update could produce YAML the parser doesn't expect; when updating
  the pinned binary, re-run all shader-using tests.
- **Rules discovered along the way**, worth documenting for zicr users:
  - texture names must be unique per shader file;
  - no unsigned integer uniform types (sokol-shdc restriction);
  - compute shader threadgroup sizes must be multiples of 32 for Metal;
  - identifiers must avoid reserved words of every target language (13.3).

### 13.3 Reserved words across targets

A storage image named `target` in `tools/scenes/compute.glsl` compiled fine for
GLSL, HLSL, MSL and SPIR-V, but `target` is reserved in WGSL, and sokol-shdc
passed it through unchanged. wgpu-native rejected the shader at queue submit and
aborted the process. The name is now `dst_image`. The generator could check
identifiers in the generated reflection against the WGSL, HLSL and MSL reserved
word lists and fail the build with a clear message; that's cheap and turns a
runtime abort into a build error.

### 13.4 Longer-term options

- **Slang** (<https://shader-slang.org/>) compiles one language to SPIR-V, DXIL,
  MSL, WGSL and GLSL, supports modules and generics, and is maintained by Khronos.
  It would give D3D12 SM6 (6.7).
- **Naga** (wgpu's shader translator) handles WGSL/SPIR-V/GLSL to
  MSL/HLSL/GLSL/WGSL/SPIR-V, used in production by wgpu.
- Staying with sokol-shdc is fine until the renderer needs features it lacks
  (SM6, bindless, mesh shaders).

---

## 14. Test suite gaps

Scenes that would have caught or will catch real problems:

- **Destroy after use, then create with data, in one frame** (D3D12 6.2).
- **Draw, write unsealed, draw again, in one frame**, if the API allows it (6.3).
- **Swapchain rendering** with a real window on each backend (6.11): a windowed
  smoke test per platform that renders a few frames and reads back the last one.
- **Many frames.** All scenes are single-frame. A scene running 100 frames with
  transient writes each frame exercises frame-slot recycling, upload ring
  wraparound and deferred release; most frame-in-flight bugs only show up there.
- **Resource churn.** Create and destroy thousands of resources across frames;
  catches leaks and descriptor free-list bugs (6.9).
- **Pool exhaustion and descriptor heap/ring overflow** on real backends, not
  only on the dummy backend.
- **Formats.** Block-compressed formats (BC1-7, ETC2, ASTC) are not in the scene
  suite at all; they test footprints (6.9), pixel format capability detection and
  the Metal enum values (11).
- **Samplers.** Anisotropy, border colors, comparison samplers (shadow maps).
- **Dual-source blending**, **MSAA texture bindings**, **storage image formats
  other than rgba8**, **instanced draws with base instance**.
- **Large dispatches and indirect draws**, once the API has them.
- **Run with `portable_limits = true`** (12.6).
- **The differential fuzzer only covers the dummy backend.** A variant that runs
  the same random streams on a real backend and only checks "no crash, no native
  validation error" would turn it into a robustness test for backends.

---

## 15. Performance

Nothing has been measured yet. The goal is "the best and fastest", and the first
baseline is C sokol_gfx on the same machine:

1. Build C sokol_gfx (already compiled into `tools/diff/` for the dummy backend)
   with each real backend in a small benchmark executable.
2. Benchmarks: draw-call throughput (10k-100k draws with changing bindings and
   uniforms), resource creation/destruction rate, transient upload bandwidth,
   readback latency. Measure CPU time per frame with the GPU work kept trivial, so
   the comparison is about zicr's overhead.
3. Run zicr's equivalent through the public API and the raw API.
4. Track results in the repo (a `bench/` directory and a results file), so
   regressions show up.

Known places where zicr is likely slower than it could be, from reading the code:
one-shot uploads waiting per resource (6.4, 8.4), per-draw descriptor copies on
D3D12 (6.6), the validation wrapper cost when validation is on (it should be off
for benchmarks), and the bind group cache on WebGPU (inherited from sokol, cache
size `bindgroups_cache_size = 1024`).

---

## 16. Documentation and housekeeping

- **PORTING.md is out of date.** It still describes the `complete-port` stage: the
  module `sokol_gfx`, `root.zig`, `gfx.setup(...)`. It should describe the current
  layout (`src/gpu/`, `internal.zig`, `zicr.gpu.raw`) and keep the section-by-
  section mapping to sokol_gfx.h, which is still accurate.
- **The public API needs doc comments** on every type and function in
  `src/gpu/gpu.zig`, written for zicr users, not in sokol terms. `zig build docs`
  (Zig's autodoc) could then publish them.
- **CONTRACT.md** (`src/gpu/backends/CONTRACT.md`) should mention the readback
  methods' synchronization expectations and the D3D12 backend.
- **The design doc for D3D12** should be kept in sync with the implementation,
  including the fixes for 6.2 and 6.3.
- **CI.** None exists. A GitHub Actions workflow with `zig build check test
  test-upstream check-metal check-scenes-windows` on Linux is easy; scenes on
  lavapipe (Vulkan) and Mesa llvmpipe (GL) can run without a GPU; D3D12 WARP on a
  Windows runner (7.3); Metal on a macOS runner (11).

---

## 17. Test environment

How the backends were tested on the development machine (Fedora 44, Mesa 26.2.4,
AMD Radeon RENOIR iGPU, Zig 0.17, Wine 11).

**GL / GLES**: surfaceless EGL through Mesa; nothing to install beyond Mesa.

```sh
zig build test-gl
zig build test-scenes -- --backend gl --backend gles
```

**Vulkan**: the system loader (`libvulkan.so.1`). The validation layer comes from
the `vulkan-validation-layers` package (or any `VkLayer_khronos_validation.json`
manifest; `VK_ADD_LAYER_PATH` adds a directory containing one). lavapipe is
Mesa's CPU Vulkan driver, selected with `VK_DRIVER_FILES`:

```sh
VK_ADD_LAYER_PATH=/path/to/layer/dir zig build test-scenes -- --backend vulkan
VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.x86_64.json VK_ADD_LAYER_PATH=/path/to/layer/dir \
  zig build test-scenes -- --backend vulkan
VK_LOADER_DEBUG=layer ...   # to confirm the layer is loaded
```

**WebGPU (native)**: download a wgpu-native release
(<https://github.com/gfx-rs/wgpu-native/releases>, v29.0.1.1 was used) and point
`WGPU_NATIVE_LIB` at `libwgpu_native.so`:

```sh
WGPU_NATIVE_LIB=/path/to/libwgpu_native.so zig build test-scenes -- --backend wgpu
```

**D3D11 and D3D12 under Wine**: build the Windows scene runner, then run it with
Wine. A virtual X server is enough (`Xvfb :97`). D3D11 uses the system DXVK.
D3D12 needs vkd3d-proton next to the executable (6.12):

```sh
zig build check-scenes-windows
mkdir -p d3d12run && cp zig-out/bin/zicr-scenes.exe d3d12run/
cp "$PROTON/files/lib/wine/vkd3d-proton/x86_64-windows/"{d3d12,d3d12core}.dll d3d12run/
cd d3d12run
DISPLAY=:97 WINEPREFIX=$HOME/.cache/zicr-wine WINEDEBUG=-all \
  WINEDLLOVERRIDES="d3d12,d3d12core=n" VKD3D_DEBUG=warn \
  wine zicr-scenes.exe --backend d3d12
DISPLAY=:97 WINEPREFIX=$HOME/.cache/zicr-wine WINEDEBUG=-all wine zicr-scenes.exe --backend d3d11
```

where `$PROTON` is Proton Experimental's directory in the Steam library. A Wine
prefix takes about 1.6 GB; keep it out of a RAM-backed `/tmp`.

**Metal**: `zig build check-metal` (type check only, 11).

---

## 18. Sources

General references used throughout:

- sokol (the original library, its tests and its design notes):
  <https://github.com/floooh/sokol>, and the author's blog posts on sokol_gfx's
  design: <https://floooh.github.io/>
- sokol-tools / sokol-shdc: <https://github.com/floooh/sokol-tools>
- Vulkan specification and extension reference: <https://registry.khronos.org/vulkan/>
- `VK_EXT_descriptor_buffer`:
  <https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_descriptor_buffer.html>
- Vulkan hardware database (extension coverage by device): <https://vulkan.gpuinfo.org/>
- Khronos validation layer: <https://github.com/KhronosGroup/Vulkan-ValidationLayers>
- Direct3D 12 programming guide:
  <https://learn.microsoft.com/en-us/windows/win32/direct3d12/directx-12-programming-guide>
- Direct3D 11 programming guide:
  <https://learn.microsoft.com/en-us/windows/win32/direct3d11/atoc-dx-graphics-direct3d-11>
- DXVK: <https://github.com/doitsujin/dxvk>
- vkd3d-proton: <https://github.com/HansKristian-Work/vkd3d-proton>
- Metal: <https://developer.apple.com/documentation/metal>, and Apple's notice
  deprecating OpenGL on macOS: <https://developer.apple.com/documentation/opengl>
- OpenGL ES 3.2 and WebGL 2.0 specifications: <https://registry.khronos.org/OpenGL/>
  and <https://registry.khronos.org/webgl/specs/latest/2.0/>
- WebGPU and WGSL: <https://www.w3.org/TR/webgpu/>, <https://www.w3.org/TR/WGSL/>
- wgpu-native: <https://github.com/gfx-rs/wgpu-native>; Dawn: <https://dawn.googlesource.com/dawn>
- Slang: <https://shader-slang.org/>; Naga: <https://github.com/gfx-rs/wgpu/tree/trunk/naga>
- Steam Hardware & Software Survey (OS and GPU share):
  <https://store.steampowered.com/hwsurvey>
