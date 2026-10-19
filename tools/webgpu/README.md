# Native WebGPU providers

The library loads the application's webgpu.h entry points. The scene host uses
`WGPU_NATIVE_LIB` for both wgpu-native and ABI-compatible Dawn; the name is retained
for compatibility. `wgpuGetProcAddress` is not implemented by wgpu-native v29, so
this host resolves exported symbols directly.

Verified locally on Linux/RADV, 2026-10-18:

- wgpu-native v29: DevicePoll completion path, full scenes and async tickets.
- Dawn 67d4d6e64b0755d638f76549794692badfdbc8ab: 57 scene passes, seven
  capability skips, portable limits, async tickets, intentional shader failure
  followed by successful creation, randomized 128-frame resource recycling.
  Dawn uses InstanceWaitAny rather than the wgpu-native DevicePoll extension.

The host queries `wgpuHasInstanceFeature(TimedWaitAny)` when DevicePoll is absent,
requests that feature when creating the instance, and sets a positive native wait
timeout only on that instance. This permits native synchronous shader error scopes.
Application-created instances need the same feature if using a positive
`BackendOptions.wgpu.wait_timeout_ns`. Browser code must yield instead.

## Reproduce Dawn

The official release listing is https://github.com/google/dawn/releases/tag/v20261016.190333.
Its Linux release asset is
`Dawn-67d4d6e64b0755d638f76549794692badfdbc8ab-ubuntu-latest-Release.tar.gz`.
Published SHA-256, verified before extraction:
`20ff88448def9645ceeff30911e07295aeb433be23e26180c96019b4300bff5a`.
The package contains a PIC `lib64/libwebgpu_dawn.a`. For the runtime-loaded host:

```sh
c++ -shared -Wl,--whole-archive "$DAWN/lib64/libwebgpu_dawn.a" \
    -Wl,--no-whole-archive -ldl -pthread -o /tmp/libwebgpu_dawn.so
python3 tools/webgpu/check_abi.py "$WGPU/include/webgpu/webgpu.h" "$DAWN/include/dawn/webgpu.h"
WGPU_NATIVE_LIB=/tmp/libwebgpu_dawn.so zig build test-scenes -- \
    --backend wgpu --portable-limits --async-readback
```

`DAWN` and `WGPU` are the extracted provider directories. The comparison checked
92 common structures and 524 size/offset values with no differences. It does not
prove enum semantics, callback behavior or runtime correctness: the real scene run
is a separate requirement. Do not load arbitrary provider versions on the strength
of the webgpu.h filename. Header/ABI changes require updating bindings and rerunning
all scenes. C++/C here are tools for auditing/building a provider, never dependencies
of zicr's Zig implementation.
