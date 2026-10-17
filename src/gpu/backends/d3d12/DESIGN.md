# D3D12 backend design

sokol_gfx has no D3D12 backend, so this one is designed for zicr. It follows the
structure of the Vulkan backend (the closest explicit API in the codebase) and
reuses the D3D11 backend's COM calling and HLSL handling. It implements the
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
- Initial data and unsealed writes use a separate one-shot upload: a temporary
  upload buffer, a dedicated allocator/list, execute, wait (like the Vulkan
  backend's staging copy path).
- Staging buffers (`usage.staging_buffer`) keep their data in CPU memory and are
  copied through the upload ring, as in the D3D11 backend.
- Texture copies use placed footprints computed analytically (rows padded to 256
  bytes, slices to 512 bytes, the layout the copies require) instead of
  `GetCopyableFootprints`; data is repacked into the upload ring.
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
- Serialized with `D3D12SerializeRootSignature` (version 1.0) from d3d12.dll.
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

`readBuffer`/`readImage` wait for the GPU to be idle, copy into a `READBACK`
heap buffer on a one-shot list (images with copyable footprints), wait, map and
repack into the requested pitches.
