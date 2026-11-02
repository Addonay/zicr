# Initial 2D checkpoint: design and verification

**Superseded scope:** the full 2D renderer is now required and in progress.
[Full capability and acceptance ledger](FULL_2D.md). The completion audit below
only describes the earlier sprite/rectangle checkpoint; it does not complete
the full renderer.

The agreed direction is **2D first, 3D later**, over the existing public `gpu`
module. GPU implementation checkpoint: `5113540`. The renderer changes are
uncommitted. The goal is a useful ordered sprite/rectangle renderer with a
reviewable API, runnable examples, behavioral/pixel tests and measured CPU costs.

## Scope and public API

Implemented under [`src/render2d`](../src/render2d), re-exported as
`@import("zicr").render2d`:

| Public concept | Contract |
| --- | --- |
| `DrawList` | Allocator-owned fixed-capacity geometry, batch and clip storage; reset/reuse per frame |
| `Renderer` | Borrows Device; owns shader, pipeline, vertex upload buffer, white texture/view and default sampler |
| `Quad` | Rectangle, normalized atlas UVs, affine transform, tint and borrowed texture |
| `Texture` | Borrowed filterable sampled 2D view and optional sampler; explicit alpha mode and vertical flip |
| `Transform` | Column-vector affine composition, translation, rotation and scaling |
| `Camera` | Logical world rectangle mapped to the full output; top-left origin, +Y down |
| `pushClip` / `popClip` | Nested intersecting output-pixel scissors, independent of camera/geometry transforms |
| `submit` | Validates resources/target, uploads once, begins/ends the supplied pass; never commits or presents |
| `Stats` | Submitted quad count, adjacent batch count and uploaded bytes |

Applications own scene state, image decoding, window/device creation, frame
commit and presentation. No scene graph, ECS, window toolkit or mandatory render
graph is introduced. This allows later 3D passes to share the same Device,
textures and frame submission without inheriting a 2D scene model.

The [public guide](../src/render2d/README.md) contains the API example and build
recipe. [`tools/render2d/consumer`](../tools/render2d/consumer) checks that recipe
as a separate dependent Zig package, including `addRender2dShaderModule`.

### Ordering, alpha and resource contracts

- Painter order is preserved. Only adjacent compatible texture/sampler/clip
  commands merge. No global texture sorting occurs.
- Tint is straight linear-light RGBA. Input textures can be straight or
  premultiplied; the shader emits premultiplied color and uses source-over.
- Offscreen images can be sampled with `.alpha = .premultiplied` and
  `.flip_y = !device.features().origin_top_left`. Pixel tests cover this path.
- Storage is allocated at initialization and reused. Capacity errors preserve
  prior CPU commands; no implicit flush changes ordering or clears a target.
- One submit per Renderer between Device commits. Multiple independent passes
  use independent renderer instances. The application chooses pass load/store.
- Pipeline target format/depth/sample count is fixed at initialization; dimensions
  may change. Offscreen targets currently use full-size base-mip views.
- Borrowed GPU resources must outlive GPU use. Foreign/dead views, invalid sampler
  handles, unsupported texture formats and attachment feedback are rejected.
- Device loss returns an error; recovery requires a new Device and recreation.

### Backend resource budgets

The 10,000-batch Vulkan workload exceeded the default 4096 descriptor sets/frame.
The benchmark preserves that workload and provisions **12,000** at Device init.
This is a documented device budget, not a reduced or skipped stress test.
Applications must budget descriptors for renderer batches and their other passes;
CPU quad capacity does not reserve backend descriptors. GPU diagnostics remain
part of correctness checking even when library validation is compiled out.

## Reference decisions

The shallow references are ignored under `.ref/`; they are not runtime
dependencies or wholesale source ports. Source review informed these choices:

- [Blend2D context](https://github.com/blend2d/blend2d/blob/58ca946/blend2d/core/context.h):
  explicit compositing and state contracts, with source-over as the initial
  operation. Arbitrary paths, fill rules and additional operators remain later.
- [Vello render state](https://github.com/linebender/vello/blob/9cbe466/vello_common/src/render_state.rs)
  and [transforms](https://github.com/linebender/vello/blob/9cbe466/vello_common/src/transforms.rs):
  keep geometry transforms, paint/alpha semantics and clipping explicit. We do
  not require compute or adopt Vello's vector rasterizer for the sprite layer.
- [PixiJS batching](https://github.com/pixijs/pixijs/blob/6555201/src/rendering/batcher/shared/Batcher.ts)
  and [quad packing](https://github.com/pixijs/pixijs/blob/6555201/src/rendering/batcher/shared/DefaultBatcher.ts):
  adjacent state-aware batching and packed frame geometry. Start with a portable
  single-texture batch; measure fragmentation before introducing texture tables.

## Acceptance evidence

This table records the completed initial 2D scope and distinguishes implementation
from external platform validation.

| Requirement | Evidence / current state |
| --- | --- |
| Public API/build integration | Separate consumer package builds the documented API and shader helper |
| Geometry and order | CPU tests cover affine/camera coordinates, UVs, premultiplied tint and painter-order batch ranges |
| Capacity/clips/cleanup | Transactional capacity/clip errors, allocation failure injection and partial GPU-init cleanup tests |
| Ownership/frame/loss | Foreign-resource, target mismatch, duplicate submit, commit-boundary and device-loss tests |
| Full native pixel example | GL, GLES, Vulkan and native Dawn WebGPU; every pixel checked, three output sizes/frames, atlas alpha and offscreen composition |
| Shared renderer scene | `render2d_order_clip` passed GL/GLES/Vulkan; Chromium WebGL2/WebGPU suites include it |
| Window example | Xvfb GL and lavapipe Vulkan WSI: 32 submitted frames each, final blue pixel verified |
| Browser | Chromium WebGL2 47 pass/19 skip; WebGPU 57 pass/9 skip; ordered renderer scene and 32-frame renderer canvas presentation passed on both |
| Windows/Apple | Full example compiled for Windows x86-64; renderer scene included in macOS arm64/x86-64/iOS arm64 compile checks; Wine D3D11/D3D12/Vulkan renderer scene 3/3 pass |
| Full existing checks | Unit/upstream/browser/cross-target/docs graph: 88/88 steps successful (cached test counts reported separately by Zig) |
| ReleaseSafe and strict legacy contexts | 9/9 Debug and ReleaseSafe tests; full pixel example passed actual GL3.3 and GLES3.0 |
| Benchmark | GL and Vulkan: both 10,000-quad batched/fragmented workloads passed full pixel verification; zero measured CPU/Device allocator calls |

Reproduction commands live in the [public guide](../src/render2d/README.md).
The existing GPU reproduction ledger remains [VERIFICATION.md](VERIFICATION.md).

## Platform boundaries and later work

Native Windows D3D validation and Apple runtime execution still require those
systems. Wine is additional evidence, not native Windows proof. The browser
renderer scene covers ordered alpha/clipping and the canvas demonstration uses
the public renderer for 32 presentation frames; the richer native pixel example
covers atlas, resize and offscreen composition. Browser coverage must not be
presented as coverage of every native example path.

This milestone does not implement text shaping/glyph rasterization, arbitrary
vector paths, gradients, advanced blend modes, 2D lighting, asset loading, an ECS
or 3D. Those are subsequent features. Multi-texture batching, indexed/instanced
quad packing and retained/static geometry should be evaluated with measured
workloads rather than assumed faster. Supporting 3D later is an architectural
constraint, not a claim that a 3D renderer exists now.

## Measured CPU baseline (2026-10-19)

ReleaseFast, Zig 0.17.0, Mesa 26.2.4 on AMD Renoir. Library validation compiled
out, native GL/Vulkan validation disabled through benchmark contexts, runtime
statistics off. Three warm-up frames, nine measured samples per workload.
Readback drains the GPU and checks all 16,384 pixels after every frame outside
both timed regions. Values measure CPU encoding and CPU submit/commit, not GPU
execution time or end-to-end frame latency.

| Backend / workload | Quads / batches | Encoding mean (CV) | Submit + commit mean (CV) |
| --- | --- | --- | --- |
| GL batched | 10,000 / 1 | 0.121 ms (18.0%) | 0.096 ms (12.7%) |
| GL fragmented | 10,000 / 10,000 | 0.130 ms (2.3%) | 4.312 ms (1.7%) |
| Vulkan batched | 10,000 / 1 | 0.112 ms (3.3%) | 0.194 ms (10.2%) |
| Vulkan fragmented | 10,000 / 10,000 | 0.155 ms (5.9%) | 6.790 ms (4.6%) |

Each frame uploads 2,160,000 vertex bytes. No measured DrawList allocations or
Device allocator calls occurred; this does not count driver-internal memory
allocations. The one-batch GL measurements have noticeable variance and should
not be used for small percentage comparisons. These results do not establish
performance parity with Blend2D, Vello or PixiJS, whose workloads differ.

Raw samples, exact adapter strings, source hashes at measurement time and
commands: [bench/results/render2d-2026-10-19.json](../bench/results/render2d-2026-10-19.json).
A later assertion added to the existing affine-composition unit test changes the
source-file hash but not the measured runtime implementation.

## Completion audit

- Intended workload and API: sprite/rectangle draw list, atlas UVs, affine
  transforms/camera, tint, ordered alpha, clips and offscreen composition are
  implemented and described in the public guide.
- Runnable examples: native pixel/window runner and browser canvas renderer;
  a separate dependent-package compile check verifies public build/API usage.
- Correctness: 9/9 tests pass in Debug and ReleaseSafe; native pixel checks pass
  GL/GLES/GL3.3/GLES3.0/Vulkan/Dawn; browser renderer scene and canvas pass both
  APIs; the renderer scene passes D3D11/D3D12/Vulkan under Wine.
- Performance: verified 10,000-quad cases on GL/Vulkan, raw nine-sample records,
  variance, warmed allocation counts and device-budget requirements recorded.
- Platform boundaries: Windows/Apple compilation and Wine evidence are labeled;
  native Windows/Apple execution and future text/vector/3D remain explicitly
  outside this initial renderer milestone.
- Existing integration: full unit/upstream/browser/Windows+Apple/docs graph
  passes 88/88 steps. Formatting, whitespace and local documentation links pass.

No source changes beyond this renderer scope are committed. GPU checkpoint
`5113540` remains the last commit; the user can review and commit the renderer.
