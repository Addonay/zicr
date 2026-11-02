# Ordered 2D renderer

`@import("zicr").render2d` draws textured quads, atlas regions and colored
rectangles. It supports affine transforms, tint, an orthographic world rectangle,
source-over alpha blending, nested pixel clips and offscreen targets. The
application owns the scene, window, native device and presentation.

**Status: full 2D rendering is in progress.** The current implementation includes
solid vector path fills with analytic coverage, in addition to the quad layer.
Strokes, gradient/pattern paints, complete compositing/layers, arbitrary masks,
fonts/text and effects are required unfinished work, tracked in the
[full capability ledger](../../tasks/FULL_2D.md). The earlier quad checkpoint is
not completion of this goal.

## Build shaders

The GPU module alone does not require a shader compiler. Applications using the
2D renderer generate its shader descriptors at build time:

```zig
const zicr_build = @import("zicr");
const dep = b.dependency("zicr", .{ .target = target, .optimize = optimize });
const zicr = dep.module("zicr");
app.root_module.addImport("zicr", zicr);
if (zicr_build.addRender2dShaderModule(b, dep, zicr)) |shaders| {
    app.root_module.addImport("render2d_shaders", shaders);
}
```

The nullable result follows the existing lazy shader dependency convention. On
hosts without a bundled compiler, configure the dependency's `shader-compiler`
option, or call `addShaderModule` directly with `ShaderOptions.compiler` and
`dep.path("src/render2d/shaders.glsl")`. Native library-only builds remain usable
without shader tooling. The generated module exports `quad.desc(backend)` and a
`quad.glsl330` descriptor for GL 3.3 contexts.

## Application API

```zig
const r2 = @import("zicr").render2d;
const shaders = @import("render2d_shaders");

var renderer = try r2.Renderer.init(&device,
    shaders.quad.desc(device.backend()) orelse return error.UnsupportedBackend,
    .{ .max_quads = 16384, .color_format = .rgba8 });
defer renderer.deinit();
var draws = try r2.DrawList.init(allocator, .{ .max_quads = 16384 });
defer draws.deinit();

// Each frame; output dimensions may change without reallocating the draw list.
try draws.reset(width, height, null);
try draws.rect(.{ .width = 100, .height = 60 }, .{ .r = 0, .g = 0.5, .b = 1 });
try draws.pushClip(.{ .x = 10, .y = 10, .width = 80, .height = 40 });
try draws.quad(.{
    .rect = .{ .width = 32, .height = 32 },
    .transform = .{ .tx = 20, .ty = 15 },
    .texture = .{ .view = sprite_view },
    .uv = .{ .x = 0.25, .width = 0.25, .height = 1 },
});
try draws.popClip();
try renderer.submit(&draws, pass_desc);
device.commit();
// Present through the application's native window/swapchain integration.
```

The build recipe and API sequence are also compiled by the separate
[consumer example](../../tools/render2d/consumer). Run `zig build check` from that
directory to reproduce it.

The complete runnable program is [tools/render2d/main.zig](../../tools/render2d/main.zig).
It includes creation, cleanup, resize, repeated frames, atlas sampling, pixel
comparisons, offscreen composition, native window presentation and benchmarks.

## Ownership and frame rules

- `DrawList.init` allocates fixed geometry/batch/clip storage. `reset` and
  `quad`/`rect` reuse it without allocations. `fillPath` currently uses temporary
  allocator storage for adaptive flattening and analytic coverage. Capacity errors preserve earlier commands.
  Choose capacity at initialization; no implicit flush/reordering occurs.
- `Renderer.init` creates its own shader, pipeline, transient vertex buffer,
  default nearest/clamp sampler and opaque white texture. It borrows the Device;
  destroy the renderer first. Do not copy initialized owning values.
- Texture views and custom samplers are borrowed. Keep their images/resources
  alive through GPU execution. Texture descriptors must be filterable sampled
  2D views, single-sampled, with a noncomparison sampler.
- `submit` checks geometry capacity, clip balance, resource identity and target
  configuration before upload. It starts and ends exactly one pass and never
  commits. Submit once per renderer between Device commits; use separate
  renderers for independent passes in the same frame.
- Device budgets must accommodate all application passes. In particular,
  Vulkan's portable strategy consumes a descriptor set per textured batch;
  configure `BackendOptions.vulkan.descriptor_set_capacity` accordingly. Its
  default is 4096. The 10,000-batch benchmark explicitly provisions 12,000.
  Draw-list quad capacity is not a reservation of backend descriptor storage.
