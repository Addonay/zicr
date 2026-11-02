# Full renderer implementation phase

User instruction: **write the full design before running builds/tests/benchmarks**.
Reading and writing files is allowed. Do not run formatting/syntax checks, shader
compilers, reference generators, native/browser apps or `zig build` yet. This
persists across continuations. All new code below is unverified. The full goal
remains open until final integration and matched-reference validation succeeds.

## Source added in the current writing batch

- `color.zig`: explicit linear/sRGB/P3 conversion, straight/premultiplied colors,
  extended gamut/HDR values, packing and OKLab interpolation primitives.
- `composite.zig`: CPU semantic equations for all 29 Blend2D operators plus four
  nonseparable HSL modes. Geometric coverage interpolates the completed operator;
  merely multiplying source alpha is incorrect for copy/clear/in/out.
- `image.zig`: owned linear-premultiplied pixels, transactional ingestion/update,
  subimages, odd-dimension area mipmaps, extend modes, nearest/linear/Mitchell/
  Lanczos sampling and output packing. GPU image ownership and codecs still need
  implementation/integration; this is not a whole-frame software renderer.
- `paint.zig`: arbitrary sorted/duplicate gradient stops, pad/repeat/reflect/
  transparent extension, premultiplied interpolation in linear/sRGB/OKLab,
  linear/two-circle radial/conic parameterization, isolated atlas-pattern regions.
- `scene.zig`, `canvas.zig`: retained owned recordings and stateful frontend;
  copied paths/stops/dashes/mesh data/uniforms, borrowed image/font/shader resources,
  immutable clip chains, save/restore, alpha/transforms/compositing and layers.
  Scene handles carry owner identity, invalidated on reset.
- `filter.zig`: owned effect DAG plus CPU reference execution: Gaussian blur,
  shadows, offset, flood, color matrix, component transfer, compositing/arithmetic,
  morphology, convolution, displacement and tiling. GPU passes remain to write.
- `coverage_region.zig`: analytic boolean combinations of winding groups, sharing
  edge partitions for geometry and path clips/aligned strokes. This avoids dark
  seams from multiplying separately antialiased copies of the same boundary.
- `paint_tests.zig`, `scene_tests.zig`: tests written, intentionally not run.

Root exports and legacy DrawList color types are being connected to the shared
color model. Existing direct-quad APIs remain available during full integration.

## GPU execution design to implement

The public renderer must execute through `gpu.Device`; CPU functions above are
preprocessing or semantic references, never an excuse to software-render the
whole frame then upload/blit it.

1. Compile a retained Scene into prepared draws before issuing GPU passes.
   Flatten geometry/clip paths in output coordinates, evaluate analytic boolean
   regions and pack coverage into reusable mask atlas pages. Cache prepared data
   by scene identity/revision, view transform, tolerance and color policy.
2. Keep geometric coverage separate from unmasked brush RGBA. A generic paint
   pass writes source RGBA and coverage (MRT), then a composite pass combines
   source, destination and coverage. This is needed for every Porter-Duff mode,
   especially clear/copy at fractional edges. Native framebuffer blending alone
   cannot implement every artistic mode.
3. Optimize normal source-over runs with a one-target paint-over shader and
   fixed premultiplied source-over blending. Masks, images, gradient stop data
   and geometry are uploaded once before the frame's passes. Preserve painter
   order; never repeatedly overwrite a transient resource within one commit.
4. GPU gradients use texel-addressed stop tables and binary search, not a fixed
   small stop count or lossy ramp that destroys hard stops. Normalize/rebase
   paint coordinates in f64 on CPU before float shader parameters. RGBA32F or
   integer bit-packed tables must use valid nonfiltering binding metadata.
5. Path clips use the shared analytic-region rasterizer. Image masks remain
   sampled alpha masks. Clip chains are immutable Scene resources; save/restore
   restores IDs. Layer parent clipping applies once at group composition rather
   than once to each child and again at the end (which darkens AA boundaries).
6. Intermediate targets and destination ping-pong make destination-dependent
   compositing, effects and isolated layers portable through WebGL2. Filters
   compile into explicit render passes with input/output lifetime tracking and
   reusable targets. Custom paints/filters have a documented shader binding and
   bounds contract, copied uniforms and borrowed GPU handles.
7. Nonisolated normal layers start from the backdrop and interpolate the finished
   result at return; do not source-over a copied backdrop onto itself. Artistic
   group modes can imply isolation. Preserve group alpha, opacity and clipping.
8. Text outlines use the same path/paint/clip machinery. Glyph atlas/cache keys
   include face/variation/glyph/size/transform and rendering mode. No ASCII-only
   bitmap text substitute: full font parsing, shaping and Unicode/fallback remain
   required implementation work before validation starts.
9. Textured meshes need shared-edge AA without independently compositing two
   half-covered triangles. Use a union coverage mask and per-pixel triangle/UV
   selection (e.g. tile-indexed triangle data), or an equally correct technique.
   Nine-slice/tiling/particles and custom materials build on image/mesh recording.

## Stroke integration still required

Current `stroke.zig` implements centered outline unions, six caps, five join
modes, odd/zero dash patterns, seam merging and transform order; direct GPU scene
and initial mathematical tests existed before the user changed the workflow.
The pre-pause Blend2D corpus comparison is failing and must remain a final-phase
regression. Explicit high-quality Blend2D stroke-to-path options improved most
curve differences; clipped miters and a few tight wide-curve pixels remain.

Add inner/outer/fractional alignment as region combinations: intersect an inside
stroke of width `2*width*alignment` with the original closed fill, union an outside
stroke of width `2*width*(1-alignment)` minus that fill. Open contours stay centered.
Do not silently ignore alignment on the low-level centered outline API. Distinguish
true source-command junctions from curve subdivision samples so bevel/miter styles
cannot introduce artificial corners into a smooth curve. Reference checks and
performance tuning happen only after all required implementations are written.

## Remaining writing work (not a narrower goal)

- GPU shader set, mask/stop/image atlases, prepared-scene compiler, pass/layer/
  effect executor and resource caches; integrate with the public renderer.
- Font/container parsing (TrueType/CFF/composites/variations/color/bitmap), Unicode
  bidi/script handling, GSUB/GPOS/fallback, glyph runs/layout/metrics and rendering.
- Image codecs/ingestion/encoding, richer meshes, nine-slice/tiling/particles,
  custom material/filter execution and path metrics/hit testing.
- Full gallery/examples, every capability's tests, matched reference drivers and
  benchmark workloads, final public API/build documentation.
- Then, and only then, switch to validation/repair. No completion or parity claim
  until the full acceptance ledger is satisfied with current evidence.
