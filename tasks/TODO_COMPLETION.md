# TODO completion ledger

Goal: finish the actionable GPU-layer work in TODO.md, preserve the native Zig
implementation, run all available acceptance checks, and leave changes uncommitted.
Implementation and available validation are complete. External hardware/SDK/CI
gates remain explicit below; checkmarks describe that scoped implementation, not
unobserved native-platform passes.

## Work queue

- [x] Independent device state and safe cross-device handles; thread contract.
- [x] Device-loss notification/recovery contract and public API documentation/autodoc.
- [x] Shared COM/DXGI/HLSL extraction, D3D12 WARP/debug/GPU-validation/DRED harness,
      authoritative texture footprints, bounded descriptor-ring tests.
- [x] Vulkan descriptor-set fallback, synchronization validation, upload batching,
      pipeline caches and genuinely asynchronous native readback.
- [x] GL debug output, strict legacy coverage, GLES/WebGL mip-view handling,
      asynchronous readback; D3D11/Metal native readback completion.
- [x] Metal scene harness and cross-build; native WebGPU error/future handling.
- [x] Firefox and hardware browser verification, canvas presentation coverage.
- [x] Shader identifier validation and compiler override for unsupported build hosts.
- [x] Resource churn, exhaustion, compressed formats, sampler/features, real-backend
      robustness streams and swapchain/presentation regressions.
- [x] Measured C/public/raw performance baseline and repeatable benchmark tooling.
- [x] CI for Linux/Windows/macOS and final documentation/evidence reconciliation.

## External verification gates

Native Windows debug/GPU validation, Apple hardware/iOS execution, non-Mesa/Android
hardware coverage and CI execution require those environments. Implement their
harnesses/workflows locally, cross-compile what is possible, and keep runtime gates
explicit until execution evidence exists. Do not count a compile as a runtime pass.
D3D11 removal remains gated on native Windows D3D12 validation as specified in TODO.
Optional future architecture alternatives (Slang/Naga, SM6/bindless/mesh/ray tracing,
enhanced barriers) need a decision/extension boundary, not simultaneous mutually
exclusive implementations or unsupported capability claims.

## Evidence

Baseline: 275 unit/upstream tests; 33 scenes, Chromium WebGPU 33 pass and WebGL2
29 pass/4 capability skips; Linux portable runs 198 pass, Windows APIs under Wine
99 pass; strict GLES 3.0 29 pass/4 skips; five million differential operations clean.
These are prior-turn results and will be rerun after the implementation changes.

## Current implementation progress

Independent devices now own State/pools/backend/diagnostics, with scoped thread-local
dispatch only for the source-shaped internals. Public handles include device
identity; wrong-device and pre-recovery handles cannot alias a pool slot. Raw
singleton compatibility is separate. Unit tests cover interleaved passes, isolated
shutdown, wrong handles and two concurrent device threads. Linux and browser scene
runs passed after this change; Apple completion blocks now capture/retain their
own semaphore rather than using a process-global value (cross-compiled only).

Shared Windows code is in backends/dxgi; D3D12 imports no D3D11 implementation.
WARP discovery, GPU validation, DRED and strict validation gating are implemented
and cross-compiled; native execution remains a gate. D3D12 copy layouts now query
GetCopyableFootprints instead of deriving format/block footprints by hand.
Device-loss status is sticky and isolated, with deferred owner-thread callbacks,
host WebGL/WebGPU event forwarding, native removal polling and recovery tests.

Vulkan now has an opt-in descriptor-buffer strategy and a portable descriptor-set
strategy (default). The harness's portable native device omits the extension.
Both passed all applicable scenes. Pipeline caches are owned per Device, can be
exported/reloaded, and incompatible vendor/device/UUID headers are ignored. A
second-Device rendering round trip verifies cache reuse and independent state.

Synchronization validation exposed a write-after-read hazard in staging readback;
explicit transfer/host dependencies fixed it on both strategies (68 pass, 2
capability skips for those Vulkan runs). The previously used ad-hoc layer JSON
omitted extension metadata. tools/prepare_validation_layer.py queries the actual
library's exports to produce an accurate manifest rather than inventing support.
Current library: API 1.3.285, VK_EXT_validation_features revision 6.

