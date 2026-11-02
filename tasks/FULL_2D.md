# Full 2D renderer acceptance contract

Status: **in progress, not complete**. This supersedes the limited scope of the
sprite/rectangle checkpoint in RENDERER.md. The user requests complete 2D
rendering capabilities integrated with the public GPU module. Text, paths,
paints, compositing and effects are required work, not deferred milestones.
3D remains a separate later renderer.

## Working phase: implementation first

The user explicitly resumed work with a two-phase requirement: read sources and
write the complete design first; do not run `zig build`, tests, benchmarks,
format/syntax checks, reference generators or application execution until the
design's required subsystems have implementations. File reads/writes and source
inspection are allowed. Only then enter validation/repair. This instruction
persists across continuation turns and context compaction. Do not fall back to
per-feature build/test cycles. New source and test files in this phase are
**unverified**. Earlier test evidence is historical and cannot verify new code.

The pre-pause stroke reference comparison is still failing: ordinary curves
became closer after passing high-quality approximation options directly to
Blend2D's public stroke-to-path API; clipped miters and a handful of tight wide
curve pixels remain unresolved. Keep those regressions for final validation;
do not report reference parity or delete them to get a green check.

The references are pinned local shallow checkouts: Blend2D `58ca946`, Vello
`9cbe466`, PixiJS `6555201`. Implementation and comparisons must use their actual
source and behavior. No claim of matching or exceeding them is valid without
matched workloads and quality measurements.

## Required capability ledger

A row is complete only when public API, implementation, error/ownership behavior,
reference/pixel tests and GPU/browser integration are verified. A CPU helper or
an enum alone does not complete a rendering capability.

