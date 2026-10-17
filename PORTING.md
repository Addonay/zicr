# Native sokol_gfx port — incomplete

This is an altered native Zig translation of the bundled `sokol_gfx.h`, originally
by Andre Weissflog. The original source remains the implementation reference.
There are no extern Sokol functions, C imports, or C compilation steps. Native
driver layouts and function-pointer signatures are confined to backend SDK
modules; the public Sokol types and implementation are native Zig.

Reference header SHA-256: `6af70de1a768ac3ff85f4c0a145c2e8e702abd5f101c2ad005b69ef69d5094f0`.

The full-header port requested by the user remains the objective. API name
coverage, compiling code, and dummy rendering are not completion criteria for it.

## Current implementation

| Source section | Native code | Status |
| --- | --- | --- |
| Public types and constants, lines 2364–5934 | `types.zig`, `enums.zig`, `constants.zig` | Converted; native layouts, not ABI bindings |
| Resource pool/slot lifecycle, lines 8383–8560 | `pool.zig`, `api.zig` | Implemented and lifecycle-tested |
| Format/layout calculations, lines 9269–9693 | `formats.zig` | Implemented; switch tables derived from source |
| Pass action defaults, lines 9772–9807 | `defaults.zig` | Implemented |
| Dummy backend, lines 9813–10029 | `api.zig` | Integrated; commands intentionally issue no GPU work |
| Descriptor default resolution, lines 26699–26936 and 27274–27353 | `defaults.zig` | Implemented |
| Descriptor/command validation, lines 24749–26691 | `validation.zig`, `api.zig` | Partial; remaining source checks and diagnostics need porting |
| Public API, lines 27418–29545 | `api.zig` | All 154 entry points present; shared behavior still requires parity audit |
| OpenGL/GLES, lines 10037–13486 | `backends/gl/` | Native resources, commands, barriers and public integration implemented; live GL/GLES rendering tested; platform loaders/error-path parity still require audit |
| D3D11, lines 13487–16009 | `backends/d3d11/` | Native COM calls, resource ownership, command submission and public integration implemented; Wine/DXVK runtime checks passed; final parity/platform audit pending |
| Metal, lines 16010–18427 | — | Not ported |
| WebGPU, lines 18428–20693 | — | Not ported |
| Vulkan, lines 20694–24132 | — | Not ported |

`glcore`, `gles3`, `d3d11`, and `dummy` are selectable. Other GPU selections return
`error.BackendNotPorted`; they never select the dummy backend implicitly.
GL and D3D11 native-object queries return actual driver handles. Queries for inactive
backends retain their null/empty behavior.

## Native API choices

The build exposes the importable module `sokol_gfx`. Descriptors are passed by
value. Function names are camelCase and type names are PascalCase. Setup takes
an explicit Zig allocator and backend:

```zig
const gfx = @import("sokol_gfx");
try gfx.setup(allocator, .dummy, .{});
defer gfx.shutdown();
```

`Desc.allocator` is retained in the translated descriptor vocabulary, but callers
must supply `std.mem.Allocator` to setup instead. Supplying legacy allocation
callbacks returns `error.UseZigAllocator`.

The global API has the same single-context ownership model as the original.
Borrowed data and callback user data must remain alive for the calls using them.

## Verification

`zig build test` runs native behavior tests. `zig build check` compiles them.
`python3 tools/port_coverage.py` checks public entry-point exports against the
bundled header; it deliberately does not claim semantic parity.

Tests cover pool exhaustion, generation reuse, uninitialization counters,
stale handles, default vertex packing, compressed-image pitches, uniform layout,
allocation failure cleanup, resource validation, transient slot rotation,
sealing, commit listeners, tracing, and frame statistics. No C ABI tests exist.

Still required before declaring the full port complete: every GPU backend and
its source-specific validation and synchronization paths, feature/capability
queries, backend injection and native-object queries, plus runtime rendering
and resource tests on each supported backend/platform.

## GL integration and verified rendering

The native GL/GLES backend accepts a context-owner symbol resolver:

```zig
try gfx.setup(allocator, .glcore, .{
    .environment = .{ .gl = .{
        .get_proc_address = resolveGlFunction,
        .user_data = context,
    } },
});
```