Vulkan tickets submit copies to their own pools/fences and poll without queue-idle
waits. Device-owned retirement keeps cancelled copies alive. Vulkan transfer
failures now propagate instead of asserting; retirement storage grows before
resource creation and idle resource-only commits collect completed objects.
Native WebGPU error scopes reject invalid WGSL and a following valid dispatch
passes. Optional InstanceWaitAny support replaces blind spinning for native hosts
without DevicePoll; positive waits require the native TimedWaitAny instance feature.
Latest native lifetime runs: 108 passed, 3 expected capability skips across Vulkan,
Vulkan descriptor buffers and wgpu-native, including positive tickets and churn.

GL harness now requests debug contexts, registers advertised KHR_debug callbacks,
and counts synchronous error/high/medium diagnostics per scene. The strict
--require-native-validation flag rejects missing callbacks. Debug output exposed
incomplete private framebuffer state inherited by compute dispatches; compute
passes now bind the default framebuffer. GL/GLES async-ticket mode: 70 passed,
4 expected skips, no native errors (2026-10-18). Vulkan retirement cleanup now
enters the owning Device scope when the last client ticket releases native
resources: 72 passed, 2 skips across both descriptor strategies.

ShaderOptions.compiler accepts an explicit host-native sokol-shdc LazyPath and
bypasses the lazy prebuilt dependency. Unsupported host architectures now explain
that override rather than attempting an incompatible x86 executable.

Additional checks: Windows APIs through Wine, all reads through tickets: 106 pass,
5 expected skips across D3D12/D3D11/Vulkan, including odd-byte tail reads. Core and
upstream tests and Windows scene cross-build pass. `zig build docs` generates
index.html, main.js, main.wasm and sources.tar in zig-out/docs. Shader parser
fixtures now exercise nested resources/trailing semicolons and reject malformed
or unconsumed indentation; wired into test/check, browser shader generation passes.

Browser expansion: Firefox 157 WebGL2 30 pass/7 capability skips, repeatable via
`zig build test-firefox-webgl2`. Its WebGPU run explicitly fails with no adapter
in this headless Linux setup; `test-firefox-wgpu` preserves that failure. Chromium
hardware mode removes SwiftShader forcing, enables GPU/ANGLE Vulkan, captures
identity and rejects missing/software identities. Actual ANGLE/RADV AMD WebGL2:
30 pass/7 skips; browser WebGPU AMD: 34 pass/3 skips. Repeatable hardware build
steps are test-web-hardware-webgl2 and test-web-hardware-wgpu. These do not close
mobile, Firefox WebGPU, or canvas presentation gates.

Added pool_exhaustion_recovery (38th scene): fill a four-buffer native device,
require PoolExhausted, free/reuse the slot, reject the stale generation and verify
a new GPU readback. This exposed a real Vulkan bounds error: Track.occupy had N
entries despite live pool slots using indices 1..N. The indexed bitmap now has
N+1 entries; its dense list remains N entries. GL/GLES and both Vulkan strategies
pass this regression with native diagnostics enabled; Windows cross-build passes.

Integrated GL/GLES async suite after pool exhaustion: 72 pass/4 skips. The scene
borrows a shared GL context through a second Device, so it now resets the original
Device state cache after the second wrapper's teardown, as required for native
state changed outside that wrapper. A first integrated run exposed this test
contract error in compute_to_vertex; the corrected full rerun passes.

Shader reflection validates WGSL keywords/reserved identifiers (including target
and double-underscore prefixes) before module generation, with a source-linked
list and a clear rename diagnostic. Other target languages still rely on shdc's
compile-time checks; complete HLSL/MSL reflection checks remain on the queue.

