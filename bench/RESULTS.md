# GL baseline, 2026-10-18

AMD Radeon Graphics (Renoir), Mesa 26.2.4/radeonsi, Zig 0.17.0 fast, znver3.
The shaders render a 1×1 target while alternating two vertex buffers and uniforms.
Every sample checks pixels and transfer bytes outside timing. Debugging, validation
and statistics are disabled. Three rotating-order process rounds give 27 measured
samples per workload/mode; raw data and binary fingerprints are in `results/`.

| 100,000 draws | Before, median ms | After borrowing binding data, median ms | After CV |
| --- | ---: | ---: | ---: |
| C sokol | 41.382 | 40.278 | 2.6% |
| raw Zig | 71.099 | 40.699 | 7.1% |
| public Device | 72.158 | 41.608 | 7.8% |

The measured Zig draw CPU time fell about 42% in this workload. The contemporaneous
C baseline moved by about 3%; after the change, raw/public medians are about 1%/3%
above C. This is one workload/driver, not a general performance guarantee.

A userspace CPU profile found memcpyFast at 24.35% and backend.applyBindings at
17.41% self cycles. The change borrows immutable metadata/arrays and fills the
native adapter directly in caller storage, avoiding multi-kilobyte snapshots.
`profile-gl-before.txt` retains the local-symbol report. Reproduce capture with:

```
perf record -o /tmp/zicr-profile.data -e cycles:u -F 499 --call-graph dwarf,8192 -- \
  ./zig-out/bin/zicr-bench-gl --mode raw --draws 100000 --resources 64 \
  --bytes 4096 --samples 40 --warmup 3
DEBUGINFOD_URLS= perf report --stdio --no-children --no-inline --no-call-graph \
  --percent-limit 1 -i /tmp/zicr-profile.data
```

Resource churn and transfers are much closer to C than the original draw path.
Some transfer/readback samples are noisy (up to about 87% coefficient of variation
in the later run), so those medians do not establish a small speed difference.
The readback workload reads completed work; C uses a native GL equivalent because
upstream sokol has no readback API. See README for timing boundaries and commands.

D3D11 and Metal native-platform measurements remain separate gates. Upstream has no D3D12 backend, so no C sokol D3D12 comparison is claimed.

## Vulkan baseline, 2026-10-19

Same machine/compiler, RADV 26.2.4, descriptor buffers in all three modes.
Three rotating-order rounds, 27 samples/workload/mode, 10,000 draws:

| Mode | Draws median ms | Draws CV | Churn median ms | Upload median ms | Readback median ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| C sokol | 3.772 | 11.0% | 40.554 | 0.372 | 19.887 |
| raw Zig | 3.789 | 6.2% | 40.176 | 0.366 | 20.188 |
| public Device | 3.896 | 5.0% | 40.644 | 0.361 | 19.965 |

These small median differences are within the observed variation; no speedup or
broad parity guarantee follows. C uses native Vulkan readback because upstream
has no readback API. Full samples, transfer variance and executable identity are
in `results/vulkan-2026-10-19-10000.json`. The 100,000-draw case also passed: C 37.686 ms (CV 1.6%), raw 38.622 ms
(CV 2.3%), public 40.694 ms (CV 12.0%). Raw is 2.5% above C in these samples;
the public median is 8.0% above C with substantial variation. Churn and transfer
medians are close to C. Full data: `results/vulkan-2026-10-19-100000.json`.

## Native WebGPU, 2026-10-19

wgpu-native v29 on the same RADV GPU, 10,000 draws, 27 samples per mode/workload:

| Mode | Draws median ms | Draws CV | 4MiB readback median ms | Readback CV |
| --- | ---: | ---: | ---: | ---: |
| C sokol | 10.973 | 3.5% | 1.296 | 17.5% |
| raw Zig | 9.746 | 4.5% | 1.348 | 10.8% |
| public Device | 9.724 | 3.6% | 1.263 | 11.0% |

These corrected samples use `Init.gpa` for Zig resource allocation. An initial
arena/double-copy run showed roughly 5.2ms Zig readback. That experiment remains
under an explicit filename: allocator reclamation and the synchronous read path
both changed, so it does not isolate one optimization's effect. The current
blocking implementation copies directly into borrowed output; owned tickets retain
their lifetime contract. Transfer/churn variation reaches 33%, so small ratios
are not reliable claims. Full data: `wgpu-native-2026-10-19-10000.json`.

## D3D11 through Wine/DXVK, 2026-10-19

Explicit RADV driver; adapter AMD Radeon Graphics (RADV RENOIR), vendor 1002 /
device 15e7. These are translation-layer measurements, not native Windows results.
27 samples/mode/workload, 10,000 draws:

| Mode | Before median ms | After borrowed descriptor arrays ms | After draw CV |
| --- | ---: | ---: | ---: |
| C sokol | 4.301 | 4.449 | 5.2% |
| raw Zig | 7.213 | 5.900 | 5.3% |
| public Device | 7.234 | 6.081 | 3.3% |

Borrowing lowers the observed Zig draw median by about 16–18%, while the C median
moves about 3%. A substantial 33–37% gap remains; no parity claim is made. The CPU
profile resolves hot PE addresses to memcpy/memset; it also includes DXVK's worker
thread, so whole-process percentages are not all library overhead.
`profile-d3d11-before.txt` preserves the report and symbolization commands/identity.
A subsequent optional-record initialization experiment did not provide a reliable
win and was reverted; its samples are retained as `10000-optional-tags.json`.
Churn and transfer results are much closer to C, with variance retained in all
three result files. Native Windows/Apple execution remains a separate gate.

## Current GL allocator baseline

The corrected Init.gpa setup at 10k draws gives C 3.796ms (CV 2.5%), raw 4.040ms
(CV 7.1%), public 4.199ms (CV 10.0%). These are 6.4%/10.6% above C with material
variation; the historical 100k before/after profile experiment above used its own
consistent arena setup and should not be conflated with this run. Transfers are
close in median, with variation retained. Data: `gl-2026-10-19-10000-gpa.json`.

## Vulkan cached-coherent readback

Before selecting readback-specific memory, the current Init.gpa run read 4 MiB in
C 19.886ms, raw 19.792ms and public 19.655ms. The staging allocator had selected the
first visible/coherent type, suitable for uploads but potentially uncached for
CPU reads. Both the library and C native-equivalent now prefer cached coherent
memory and fall back to coherent memory, leaving upload policy unchanged.
Matched medians are C 2.048ms, raw 1.825ms and public 2.003ms, approximately tenfold
less time on this driver. CV 14–26% does not support small inter-mode speed claims.
Unit tests protect coherence, allowed memory bits and fallback. Both Vulkan
strategies pass the full async scene suite. Data: `vulkan-2026-10-19-10000-gpa.json`
and `vulkan-2026-10-19-10000-cached-readback.json`.
