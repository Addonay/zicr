# Browser harness and embedding

Build with `zig build check-scenes-web`. Serve `zig-out/web` over HTTP and open
`/?backend=webgl2` or `/?backend=wgpu`; `&filter=texture` narrows the scene set.
WebGPU requires HTTPS or localhost. No Emscripten or npm packages are used.

`zig build test-web` runs both backends using Node and an isolated headless
Chromium profile. `test-web-webgl2` / `test-web-wgpu` run one backend. Set
`CHROMIUM` to a Chromium executable if `google-chrome` isn't installed. The runner
uses SwiftShader so its results are reproducible without a hardware GPU. It fails
on missing results, mismatched pixels, native API errors, traps and timeouts.

`zig build test-firefox-webgl2` and `test-firefox-wgpu` use an isolated headless
Firefox profile and WebDriver BiDi (Node 22+ required). `FIREFOX` selects its
executable. No existing browser session or profile is used. Firefox 157 WebGL2:
30 passed, seven capability skips; renderer strings may be privacy-masked.
Firefox WebGPU currently fails with "WebGPU adapter unavailable" on this Linux
headless setup. This is an explicit verification failure, not a passing skip.

`zig build test-web-hardware-webgl2` / `test-web-hardware-wgpu` request hardware
Chromium adapters and reject missing or software identities. They use
`--enable-gpu --use-angle=vulkan`, following Chromium's
[headless hardware guide](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/docs/gpu/using-gpu-hardware-in-headless-chrome.md).
Verified locally: ANGLE/RADV AMD WebGL2 30 passed/seven skips; AMD WebGPU
34 passed/three skips. Adapter identity is captured in the JSON output.

## Embedding an application

The application creates the canvas/context or requests a WebGPU adapter/device;
the library owns neither. Use `gl.js` / `wgpu.js` as ES modules. Each bridge
returns an `imports` object for the matching wasm import namespace.

- GL: `webGLImports(context, () => exports.memory)`, with
  `gpu.web.glProcAddress` as the GLES loader. After instantiation, call
  `bridge.initializeStrings(pointer, capacity)` with a persistent wasm scratch
  buffer (64 KiB by default). Extension strings must be initialized before the
  device. GL names, object tables and uniform locations are private to the bridge.
- WebGPU: `webGPUImports(device, () => exports)`, then call `initialize()` after
  instantiation. Pass its `deviceId` to `.backend.wgpu.device` using
  `@ptrFromInt`, and use `gpu.web.wgpuProcAddress` as the loader. Export
  `wgpu_layout_ptr` / `wgpu_layout_len` exposing `gpu.web.wgpu_layout`,
  `alloc(size)` / `free(pointer, size)` for mapped bytes, and
  `mapped_callback(callback, status, userdata1, userdata2)` calling
  `gpu.web.dispatchMapCallback`. `main.zig` contains the exact working exports.
  Request optional features before creating the device; capability queries report
  only features present on that device.
- Both: export wasm memory, keep bridges/wasm exports alive until all GPU promises
  complete, and provide a logging/panic target. `main.zig` imports `host.log`.
  Do not cache views of wasm memory across calls or `memory.grow`.

For presentation, GL framebuffer zero is the canvas. For WebGPU configure a
`GPUCanvasContext`, add each current texture view to the bridge with `addObject`,
pass that handle in the swapchain descriptor, and release it with `releaseObject`
after recording the frame. Match `Options.defaults.color_format` to the canvas.
The suite also renders 32 real canvas frames, yielding between acquisitions, and
verifies the final pixel before the drawing buffer or current texture expires.

## Readback

Commit producer work, call `requestReadBuffer` or `requestReadImage`, and retain
the owned ticket between frames. `poll()` returns null until ready. Return to the
event loop between polls; spinning in wasm prevents WebGPU promises from settling.
Release tickets before device teardown. Their allocator must live until teardown.
The browser bridge also retains the wasm instance through pending callbacks.

The scene harness replays deterministic scenes after each async readback
checkpoint. Completed tickets supply snapshots on subsequent replays, so the
shared CPU expectations stay unchanged. This is test-only control flow: production
applications should retain tickets and continue rendering normally.

WebGL2 has no compute or base-vertex path in this bridge. Canonical RGBA byte,
integer and float reads are repacked into the image's channel count and row pitch.
Exact packed-format (`rgb10a2`, `rg11b10f`) reads return `ReadFailed`. WebGPU's
synchronous `readBuffer` / `readImage` also return `ReadFailed`; use tickets.

This implements the webgpu.h functions used by zicr's backend, not arbitrary
webgpu.h programs, surfaces or extension chains. Firefox WebGPU and mobile browsers require their own runtime verification.
Chromium hardware mode has passed on the local AMD adapter; the harness rejects
software or missing adapter identities when that mode is requested.

The canvas test uses `present_frame` from `main.zig` and acquires a new WebGPU
current texture per animation turn. Readback copies the last current texture
before yielding; WebGL reads framebuffer zero before its drawing buffer is
invalidated. This verifies the presentation source image; it is not a screenshot
comparison of a browser compositor or physical display.