Vulkan optional features are now queried and enabled explicitly by the native
harness (compression families, anisotropy, independent/dual-source blend, cube
arrays and storage-image features used by the API). Strict validation full run:
74 pass/2 skips before compressed fixtures. BC1-BC5 fixed block fixtures are now
five separate scenes (43 total); compare every output pixel against endpoints
derived from Khronos S3TC/RGTC, no GPU-derived expected data. GL/GLES/two Vulkan
strategies: 20 pass; wgpu-native with supported compression features requested:
5 pass; D3D11/D3D12/Windows Vulkan under Wine: 15 pass. No capability skips in
those compressed runs. BC6/BC7, ETC2 and ASTC fixtures still remain.

BC6H (mode 00 zero endpoints) and BC7 (mode 6 zero RGBAP endpoints) added as
separate fixtures, 45 scenes total. Seven BC fixtures across GL/GLES, portable
Vulkan, descriptor-buffer Vulkan and wgpu-native: 35 pass/0 skip/0 fail. Previous
browser run with BC1-BC5: Chromium SwiftShader WebGPU 39 pass/4 skips, WebGL2
35 pass/8 skips, no failures. These counts predate BC6H/BC7 browser verification.

ETC2 individual-mode constant fixture and ASTC LDR void-extent red fixture added
(47 scenes total). Across five native paths, all BC1-BC7 plus ETC2/ASTC: 39 pass,
6 capability skips, no failures. GL and GLES both execute ETC2 and ASTC fixtures;
the two Vulkan devices and wgpu-native do not advertise those families here.
These are baseline fixed-block fixtures, not exhaustive codec pattern coverage.
Remaining immediate queue: strict GL3.3 shader fallback/mip-view contract, native
upload batching, sampler/descriptor exhaustion/real robustness and presentation,
benchmark C/raw/public baseline, platform CI, full exported API docs and final
requirement-by-requirement README/TODO reconciliation. Firefox WebGPU adapter and
native Windows/Apple/mobile runtime gates remain explicit. Goal stays active.

Strict GL 3.3 coverage implemented: render shader namespaces now expose glsl330,
converting shdc's 4.10 interstage location decorations to name linkage while
retaining attribute and fragment-output locations. Shader operations are not
silently translated; unsupported syntax still fails in the native compiler.
Generator tests verify interface conversion and reject unexpected versions.
The gl_legacy scene path selects that descriptor. Exact runtime command:
`MESA_GL_VERSION_OVERRIDE=3.3 MESA_GLSL_VERSION_OVERRIDE=330 zig build test test-scenes -- --backend gl_legacy`
42 passed, 5 skips; context reports actual 3.3 Core Profile. GLSL 3.30 conversion
does not claim general translation of arbitrary GLSL 4.x language features.

CI definitions implemented in .github/workflows/gpu.yml: checksum-pinned official
Zig 0.17.0 installer, Linux core/upstream/safe/cross-target/differential/native
software scenes/strict minimum GL+GLES/browser runs; Windows Graphics Tools and
strict D3D12 WARP validation, plus D3D11; macOS strict Metal native runtime gate.
Workflow YAML parsed locally. These jobs have not executed remotely; no passing
CI/native-Windows/Apple runtime evidence is claimed. Installer metadata dry-run
passes; actual bounded network download verification is in progress.

check-metal now imports generated render/compute shaders and forces ALL shared
scene bodies in an exported compile-only function for macOS ARM64/x86_64 and
iOS ARM64. All three cross-check objects pass (2026-10-18). This extends the
previous backend/readback/host body checks and still does not prove runtime.

CI installer verified end to end locally: official Linux Zig 0.17.0 archive
downloaded to /tmp, SHA-256 matched the pinned official checksum, extracted, and
its executable reports 0.17.0. Network reads have a 30-second inactivity timeout.
macOS/Windows archives are pinned from the same release index but have not been
downloaded/executed on their platforms here.

Every exported type, constant and function declaration in src/gpu/gpu.zig now
has a user-facing doc comment; a declaration scan finds none missing. `zig build
docs` succeeds. CONTRACT.md now documents per-Device selection/ownership/loss and
all native ticket synchronization/retirement, removing the old synchronous-fallback
claim. D3D12 DESIGN.md now records shared dxgi modules, queried texture footprints
and fence-driven readbacks. These documentation requirements are implemented,
with final whole-roadmap reconciliation still pending.