The caller must make its context current before setup and keep it current during
GPU calls and shutdown. No GL/EGL/Sokol C headers or C source are compiled.
`zig build test-gl` uses a separate native EGL test utility with runtime-loaded
system driver functions; that utility links libc for the OS dynamic loader.

Verified on Mesa 26.2.4 through surfaceless EGL 1.5:

- Desktop GL 4.6 and GLES 3.2, in Debug and Safe configurations.
- GL 3.3 and GLES 3.0 compatibility paths using Mesa version overrides and
  `zig build test-gl -- --legacy`.
- Uniform-driven triangles with exact RGBA readback, indexed/instanced vertex
  buffers, base-vertex offsets, transient staging uploads, buffer-to-image
  copies, texture/sampler bindings, multisample rendering and framebuffer resolve.
- Compute storage-buffer writes and GPU copy/readback, plus actual rendering
  from compute-written vertex buffers and storage images with memory barriers.
- Native frame statistics and an absence of GL errors in these paths.

Cross-target semantic compilation (`zig test -fno-emit-bin`) passes for
32-bit Windows and ARM64 macOS; those checks are not platform runtime tests.
The ARM64 check caught and corrected erased function-pointer alignment in the
context-loader dispatch table. The mutable texture-storage path also restores
Sokol's mip-range setting and skips that parameter on multisample targets,
which do not accept it.

Remaining GL-specific audit items include the automatic Windows loader from the
original header, debug driver-error assertion coverage, broader state/format
paths, and runtime verification outside this Linux/Mesa environment. The native
resolver currently supplies the same role as an external GL loader.
Shared diagnostics still need the original debug message strings and remaining
command/pass validation checks. None of these are waived by the passing smoke
checks.

## D3D11 integration and verified rendering

The backend uses the caller's D3D11 device and immediate context. Driver data
layouts and typed COM virtual-table calls are isolated in `backends/d3d11/sdk.zig`;
they define the Windows driver interface, not Sokol C bindings. Format/state
conversion follows the bundled header and installed SDK definitions. Device and
context ownership remains with the caller. Injected resources are AddRef'd and
released according to the source; image texture/resource aliases have balanced
references, and views retain their parent through the driver.

`zig build check-d3d11` builds `zig-out/bin/sokol-gfx-d3d11-smoke.exe`. It performs
all rendering through the public Zig module, loads D3D11 and the HLSL compiler
through Zig's native Windows library loader, and verifies actual GPU readback.
Observed in this environment: Wine, DXVK 2.7.1, D3D feature level 11.1, RADV
26.2.4 on AMD Radeon Graphics. This is Windows API execution through Wine/DXVK,
not a claim of native Windows hardware validation.

Passed runtime paths:

- Uniform-driven triangle with exact `{64, 128, 191, 255}` readback and native
  frame-statistics checks.
- Indexed/instanced vertex-buffer rendering and base-vertex offsets.
- Transient staging uploads, buffer-to-image copies, SRV/sampler texture rendering.
- Multisample render targets and resolve texture readback.
- Compute raw storage-buffer writes followed by GPU copy and mapped readback
  `{100, 103, 106, 109}`.

Wine uses an owned prefix under `/tmp` and a private Xvfb display. The sandbox
blocks Wine's Unix socket; execution therefore needs process permissions outside
that sandbox. These test processes do not target the host desktop.

Native tests additionally exercise failure cleanup after partially created
pipelines, dynamic buffer discard/no-overwrite selection, constant-buffer padding,
register collisions across stages, owned HLSL semantic-name lifetime, staging
versus GPU storage, injected-resource references, and clearing compute SRVs before
assigning UAVs. Unaligned uniform ranges use a preallocated padded upload buffer
so a full D3D constant-buffer update does not overread caller data.

Remaining D3D11 audit includes broader image/view formats, fragment UAV paths,
shader compiler diagnostics/failure coverage, and actual native Windows testing
where available. Shared pass/command validation and debug diagnostic strings
still require source-wide completion audit.

## Active goal checkpoint

The full-header port remains active. GL/GLES and D3D11 are integrated and have
passed live rendering checks. Metal, WebGPU, and Vulkan still require native
implementation and verification. The final audit must also cover all remaining
shared behavior, platform loading, diagnostics, resource tracking, and backend
edge paths. Passing current tests does not waive any of that scope.