| ID | Capability | Reference source | Current state / missing acceptance |
| --- | --- | --- | --- |
| G1 | Editable multi-contour paths, moves/lines/quadratics/rational conics/cubics/close; append, reverse, transform, bounds | Blend2D core/path.h | Retained commands, append/transform/reverse and analytic extrema bounds implemented; broader reference and public API acceptance still open |
| G2 | Rectangles, rounded rectangles, ellipses, circles, polygons, polylines, circular/elliptical arcs and SVG endpoint arcs | Blend2D core/geometry.h and path.h; Pixi graphics | Circle/ellipse/rounded-rectangle/polygon/arc construction implemented; broader primitive/reference tests remain |
| G3 | Nonzero/even-odd fills, holes, open-contour fill closure, self intersections, degenerate and extreme coordinates | Blend2D raster; Vello strip_generator | Analytic winding coverage implemented and GPU-tested for holes/self-intersection; broader stress/reference acceptance remains |
| G4 | Adaptive device-space curve flattening, bounded numerical error, shape hit testing, path metrics and winding | Blend2D path geometry; Vello flatten | Adaptive device-space flattening and error tests implemented; path metrics/hit testing still missing |
| G5 | Strokes with width, joins (miter/clip/bevel/round variants), miter limit, independent caps (including reverse/triangle variants), dashes/offsets, closed paths, stroke alignment and transform order | Blend2D core/path.h; Pixi FillStyle/StrokeStyle | Missing |
| A1 | Subpixel antialiasing of vector geometry and clips; thin edges, shared edges, large zoom, scale/shear and fractional translation | Blend2D raster; Vello coverage | Analytic line coverage + adaptive curve approximation implemented; independent ellipse pixel oracle passes; Blend2D/Vello comparisons still missing |
| P1 | Solid color, linear/radial/focal/conic gradients, arbitrary ordered stops, hard stops, extend modes, paint transforms and opacity | Blend2D core/gradient.h; Vello paint | Solid quad tint only |
| P2 | Image/pattern paints, atlas regions, tiling, nearest/linear/high-quality filtering, mipmaps, alpha representation and color conversion | Blend2D pattern/image; Pixi textures | Basic borrowed sampled quads exist; richer sampling/paint contract missing |
| P3 | Linear/sRGB handling, premultiplication, transparent-edge correctness, float/HDR targets and precision policy | Blend2D pixelops; Vello paint | Basic explicit alpha modes exist; full color pipeline missing |
| C1 | Every Blend2D composition operator (29), plus hue/saturation/color/luminosity blend modes used by Pixi/Vello | Blend2D core/context.h:244-303; Pixi filters/blend-modes; Vello blend | Source-over only |
| C2 | Nested save/restore, global alpha, paint/geometry transforms, opacity groups, isolated layers and correct group compositing | Blend2D context; Vello scene/layers; Pixi filters | Only explicit quad transform/pixel clip stack exists |
| C3 | Arbitrary path and image/alpha masks, nested transformed clips, clip intersection, inverse clips, antialiased clip edges | Vello clip/layers; Pixi masks; Blend2D clip | Pixel rectangles only |
| I1 | Owned and borrowed images, subimages, sprites/atlases, tiled sprites, nine-slice, indexed/textured meshes and efficient particle/batch submission | Pixi scene renderables; Blend2D image | Quads/atlas subset exists |
| I2 | Image ingestion/encoding and upload/readback with explicit formats, row pitch, lifetime and asynchronous transfers | Blend2D codecs/image; gpu readback | GPU primitives exist; renderer image/resource integration missing |
| T1 | Font data/faces/collections, metrics, character maps, TrueType/CFF outlines, composites, kerning and variable-font coordinates | Blend2D opentype/font; Vello glifo | Missing |
| T2 | Unicode text decoding, script/bidi-aware shaping, GSUB/GPOS, ligatures, marks, fallback, positioning, glyph runs, hit testing and layout metrics | Blend2D font shaping; Pixi text; Vello glyph runs | Missing; ASCII bitmap text is not acceptance |
| T3 | Glyph antialiasing/caching, transformed text, bitmap/color glyphs and text paint/compositing parity with paths | Vello glifo; Pixi bitmap/text; Blend2D glyph buffers | Missing |
| F1 | Gaussian blur, drop shadow, offset/flood, color matrix, blend/filter composition, masks, effect bounds and isolated intermediate targets | Vello filter_effects/filter; Pixi filters | Missing |
| F2 | Custom shader/filter and textured mesh extension points with correct bounds, uniforms/resources, clipping and compositing | Pixi Filter/mesh | Missing |
| R1 | Retained/reusable scene recordings, dynamic draw lists, resource caches, render-to-texture, resize/loss recovery and explicit resource ownership | All three references | Fixed transient quad list and basic offscreen pass only |
| R2 | Public-gpu-only execution, portable raster path including WebGL2, optional compute acceleration, bounded frame resources and predictable errors | gpu API; Vello CPU/GPU families | Quad path integrated; complete vector/text/effects execution missing |
| V1 | Runnable native and browser feature gallery with every required feature, resize and resource recycling | Existing harness plus reference scenes | Quad example exists; complete gallery missing |
| V2 | CPU/reference and real-GPU pixel tests, randomized geometry/clip/lifetime tests, malformed fonts/images, allocation failure, Debug/ReleaseSafe | Blend2D tests; Vello snapshots; existing gpu harness | Quad tests exist; complete corpus missing |
| V3 | Matched Blend2D/Vello/Pixi workloads; quality diffs, CPU/GPU timing, allocations, variance and hardware metadata | Reference benchmark harnesses | Only internal quad baseline exists; comparisons missing |
| V4 | Native/browser/backend coverage matrix with capability and external-platform limits; public API/build examples | Existing verification ledgers | Complete-renderer matrix missing |

## Architecture and implementation order

Keep resource identity, ownership and submission with the existing `gpu.Device`.
The renderer must not use `gpu.raw`, native backend escape hatches or C wrappers
as a substitute for native Zig implementation. Keep the existing sprite path
working while extending the renderer.

1. Geometry/path model and robust device-space flattening. Build behavior tests
   that check geometric error, contour boundaries, invalid inputs and failure
   cleanup rather than merely inspecting command tags.
2. Vector coverage and fill rules. Use a portable CPU preprocessing plus GPU
   raster/compositing path so WebGL2 is first-class. A slow CPU reference is a
   test oracle, not a substitute for the renderer's GPU execution. Evaluate
   tiled/strip coverage (Vello) against analytic scan conversion (Blend2D).