Safe optimized regression run passes all 283 tests: core/public API, generator
fixtures and upstream cases. Later generator hardening handles flat/centroid
interstage qualifiers and rejects extra layout decorations instead of silently
discarding component/index semantics; the latest Debug generator tests pass.

Added descriptor_exhaustion_recovery (48th scene): a real Vulkan Device limited
to one descriptor set renders red, rejects the second green draw with exactly
one pool-exhaustion diagnostic, preserves the red result, then renders green on
a fresh frame. Strict synchronization/native validation passes, no native errors.
Added D3D12 sampler-ring equivalent (49th scene): fill all 1024 per-frame sampler
entries, reject the overflow green draw, validate red remains, then recover green
on the next frame. Windows cross-build/runtime verification is in progress.

D3D12 descriptor-ring recovery passed under Wine: exactly one expected overflow
diagnostic, correct skipped green draw and recovery. Root signature 1.1 feature
negotiation/SDK structs/versioned serializer implemented, retaining 1.0 when the
device/loader does not support 1.1. Static descriptor flags preserve buffer bounds
checks and resource data remains volatile for ordered uploads/UAV writes. Uniform
root CBVs are static while set at execute, matching immutable upload-ring bytes.
Full D3D12 async suite on reported root signature 1.1 path: 44 pass/5 capability
skips, no failures (49 scenes total). Native debug queue is unavailable under
Wine, so native Windows validation and a true 1.0-only device remain external gates.

Automatic upload batching implemented. D3D12 lazily opens its frame for initial
and unsealed uploads; Vulkan uses a mapped UploadArena per frame and records in
its stream command buffer. Chunks grow for large batches, and the next fenced
reuse keeps only one normal-sized cached chunk. Readback flushes pending producers.
copy_staging_buffer_size is the normal Vulkan chunk size; no per-resource queue
idle wait remains. Added submission/one-shot counters and batched_initial_uploads
(50th scene): 32 odd-sized buffers plus a mipmapped image, immediately overwritten
CPU sources, forced 64-byte Vulkan chunks, exactly one submission, correct bytes/
pixels, and a read before explicit commit. Both Vulkan strategies pass. Full
Vulkan compatibility-read run: 91 pass/9 skips; async arena-trim run also 91/9.
D3D12 full async suite under Wine: 45 pass/5 skips, including batch assertions.
Core/upstream tests passed with the batching change before the module addition.

User added standalone gpu module and moved gpu.zig to root.zig while benchmark
work was in progress, and explicitly confirmed to continue. Preserved that layout,
wired options to the actual GPU module, updated tool-module construction and API
test imports. A module-export test proves gpu.Device/Buffer and zicr.gpu aliases
share types and Device identities. Core/API/module tests and Windows cross-build
pass after wiring. The benchmark executable is being compiled; no performance
measurement is claimed yet. A temporary build in /tmp was used while preserving
the user's live build.zig edits; normal build integration is now restored.

Real GL C/raw/public benchmark implemented in tools/bench/ with 1x1 output,
identical generated shaders, alternating bindings/uniforms, 4 KiB resource churn,
transient uploads and checked synchronous readback. All modes disable native
debugging, library validation and statistics. C inner loops are compiled O3 with
NDEBUG/trace hooks; Zig uses fast mode. Runner rotates process order and retains
raw samples, identity and variance. Completed baseline artifacts: bench/results/
gl-2026-10-18-10000.json and gl-2026-10-18-100000.json (27 measured samples per
workload/mode). At 100k draws: C 41.382 ms, raw 71.099 ms, public 72.158 ms median;
churn and transfers are much closer. This is a measured GL checkpoint, not a
claim about other backends or completion of the performance requirement.

