# Real GPU performance baseline

Measured executables are `zicr-bench-gl`, `zicr-bench-vulkan`, and the optional
`zicr-bench-wgpu`; see
[RESULTS.md](RESULTS.md) and `results/` for checked samples and variance. Windows D3D11 and macOS Metal build paths are also available; platform runtime
verification is recorded separately.

```
zig build bench-tools
python3 tools/bench/run.py --output bench/results/gl.json
python3 tools/bench/run.py --executable zig-out/bin/zicr-bench-vulkan --output bench/results/vulkan.json
```

The executable has `--mode c|raw|public`, `--draws`, `--resources`, `--bytes`,
`--samples` and `--warmup`. Defaults: 10,000 draws, 1,000 resource cycles, 4 MiB
transfers, nine samples and three warmups per workload. The runner launches three
rounds in rotating C/raw/public order and retains every raw sample, compiler/CPU/
adapter identity, executable SHA-256, spread and median. The runner rejects a
changed executable during measurement. Use `--draws 100000` for the larger draw test.

All modes use the same shader fixture and 1×1 RGBA8 target. Draws alternate two
vertex buffers and two uniform colors on every call. Resource churn creates and
destroys 4 KiB transient buffers, with an empty clear pass/commit every 64 cycles
so the upstream reference also retires resources on explicit APIs. Uploads write
a transient buffer. Readback measures the synchronous native equivalent from that
buffer. The GPU is drained between samples, including before the timed read, so
this is completed-work readback latency; it does not claim latency behind a busy
GPU queue. Readback is a zicr extension: the C reference uses an equivalent native
operation because upstream sokol has no such API.

Timing covers the API workload and commit, excluding setup, shader compilation,
GPU drain, pixel/byte verification, and JSON/reporting. Pixels and all transferred
bytes are checked outside timing for every sample, including warmup. Native API
errors and library errors fail the run. Validation/debug layers and statistics are
disabled for every mode. C is compiled at O3 with NDEBUG and trace hooks enabled;
Zig is built in fast mode with debug validation disabled. The C reference and its
loops are test tooling only, never part of the library.

These are CPU submission measurements on a trivial GPU workload. Driver behavior,
CPU scheduling, temperature and memory topology still affect them. Keep variance
and the individual samples with any comparison; a single ratio is not a general
backend performance guarantee. Native Windows/Apple/Dawn measurements need their
platforms and are separate from Linux build or software-driver evidence.

Vulkan benchmarks explicitly use descriptor buffers for C, raw and public APIs,
because the pinned C backend requires that extension. The portable descriptor-set
backend is tested for correctness separately. C readback uses native Vulkan copies
and host-coherent staging with the C backend's own resource/state helpers.

Optional native WebGPU build (matching header/provider required):

```sh
zig build bench-tools -Dwebgpu-include="$WGPU/include" -Dwebgpu-library="$WGPU/lib/libwgpu_native.so"
WGPU_NATIVE_LIB="$WGPU/lib/libwgpu_native.so" python3 tools/bench/run.py \
    --executable zig-out/bin/zicr-bench-wgpu --output bench/results/wgpu.json
```

The pinned C WebGPU backend omits texture COPY_SRC usage. The benchmark injects
an equivalent native readable texture using its public native-texture descriptor,
outside timing, and leaves the upstream implementation unchanged. Native copies
and map callbacks verify its outputs. Mandatory WebGPU provider validation remains
in all modes; zicr's optional validation and native GPU debug layers are disabled.

The current Zig backend/context allocator is `std.process.Init.gpa`, recorded in
new result metadata. Input/output arrays and report storage use the process arena
once per run. Early GL/Vulkan artifacts predate this allocator correction; retain
them as historical measurements of that setup. The initial native WebGPU arena/
double-copy run has an explicit filename and must not be treated as the corrected
baseline. C uses its upstream malloc/free allocation path.

Native Windows: `zig build bench-d3d11-tools`; cross-build on Linux with
`-Dtarget=x86_64-windows-gnu`. The runner accepts `--launcher wine` for an isolated
Wine prefix, but those results are translation-layer measurements, not native
Windows evidence. The host records the DXGI adapter identity.

Native macOS: `zig build bench-metal-tools` (requires the Apple SDK). The C reference
is compiled as Objective-C with ARC and Metal/Foundation frameworks. For D3D11 and
Metal, an equal four-byte read outside timing drains the frontend's own producing
queue, because the three frontends may create distinct native command queues.
The ordinary draw/readback output checks remain outside timing. Apple runtime
measurements require an Apple device; cross-checking Zig does not compile Apple
Objective-C SDK headers on Linux.

Vulkan readback now prefers HOST_CACHED|HOST_VISIBLE|HOST_COHERENT memory when
compatible, falling back to visible/coherent memory. The C native equivalent uses
the same policy; upload staging retains its original policy. Readback remains
coherent in both cases, so this does not introduce non-coherent invalidation rules.
The explicit `cached-readback` artifact is the current policy; earlier results
remain historical comparisons, not silently replaced samples.
