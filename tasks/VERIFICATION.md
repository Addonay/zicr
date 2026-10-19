# Reproduce the GPU checks

Zig 0.17.0; current runs are from Fedora 44/Mesa 26.2.4 on AMD Renoir. The README
status table and TODO_COMPLETION.md distinguish native runtime, Wine, browser,
cross-compilation and external gates. Capability skips remain skips.

## Core, API, cross-target and shader checks

```sh
zig build check test test-upstream check-metal check-scenes-windows check-scenes-web docs --summary all
zig build test test-upstream -Doptimize=safe --summary all
zig build test-diff -- --runs 10000 --steps 500
```

`tools/module_check.zig` compiles the README API sequence and verifies standalone
`gpu` and `zicr.gpu` share types/identities. `check-metal` forces every scene body
for macOS arm64/x86-64 and iOS arm64; it also checks the macOS window ABI. None of
those cross-checks proves an Apple runtime pass.

An explicit shader executable can be tested with
`zig build test check-scenes-web -Dshader-compiler=/absolute/path/to/sokol-shdc`.
The compiler override bypasses the bundled binary. Parser/identifier fixtures are
included in `test`; generated shaders are compiled by all scene-check steps.

## Linux native APIs

Use a Vulkan 1.3 device. The harness requests Khronos synchronization validation
when its layer is available. To create a manifest from an existing layer library:

```sh
python3 tools/prepare_validation_layer.py /absolute/path/to/libVkLayer_khronos_validation.so /tmp/zicr-layers
```

It queries the library's real metadata; copying an incomplete ad-hoc manifest
can silently omit validation features. Then, with a matching wgpu-native provider:

```sh
VK_ADD_LAYER_PATH=/tmp/zicr-layers WGPU_NATIVE_LIB="$WGPU/lib/libwgpu_native.so" \
  zig build test-scenes -- --backend gl --backend gles --backend vulkan \
    --backend vulkan_descriptor_buffer --backend wgpu --portable-limits --async-readback
```

The `vulkan` variant creates a device without the descriptor-buffer extension;
`vulkan_descriptor_buffer` explicitly enables it. Omit `--async-readback` to check
blocking reads too. Use `--require-native-validation` on GL/GLES/Vulkan to fail if
required layer/debug callbacks are missing; WebGPU uses provider validation and
its uncaptured-error callback instead of that optional native-layer probe.

Software equivalents use `LIBGL_ALWAYS_SOFTWARE=1` and
`VK_DRIVER_FILES=/absolute/path/to/lvp_icd.x86_64.json`. Discover the actual ICD
filename in `/usr/share/vulkan/icd.d`; it is driver/package dependent.

```sh
MESA_GL_VERSION_OVERRIDE=3.3 MESA_GLSL_VERSION_OVERRIDE=330 \
  zig build test-scenes -- --backend gl_legacy --portable-limits --async-readback
MESA_GLES_VERSION_OVERRIDE=3.0 \
  zig build test-scenes -- --backend gles_legacy --portable-limits --async-readback
```

Real window smoke, in a separately owned X server:

```sh
xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 VK_DRIVER_FILES="$LVP_ICD" \
  VK_ADD_LAYER_PATH=/tmp/zicr-layers zig build test-scenes -- \
    --backend gl --backend gles --backend vulkan --window-smoke --require-native-validation
```

`LVP_ICD` is the actual lavapipe manifest. GL/GLES use X11/EGL window surfaces;
Vulkan uses Xlib WSI. Each renders/swaps 32 frames and verifies the final source
pixel. Vulkan window lifetime checking requires VK_EXT_swapchain_maintenance1
and its surface dependencies; presentation fences cover teardown. It fails if
those host extensions are absent. Headless Vulkan does not require them.

## Browsers and native Dawn

```sh
zig build test-web
zig build test-firefox-webgl2
zig build test-web-hardware-webgl2 test-web-hardware-wgpu
```

All browser tools create isolated temporary profiles. `CHROMIUM` and `FIREFOX`
select binaries. Default Chromium uses SwiftShader; hardware steps reject missing
or software adapter identities. The browser suite includes 32 canvas presentation
frames and final-source-pixel readback. Firefox WebGPU did not provide an adapter
in the tested setup; it is a failing external setup gate, not a passing skip.

For Dawn's pinned download, header layout audit and shared-provider build, see
[tools/webgpu/README.md](../tools/webgpu/README.md). Both native providers run the
same scenes. Dawn uses a TimedWaitAny-enabled instance; wgpu-native uses DevicePoll.

## Windows and Apple

Native Windows:

```sh
zig build test test-upstream
zig build test-scenes -- --backend d3d12_warp --require-native-validation --async-readback
zig build test-scenes -- --backend d3d12_warp --window-smoke --require-native-validation
zig build test-scenes -- --backend d3d11 --async-readback
zig build test-scenes -- --backend d3d11 --window-smoke
```

Install DirectX Graphics Tools for the D3D12 debug/GPU-validation gate. D3D11
removal remains gated on that actual native Windows evidence.

For Wine, use only a separately created test prefix and display. The original
TODO environment section describes the native DXVK/vkd3d DLL setup. Copy the
Windows scene executable beside the test's native d3d12/d3d12core DLLs, run from
that owned directory, and set `WINEPREFIX`, `DISPLAY`, and
`WINEDLLOVERRIDES=d3d12,d3d12core=n` explicitly. The validated offscreen command is:

```sh
wine ./zicr-scenes.exe --backend d3d12 --backend d3d11 --backend vulkan \
  --portable-limits --async-readback
```

Current Wine offscreen scenes pass. Win32 Vulkan window smoke passes on lavapipe
with presentation fences, but Wine does not expose the required validation layer.
DXGI window smoke faults in this Wine/Xvfb setup after monitor metadata errors;
no passing D3D11/D3D12 presentation or native Windows validation is claimed.
Cross-target unit tests may invoke Wine automatically: constrain `WINEPREFIX`
and `DISPLAY` explicitly before running them.

Native macOS:

```sh
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER_ERROR_MODE=assert \
  zig build test-scenes -- --backend metal --require-native-validation --async-readback
MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 MTL_DEBUG_LAYER_ERROR_MODE=assert \
  zig build test-scenes -- --backend metal --window-smoke --require-native-validation
```

The harness enforces requested validation flags; command-buffer errors fail via
Device loss. Native Apple execution, the Objective-C benchmark's SDK build, iOS
application-host execution, and remote CI execution remain external gates.

## Performance

[bench/README.md](../bench/README.md) defines timing boundaries, compiler/provider
options and the C/raw/public runner. [bench/RESULTS.md](../bench/RESULTS.md) retains
results, variance, profiles and negative experiments. Current metadata identifies
the reclaiming Zig allocator; earlier arena-based artifacts are historical.
D3D11 Wine draw overhead remains measured and documented. No C sokol D3D12 baseline
exists because upstream has no D3D12 backend.