Userspace perf capture (cycles:u, 499 Hz, DWARF) found memcpyFast 24.35% and
backend.applyBindings 17.41% self cycles; local-symbol report is retained in
bench/profile-gl-before.txt. Original remote/inline symbol expansion stalled and
was terminated; local-symbol analysis completed from the same captured data.
Profile-led hot-path changes avoid whole-array snapshots in GL binding/barrier
loops, borrow uniform metadata, and construct GL/D3D11 binding adapters directly
in caller scratch storage. Core/upstream/Windows builds and benchmark remeasure
are in progress; no speedup claim is made before those finish.

Measured GL optimization: 100k draw medians after borrowed bindings: C 40.278 ms,
raw 40.699 ms, public 41.608 ms, CV 2.6/7.1/7.8%. Raw/public draw CPU time dropped
42.8/42.3% versus their earlier measurements while C moved -2.7%. Later transfers
have high variance, so no small-transfer speed claim is made. RESULTS.md records
methodology and limits. Binary fingerprints were recovered from retained matching
Zig cache executables; future runner output hashes/rejects changed executables.
Benchmark teardown now runs before results publication and checks diagnostics.

The profile-led native regression run passed 225 scenes/25 skips over five Linux
paths and all Apple scene cross-builds. Browser BC6H fixtures exposed a wrong Web
IDL spelling from native underscore names. Corrected BC6H/ETC2/EAC/ASTC conversion
in formats.mjs, with 23 canonical-name checks and actual browser compressed
fixtures: WebGL2 39 pass/11 skips; WebGPU 43 pass/7 skips (50-scene revision).

CI-style llvmpipe/lavapipe revealed an actual driver bug: GetPipelineCacheData
reports 20 after writing a full 32-byte header. Confirmed native output and Mesa
source. Cache export zeroes its buffer and repairs ONLY the Mesa vendor/device
case with a complete matching header/UUID; malformed/oversized reported data is
rejected. Header parsing is little endian on every host. Guard/UUID/endian unit
tests and full software GL/GLES/Vulkan validation: 136 pass/14 skips. New warning
and counter expose repairs. EGL also falls back from 4.6 to 4.3/4.1 (or ES3.1 to
3.0), preserving debug validation; forced 4.5 run: 45 pass/5 skips.

GL/GLES/WebGL mip ranges now use BASE_LEVEL/MAX_LEVEL when native texture views
are unavailable; incompatible simultaneous ranges for one backing texture reject
bindings, and unsupported layer subsets reject creation. Attach/readback restore
the full backing range. Added alias/layer/same-pass switching regressions, including
two active texture units and later absolute read/attachment use (53 scenes).
Native GL/GLES/Vulkan texture tests and both full browser suites pass. Strict
GL3.3 texture set: 9 pass/0 skip; strict GLES3.0/Vulkan mip-view tests pass.
Windows and three Apple scene cross-builds pass; Windows runtime revalidation is
in progress. Browser harness validates exact expected diagnostics for negative
scenes rather than accepting arbitrary errors.

Windows texture-view regression initially exposed a test assumption: D3D defaults
to BGRA8 attachment storage, while the direct byte expectation was RGBA. The test
now requests RGBA8 explicitly. Full D3D12/D3D11/Windows-Vulkan rerun under Wine:
143 pass/16 skips (53 scenes per API), no failures. This is not native Windows
validation evidence.

Further readback lifetime audit found that Vulkan query errors other than device
removal were treated as completion by generic retirement. Such errors now retain
the task and retry; teardown can use an independent idle wait for proof. A failed
healthy-device idle wait cannot proceed to destroy GPU resources. Added a mock
that cancels a real Task, returns transient host OOM on its fence query, verifies
no destruction/loss, then completes and verifies exactly one retirement. Unit and
native ticket verification are in progress.

Readback lifetime failure mock passes, including a non-blocking poll that does
not wait/release after transient OOM, a teardown idle proof, and confirmed removal.
Native Vulkan tickets plus core/upstream tests pass after the fix.

Shader compiler override hardened end to end: root -Dshader-compiler accepts a
LazyPath and is inherited by addShaderModule; per-call compiler still overrides
it. Dependency is truly lazy. Unsupported hosts no longer panic during library-only
build setup; requesting shader steps without a compiler gives an actionable fail
step. Host-selection tests reject wrong-architecture prebuilts (the Windows binary
is PE32+ x86-64). An actual override wrapper ran render/compute compiler invocations,
and check-scenes-web/unit tests passed. Added ShaderOptions.slangs for native
feature-specific profiles.