3. Paint evaluation and GPU shaders, including gradients/patterns and complete
   premultiplied compositing. Establish color/coverage semantics before layering
   masks and filters, to avoid baking inconsistent alpha into later features.
4. Stroke-to-outline geometry, arbitrary clips and isolated layers. Preserve
   painter order across passes and avoid repeated overwrite of transient GPU
   uploads within one Device frame.
5. Fonts/shaping and glyph rendering through the same paths/paints/clips; richer
   image/mesh/sprite paths, filters and custom extension points.
6. Complete gallery, reference corpus, matched benchmarks and platform matrix.
   Optimize from measurements; correctness and comparable output are required
   before a speed comparison is counted.

## Public API direction

`Path` owns reusable geometry. `Paint` describes solid/gradient/image paints.
`Scene` records ordered `fill`, `stroke`, `drawImage`, `drawGlyphRun`, clip and
layer commands, copying or retaining their inputs according to explicit ownership
rules. A stateful `Canvas` facade supplies save/restore and convenient shapes/text
without making the consumer use a scene graph. `Renderer` compiles a recording
into GPU work for a caller-supplied target; the caller still commits/presents.

Path commands retain curves in local coordinates. Flattening uses a supplied
transform and tolerance in **output pixels**; cached geometry must therefore be
keyed by transform/tolerance, not solely by Path identity. A failed flatten or
recording operation must not corrupt an earlier valid scene. Limit exhaustion
must be reported, never silently flatten a curve to an inaccurate straight line.

No row above is considered finished until the actual draw path and its evidence
exist. The full goal remains active across intermediate implementation slices.

## Implementation evidence: geometry and solid fill (2026-10-19)

- New `geometry.zig`, `path.zig`, `coverage.zig` implement reusable f64 geometry,
  retained Bézier/conic curves, exact conic shape construction, SVG endpoint arcs,
  analytic extrema bounds, curve-preserving reversal and device-space adaptive
  flattening. Bounded negative conics are supported; singular weights fail.
- `DrawList.fillPath` performs analytic scan conversion into non-overlapping
  coverage spans, merges identical rows/runs, and submits those spans through
  the existing public-GPU painter. This is actual GPU rendering/compositing,
  with CPU geometric preprocessing, not a whole-frame software fallback.
- Geometry/coverage tests use independent Bernstein/rational evaluation,
  analytical fractional areas, fill-rule overlaps/holes, a subpixel self
  intersection, large finite slopes, SVG radius correction, retained-curve
  bounds and reversal coverage. Allocation-failure tests verify cleanup and
  command-prefix preservation; deterministic backing forbids in-place remap
  so allocator page layout cannot change failure-injection allocation counts.
- `render2d_vector_fill`: every pixel checked for a half-covered diagonal and
  reversed-winding hole. `render2d_vector_curves`: every pixel compared against
  independent numerical integration of an exact, rotated, fractionally placed
  ellipse. Both passed GL, GLES and Vulkan (6/6 scene runs).
- Browser/platform graph passed 61/61 steps: Chromium WebGL2 49 pass/19 skip,
  WebGPU 59 pass/9 skip, including both vector scenes; Windows x86-64 and all
  existing Apple ABI scene compilation checks passed. These counts include
  the GPU suite and canvas test, not just renderer features.
- Final retained-curve/coverage suite: **32/32 tests pass in Debug and
  ReleaseSafe**, including reversal failure cleanup and bounded negative conics. No full-renderer benchmark
  comparison or claim of Blend2D/Vello/PixiJS parity has been made.

Reproduction:

```sh
zig build test-render2d --summary all
zig build test-render2d -Doptimize=safe --summary all
zig build test-scenes -- --backend gl --backend gles --backend vulkan --filter render2d_vector
zig build test-web check-metal check-scenes-windows --summary all
```

Next required implementation is strokes and paint evaluation, followed by the
remaining state/layers/clips, compositing, image/mesh, text/font, effects and
reference-comparison rows. The full goal remains active; this evidence does not
close those requirements. Compositing conformance will also use the
[W3C compositing specification](https://www.w3.org/TR/compositing-1/) alongside
Blend2D's additional operators and PixiJS/Vello behavior.
