# D3D12 backend design

sokol_gfx has no D3D12 backend, so this one is designed for zicr. It follows the
structure of the Vulkan backend (the closest explicit API in the codebase) and
uses the shared `../dxgi/` COM, DXGI, conversion and HLSL modules. It implements the
contract in `../CONTRACT.md` like the Vulkan, WebGPU and Metal backends.

## Environment and frames

- `desc.environment.d3d12` holds an `ID3D12Device` and a direct `ID3D12CommandQueue`
  owned by the application. The backend AddRefs both and releases them at deinit.
- Two frames in flight (`constants.num_inflight_frames`). Per frame: a command
  allocator, a graphics command list, the fence value signaled at its submit,
  a slice of the shader-visible descriptor heaps, a slice of the upload ring and
  a deferred-release queue (resources destroyed while the GPU may still use them).
- A frame starts lazily with the first recorded command: wait until the frame's
  fence value is completed (`SetEventOnCompletion` + `WaitForSingleObject`),
  release its deferred objects, reset allocator and list, reset its ring slices.
- `commit` closes the list, `ExecuteCommandLists`, `Signal(fence, ++value)`.

## Memory

- Buffers and images are committed resources in the default heap.
- An upload ring per frame (one persistently mapped `UPLOAD` heap buffer split
  into per-frame regions, `desc.uniform_buffer_size` for uniforms plus
  `desc.vulkan.transient_staging_buffer_size`-like sizing for data) serves uniforms
  (256-byte aligned CBVs), transient buffer/image writes and staging copies.
- Initial data and unsealed writes use temporary upload buffers. They lazily
  open a frame, record into that frame's list and retire staging at its fence.
  Bulk loading therefore submits once at commit rather than waiting per resource.
  Readback flushes pending producer commands first. A blocking compatibility
  one-shot list must never overtake recorded frame commands: doing so
  reorders transfers, invalidates resource-state tracking and advances retirement
  tags too early. Draws using unsealed resources are skipped until sealing.
- Deferred release tags use the next frame fence value. No one-shot submission
  can occur while that frame is open. Creation/upload reserves spare
  retirement capacity for every live pool slot plus a temporary upload. If it
  cannot reserve, creation fails before recording new references. Destruction and
  descriptor frees never allocate, flush an active pass or release early on OOM.
- Staging buffers (`usage.staging_buffer`) keep their data in CPU memory and are
  copied through the upload ring, as in the D3D11 backend.
- Texture copies query `GetCopyableFootprints` for the authoritative row count,
  row size, pitch and placement. Arrays and 3D slices are repacked into aligned
  placements; compressed region queries round dimensions to complete blocks.
  Uploads and readbacks use these footprints rather than inferred format pitches.
  `features.copy_buffer_to_image_relaxed_bytes_per_row` is false (as on WebGPU);
  a buffer source at an offset that isn't 512-aligned is first copied into a
  temporary buffer.

## Descriptors

- Persistent descriptors live in CPU-only heaps with free lists: CBV_SRV_UAV for
  texture SRVs, storage buffer SRVs/UAVs (raw, `R32_TYPELESS`, matching the
  `ByteAddressBuffer`/`RWByteAddressBuffer` HLSL that sokol-shdc emits) and
  storage image UAVs; SAMPLER; RTV; DSV. Views create them in `createView`.
- Two shader-visible heaps (CBV_SRV_UAV and SAMPLER, at most 2048 samplers) are
  ring-allocated per frame. `applyBindings` allocates contiguous ranges,
  `CopyDescriptorsSimple` from the CPU heaps, and sets descriptor tables. Unused
  registers inside a range get null descriptors created at setup.

## Root signatures (one per shader)

- One root CBV per uniform block (`b` register `hlsl_register_b_n`, visibility of
  its stage). Uniform data is written into the upload ring and bound with
  `Set{Graphics,Compute}RootConstantBufferView`.
- Per stage (VS and PS for render shaders, ALL for compute): one descriptor table
  for SRVs (`t` registers), one for UAVs (`u` registers), one for samplers (`s`
  registers), each covering registers 0..max used. Shaders keep the parameter
  indices and register layout in their payload.
- Query `D3D12_FEATURE_ROOT_SIGNATURE` and use
  `D3D12SerializeVersionedRootSignature` 1.1 when both device and loader support it.
  Older devices/loaders retain the 1.0 serializer path. Uniform root CBVs promise
  data static while bound at execution because each upload-ring allocation is
  immutable through its frame fence. Resource descriptor tables retain volatile
  data semantics for ordered copies/UAV writes, and explicitly keep buffer bounds
  checks when descriptors are static. Sampler descriptors are static through the
  frame fence. See [descriptor flags](https://learn.microsoft.com/en-us/windows/win32/api/d3d12/ne-d3d12-d3d12_descriptor_range_flags).
  Wine/vkd3d reports and passes the 1.1 path; a genuinely 1.0-only device remains
  an external compatibility verification gate.
- The HLSL target defaults to `vs_5_0`, `ps_5_0`, `cs_5_0` (the shared `d3d11_target` field), since SM 4.x is not valid D3D12 input.

## Shaders and pipelines

- HLSL source is compiled with `D3DCompile` (reuse `../d3d11/compiler.zig`) using
  the target from the shader function (`vs_5_0`, `ps_5_0`, `cs_5_0` from
  sokol-shdc); byte code is used as is. Shader model 5.x DXBC is valid in D3D12.
- Input layout semantics come from the shader's attributes (copied, like D3D11).
- Graphics and compute PSOs are created in `createPipeline`; `applyPipeline` sets
  the PSO, root signature, primitive topology, blend factor and stencil reference.

## Resource states

- Every buffer and image tracks its current `D3D12_RESOURCE_STATES` (whole
  resource). Transitions are recorded before use: render target / depth write at
  begin pass, shader resource / unordered access / vertex / index buffer at
  apply bindings (with UAV barriers between consecutive UAV uses), copy source /
  destination for copies, resolve source / destination for MSAA resolves.
- Swapchain targets come from `pass.swapchain.d3d12` as `ID3D12Resource`
  pointers in `PRESENT` state: the backend creates RTV/DSV descriptors for them
  in reserved per-frame slots, transitions to render target at begin pass and
  back to `PRESENT` at end pass.

## Features and limits

`origin_top_left`, `image_clamp_to_border`, `mrt_independent_*`, `compute`,
`msaa_texture_bindings`, `draw_base_vertex`, `draw_base_instance`,
`dual_source_blending`, `copy_buffer_to_image_relaxed_buffer_type` are true;
pixel format capabilities come from `CheckFeatureSupport(FORMAT_SUPPORT)` like
the D3D11 backend. UAV limits follow the resource binding tier.

## Readback

Owned requests submit a copy on a private allocator/list with a private fence
and a `READBACK` heap resource. Requests and ordinary polls never wait. Image
copies use queried footprints and repack padded rows/slices only after completion.
Cancellation keeps native resources in the Device's retirement queue until the
fence completes. Waiting creates an event lazily, only for synchronous compatibility
reads or teardown. Failed event registration never counts as GPU completion;
retry/poll instead. A failed queue signal on a healthy device cannot safely free
in-flight command storage and is fatal; confirmed device removal records loss.

Synchronous `readBuffer`/`readImage` retain blocking semantics. No readback list
may reorder pending producer commands; requests are validated outside passes and
operate on committed work.