Dual-source blend test (54th scene) passes on GL, Vulkan and wgpu-native, and the
full browser suites pass. Native feature shaders compile GLSL/HLSL/MSL/SPIR-V; the
pinned translator omits WGSL support, so that test uses explicit standards-based
WGSL with blend_src and enables the adapter's supported dual-source feature.
Anisotropy/border/comparison sampler tests (57 scenes total) are now being verified.

Storage image formats r32ui/rgba16f/rgba32f now have exact-byte/value compute
regressions. Approved native run: 16 pass/0 skip across GL/GLES/Vulkan/wgpu-native;
both full Chromium suites also pass, including the new 1M-element dispatch.
Native base-instance regression: GL/Vulkan/wgpu-native pass; GLES capability skip
(7 pass/1 skip including the existing instancing scene). New shader identifier
checks cover HLSL object keywords, MSL address spaces and numeric type families;
verification is in progress.

Full 63-scene portable-limit run: 227 pass/25 capability skips across GL, GLES,
Vulkan and wgpu-native, no failures. Both full Chromium suites pass; all-scene
Windows and Apple cross-checks pass. MSAA texture sampling now fetches all four
actual samples (no prior resolve); WGSL uses explicit multisampled texture loads.
Cross-target identifier validation and shader regeneration pass. Evidence:
/tmp/zicr-features-portable-full.log. Requirement-by-requirement audit is in
TODO_REQUIREMENTS.md, including remaining presentation and non-GL benchmark work.

