# TODO.md acceptance audit

This maps the original roadmap to the current implementation. Implementation and available validation are complete; external gates and
explicit future architecture choices remain separated below. Historical TODO source excerpts refer to
254976a; the completion ledger holds dated runtime evidence. All work is uncommitted.

| Original requirement | Current implementation / evidence | Remaining work |
| --- | --- | --- |
| 3 WebGL2 loader, wasm flags, extension/object/memory/readback differences | Native Zig imports plus tools/web/gl.js; real Chromium/Firefox runs | Current guide annotated; historical excerpts identified |
| 4 Browser WebGPU ABI and asynchronous readback | Generated wasm ABI metadata; owned tickets; full Chromium scenes | Canvas presentation and current guide passed/reconciled |
| 5 Browser harness | Isolated Chromium and Firefox profiles, software/hardware modes, exact diagnostics | Latest hardware Chromium/Firefox WebGL2 passed; Firefox WebGPU adapter unavailable locally |
| 6.2 GPU use-after-free | Frame-ordered uploads and retirement; destroy/create regression | Native Windows GPU validation external gate |
| 6.3 Unsealed write ordering | Same frame command stream; ordering regression | Native Windows GPU validation external gate |
| 6.4 Upload batching | D3D12 frame uploads and Vulkan frame upload arenas; submission-count regression | Done locally |
| 6.5 Per-subresource tracking | Current API rejects simultaneous attachment/sample alias; whole-resource tracking retained | Future API extension; current alias rejection remains the supported boundary |
| 6.6 Root signatures and descriptors | Negotiated 1.1 with 1.0 fallback; overflow/recovery test | Optional descriptor-table cache/profiling extension; 1.0-only hardware external gate |
| 6.7 Compiler sharing and diagnostics | backends/dxgi, neutral HLSL diagnostics | SM6/DXC deferred architecture choice |
| 6.8 Enhanced barriers | Legacy barriers supported | Optional modern-SDK path, deferred architecture choice |
| 6.9 Copy footprints / descriptor allocation failure | GetCopyableFootprints; allocation-free descriptor return; BC fixtures | Native Windows driver runtime external gate |
| 6.10 Debug/GPU validation and DRED | Harness and strict Windows CI gate | Native Windows execution external gate |
| 6.11 Swapchain, loss, adapter, readback | Device loss/recovery contract; WARP; native async tickets | Window/preferring-adapter hosts implemented; native Windows validation/presentation gates remain |
| 7 D3D11 removal safety | Shared DXGI/COM/HLSL extracted; D3D11 retained for comparison | Removal gated on native Windows evidence |
| 8 Vulkan portability | Default descriptor sets; opt-in descriptor buffers; Windows Wine scenes | Non-Mesa/Android runtime external gate |
| 8.4 Sync validation, uploads, caches | Both strategies validated, uploads batched, compatible cache persistence | Done locally |
| 9 Native WebGPU futures/errors | Owned callback data, InstanceWaitAny fallback, shader error scopes | Dawn 67d4d6e: 57 pass/7 skip; TimedWaitAny enabled and exercised |
| 10 GL debug/legacy/views | Debug callback; strict 3.3/ES3.0 runs; mip emulation and alias rejection | Mobile/Apple runtime external gates |
| 11 Metal | Native host, async tickets, all-scene macOS/iOS cross checks, strict CI gate | Apple runtime external gate |
| 12.1 Multiple devices | Device-owned State, owner-tagged handles, independent/concurrent tests | Done locally |
| 12.2 Threads | Owner-thread recording contract; cross-thread loss notification | Multithreaded command recording is a future API extension |
| 12.3 Async tickets | Native completion primitives on all backends; cancellation lifetime tests | Done locally; Apple execution external gate |
| 12.4 Device loss | Sticky state, deferred callbacks, recovery using new Device | Hardware-induced removal external gate |
| 12.5 Validation | Public contract and comments; benchmark validation disabled | Public comments, autodoc and README API compilation passed |
| 12.6 Portable limits | Full 63-scene suite: 227 pass, 25 skip across four APIs | Wine 176/16 and software Linux 174/18 passed |
| 13 Compiler override and parser | Lazy compiler override tested with actual wrapper; YAML fixtures | Done locally |
| 13.3 Identifier validation | WGSL/HLSL/MSL reflection keyword/type checks | Done locally; shader compilation and explicit README API sequence compile passed |
| 14 Lifetime/multiframe/churn/exhaustion/formats/samplers | Regression scenes including BC1-7/ETC2/ASTC, sampler variants, dual source | Latest five-config native suite 290 pass/30 skip; both browsers passed |
| 14 MSAA/storage/base-instance/large dispatch | Actual multisample sampling; three storage formats; nonzero first instance; 1M-element dispatch | Wine portable suite passed |
| 14 Real-backend randomized streams | 128-frame, 4096-draw deterministic resource recycling stream | Five native configurations passed |
| 14 Real window/swapchain | Chromium GL/WebGPU canvas and Linux X11 GL/GLES hosts passed | Linux/Win32 Vulkan WSI passed; DXGI Wine fault and Apple/native Windows validation remain gates |
| 15 Performance | C/raw/public GL and Vulkan measurements; native WebGPU tooling passes smoke | D3D11 Wine measurements/profile retained; Metal SDK/native execution external; no D3D12 C baseline exists |
| 16 Documentation / CI | Public autodoc; CONTRACT/DESIGN updates; Linux/Windows/macOS workflows | Current README/TODO reconciled; remote CI external gate |
| 17 Reproduction | Ledger, CI and browser/bench instructions | tasks/VERIFICATION.md consolidates commands and coverage boundaries |