- A pipeline is fixed to one color format, depth format and sample count. Recreate
  the renderer when those change. Resizing alone does not require recreation.
  Offscreen attachment targets currently use full-size base-mip views.
- No automatic device-loss reconstruction occurs. A lost Device causes submit
  to fail. Recreate application GPU resources and renderer on the replacement.

## Drawing conventions

Logical positions start at top left, +X right and +Y down. With a null camera,
logical coordinates equal output pixels. A `Camera` rectangle maps a chosen
world region to the entire output. Each quad's affine transform runs first;
`Transform.mul(parent, child)` applies child, then parent. Use `Transform.translation`, `Transform.rotation` (radians) and
`Transform.scaling`, or set matrix fields directly for skew. Positive rotation
is clockwise in the +Y-down world.

Clips are axis-aligned **output pixels**, independent of camera and quad
transforms. Nested clips intersect. Empty clips suppress geometry. Every
successful push must be matched by a pop before submitting.

Tint is straight linear-light RGBA in [0,1]. Texture input defaults to straight
alpha. The shader premultiplies once and uses premultiplied source-over blending.
For transparent images produced by this renderer, set `.alpha = .premultiplied`.
Set `.flip_y = !device.features().origin_top_left` when sampling an offscreen
rendered image across the GPU API's framebuffer-origin convention. Ordinary
uploaded image UVs address stored rows. For linear filtering of transparent assets, supply premultiplied texels to avoid
color fringes from interpolation of straight-alpha RGB. The shader does not
perform implicit
sRGB conversion; choose formats and supply tint in the intended linear space.

Vector coverage is converted into disjoint constant-coverage spans and submitted
through the same GPU pipeline as quads; it is not a CPU-rendered full-frame blit.
`max_quads` also budgets those coverage spans. The statistics count emitted GPU
quads rather than original high-level path objects.

Draw order is painter order. Only adjacent commands with the same view, sampler
and clip merge. Changing textures or clips can create a batch per quad; zicr
never globally sorts translucent commands to reduce draw counts. `renderer.stats`
reports quads, batches and uploaded bytes after submission.

## Vector paths (implemented foundation)

```zig
var path = r2.Path.init(allocator);
defer path.deinit();
try path.moveTo(.{ .x = 10, .y = 20 });
try path.cubicTo(.{ .x = 30, .y = 0 }, .{ .x = 70, .y = 60 }, .{ .x = 90, .y = 20 });
try path.lineTo(.{ .x = 90, .y = 80 });
try path.close();
try draws.fillPath(&path, .{ .r = 1, .g = 0.2, .b = 0 }, .{
    .rule = .nonzero,
    .transform = r2.Affine.translation(5, 10),
});
```

Paths retain double-precision lines, quadratic/cubic Béziers and bounded rational
conics. Ellipses/circles and rounded rectangles retain conic curves; `svgArcTo`
supports endpoint arcs with radius correction. `append`, `transformed`, `reversed`
and analytic `bounds` operate on retained curves rather than flattening them.

`flattenPath` exposes adaptive device-space flattening with an explicit pixel
error and resource/depth limits. `fillPath` applies the camera and its supplied
transform before flattening, then integrates line-segment winding intervals to
produce antialiased coverage. Both nonzero and even-odd fill rules are available;
open contours close implicitly for filling. This foundation has independent
geometry/coverage tests, but complete reference quality/performance comparisons
and the remaining full-renderer features are still open.

## Reproduction

```sh
zig build test-render2d
zig build test-render2d -Doptimize=safe
zig build test-render2d-scenes -- gl
zig build test-render2d-scenes -- gles
zig build test-render2d-scenes -- gl_legacy
zig build test-render2d-scenes -- vulkan
WGPU_NATIVE_LIB=/path/to/libwebgpu_dawn.so zig build test-render2d-scenes -- wgpu
zig build test-render2d-scenes -- gl --window
zig build test-scenes -- --backend gl --filter render2d
zig build test-web
zig build bench-render2d -- gl
zig build bench-render2d -- vulkan
```

The benchmark is ReleaseFast with library validation compiled out and runtime
statistics and native validation disabled for the GL/Vulkan benchmark contexts. It separates CPU encoding from submit/commit, drains the
GPU and verifies every pixel outside timing, and measures one-batch versus
10,000-batch versions of the same 10,000-quad image. It records nine samples after
three warm-up frames and counts CPU/GPU allocator calls during measured work.
These are CPU timings, not GPU timestamps or comparisons against other libraries.

Current evidence and remaining platform gates are recorded in
[tasks/RENDERER.md](../../tasks/RENDERER.md). Windows/Apple cross-compilation is
separate from native runtime verification.