Deterministic real-backend robustness stream passes GL/GLES/Vulkan descriptor sets/
Vulkan descriptor buffers/wgpu-native: 5 pass, no skips or native diagnostics.
Each executes 128 frames and 4096 draws with seeded resource replacement after use.
Browser canvas presentation is now exercised through Swapchain, over 32 browser
animation turns with final-pixel readback; both full Chromium suites pass.
Native Linux GL and GLES now have actual X11/EGL window hosts. On isolated Xvfb,
both passed 32 swaps plus final-pixel verification with strict native debug output
(software llvmpipe, not a claim about the host's display compositor). Linux CI
includes this window test. Vulkan/Windows/Metal presentation hosts remain open.

Latest Windows APIs under Wine with portable limits: D3D12 59 pass/5 skip,
D3D11 57/7, Vulkan 60/4; 176 pass/16 skip overall, no failures. Latest browser
runs include real canvas presentation: Chromium software WebGL2 46/19 and WebGPU
56/9; Chromium hardware WebGL2 44/21 and WebGPU 55/10; Firefox WebGL2 46/19.
No failures. Capability differences are retained, not counted as passes.

Linux Vulkan X11 swapchain host now passes 32 acquired/presented frames and final
image transfer/readback with synchronization validation on lavapipe. Xvfb lacks
DRI3 for RADV presentation; this is software presentation evidence only. The
first failed hardware-host setup exposed an existing cleanup bug (calling
vkDestroyInstance from the unloaded global dispatch); cleanup now uses the loaded
instance dispatch and destroys a created device on subsequent host-setup failure.

Safe full checks after Linux window-host integration: 59 build steps succeeded,
298/298 tests passed, including Windows/Apple cross-checks and docs generation.
Five million differential operations passed after excluding the new D3D12-only
stats block (C sokol has no D3D12 backend). Latest software GL/GLES/Vulkan scene
run: 174 pass/18 capability skips, no scene failures.

Dawn native runtime is now verified, not deferred: official release v20261016.190333,
revision 67d4d6e64b0755d638f76549794692badfdbc8ab, published SHA verified; 92 common
webgpu.h structures / 524 size-offset checks match wgpu-native v29. Linked the
package's static library into a test-only shared provider. Initial full run found
that the host omitted TimedWaitAny, causing synchronous shader error scopes to be
disabled on Dawn. Host now queries and requests that feature, supplies a positive
wait timeout only when enabled, and labels the actual completion path. Full Dawn
portable/async suite: 57 pass/7 skip, including shader_failure_recovery. Source,
commands and ABI audit tool: tools/webgpu/README.md. Library remains native Zig.

Platform presentation hosts now also cover Win32 flip-model D3D11/D3D12, Win32
Vulkan surfaces, and macOS NSWindow/CAMetalLayer. Windows and Apple ABI cross-checks
pass. Native macOS drawable readback uses the public injected-image/readback API;
per-frame autorelease pools prevent retaining the whole drawable pool. Apple
execution remains external. Native Windows workflow now gates D3D12 WARP window
presentation; macOS workflow gates Metal window presentation. Wine DXGI window
execution currently faults with a DLL-address integer division by zero after
invalid monitor EDID metadata is reported. This is failed verification, not a
passing presentation result; isolating the provider failure is in progress.
DXGI adapter preference support (Factory6, high-performance/minimum-power) is
implemented in the shared host helpers and cross-compiled.

Win32 Vulkan presentation passed through Wine/lavapipe: 32 frames and correct
final pixel. The strict validation invocation failed because Wine did not expose
the required layer, so this pass is explicitly without that validation coverage.
After platform window integration, 59/59 Debug build steps and 293/293 uncached
unit/upstream tests passed, with Apple/Windows cross-checks and docs generation.

Vulkan C/raw/public benchmarks now build and pass checked rotating-order runs at
10k and 100k draws, 27 samples/workload/mode. Same RADV driver and descriptor-buffer
strategy in all modes (pinned C requires that extension). 100k medians: C 37.686ms,
raw 38.622ms (2.5% above C), public 40.694ms (8.0% above C, CV12.0%). Transfer/churn
medians are close, with full variance retained. See bench/results/vulkan-2026-10-19-*.json.
Native WebGPU benchmark path is being implemented; C callback signatures are
checked against the supplied provider header rather than assumed.

Native WebGPU C/raw/public benchmark smoke passes. Initial 10k samples exposed a
readback gap (~5.2ms Zig versus ~1.3ms C for 4MiB). The benchmark had given Zig an
arena allocator, retaining temporary read results, while C used reclaiming malloc.
Changed context/Device/raw allocators to Init.gpa (results/input arrays stay in the
process arena). Synchronous WebGPU reads also unnecessarily allocated owned output
and copied it twice. They now borrow caller output; only poll copies, while late
callbacks/retirement never touch or free it. Expanded late-callback ownership test
covers owned and borrowed buffers on success/failure. Native full blocking suite
passes 57/7 plus unit tests. Initial samples remain as
wgpu-native-2026-10-19-10000-arena-double-copy.json, explicitly not the corrected
allocator baseline. Corrected measurements are in progress.

D3D11 C/raw/public benchmark cross-build and output smoke passed through Wine/DXVK
on explicitly selected RADV. Adapter metadata now queries IDXGIDevice/IDXGIAdapter
and records the real UTF-8 adapter name and vendor/device IDs. First 10k draw
medians: C4.301ms, raw7.213ms, public7.234ms (about68% overhead). Retained profile
has5522 samples; Wine maps PE code as JIT addresses, resolved with llvm-addr2line:
memcpy copyBlocks and memset are hot. D3D11 binding loops now borrow descriptor
arrays, as GL already does; remeasurement in progress. Native unit/upstream tests
passed293/293. An accidental foreign-test invocation exposed a Windows-specific
GL loader expectation (built-in opengl32 loader reports MissingOpenGlFunction,
not MissingGlProcAddress); corrected it. Rerunning explicitly in the owned Wine
prefix/display passed277/277 Windows unit/upstream tests. Do not infer native
Windows GPU validation from these unit tests or Wine measurements.

Broad native/browser verification after readback/binding changes:290 pass/30
capability skips across GL/GLES/Vulkan descriptor sets/descriptor buffers/wgpu-native;
both full Chromium suites including canvas pass, Apple cross-checks pass.
D3D11 borrowed-array remeasurement: C4.449ms, raw5.900ms, public6.081ms at10kdraws.
This is16–18% less Zig CPU time in the measured workload, but33–37% above C remains.
A further optional-record tag-initialization probe did not show a reliable win and
was reverted; raw samples are retained as a negative experiment. The simpler
caller-scratch initialization remains. Source/helper/profile identity is retained
with bench results. Native Windows parity or validation is not inferred.

README usage now creates its shader/pipeline with the same Device, casts the
loader pointer explicitly, and has a concrete function-body compilation check in
tools/module_check.zig. Native check/test/upstream/docs passed after that addition.
The host-owned native/browser WebGPU loss forwarding requirement is now explicit.

Dawn final full blocking-read run after borrowed output and adapter-info cleanup:
57 pass/7 capability skips, no failures. Metadata strings now use the provider's
AdapterInfoFreeMembers ownership API after copying their description.

Final Debug build/cross/docs/benchmark-tools graph passed89/89 steps. Final safe
unit/upstream run passed294/294 tests. Current Windows scenes through Wine passed
176/16 with portable limits and async reads. Strict GL3.3 run passed51/13.
Vulkan WSI review corrected semaphore ownership: render-finished semaphores are
per swapchain image; the host enables optional maintenance1 and uses presentation
fences for recycle/shutdown instead of assuming queue-idle covers presentation.
Extension/feature absence fails that host explicitly, without adding requirements
to the headless portable Vulkan backend. Lavapipe WSI passes32 frames/final-pixel
readback with synchronization validation and presentation fences. See the Khronos
swapchain-semaphore-reuse guide linked by tools/ci/README.md.


Final strict GLES 3.0 passed 47/17; Vulkan maintenance1 window host passed lavapipe
with synchronization validation and Win32/Wine without the unavailable layer.
Readback profiling found a shared native Vulkan policy issue: upload-style
host-visible/coherent memory can be uncached for CPU reads. Added a readback-only
cached-coherent preference with coherent fallback, preserving upload policy.
The C native-equivalent benchmark now uses the same preference. Unit coverage
checks permitted memory bits and rejects cached non-coherent types; both Vulkan
strategies pass 119/9 with native async readback. Measurements are being collected.


Matched Vulkan cached-coherent readback run: C 2.048ms/raw 1.825ms/public 2.003ms for
4MiB, versus roughly 19.7–19.9ms in the uncached policy, with 14–26% variation in
new samples. Both C and Zig use the same new policy; no artificial C disadvantage
is introduced. Raw samples retained. Current GL/Vulkan allocator baselines are
separate artifacts from historical arena experiments. All current guide links
and CI YAML parse; tasks/VERIFICATION.md consolidates exact commands/limitations.


## Final acceptance (2026-10-19)

Implementation and available validation are complete; all changes are uncommitted.
Final Debug/cross/docs graph:73/73 steps passed. Final safe unit/upstream graph:
300/300 tests passed. Latest Windows scene runtime through Wine:176 pass/16 skips.
Latest complete five-configuration native/browser run:290/30 native scenes, both
Chromium suites including canvas presentation pass. Strict GL3.3:51/13; GLES3.0:
47/17. Native Dawn blocking suite:57/7. Five million differential operations passed.
Vulkan cached-readback regression run:119/9 across both strategies. Fenced Vulkan
window smoke passes on Linux/lavapipe with synchronization validation and through
Win32/Wine without its unavailable validation layer. Platform compile checks,
README API compilation, links, benchmark JSON metadata, CI YAML and formatting pass.

External gates and optional architecture choices remain in TODO_REQUIREMENTS.md;
reproduction commands are in VERIFICATION.md. Native Windows GPU validation,
Apple/iOS execution, Apple's Objective-C benchmark SDK build and remote CI are not
claimed. Wine DXGI window presentation still faults in the tested environment.
D3D11 Wine draw overhead remains above C after its measured improvement. Those
limitations are recorded rather than reported as passes or hidden by performance
claims. D3D11 remains until the native Windows removal gate is satisfied.
