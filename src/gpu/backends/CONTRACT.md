# Backend contract

The shared core (`core.zig`, `api.zig`, `validation.zig`) implements everything in
sokol_gfx.h outside the backend sections. `backend.zig` dispatches to the backend
selected in `setup()`, the counterpart of the "generic backend" section of the
header (lines 24132-24741). The Vulkan, WebGPU, D3D12 and Metal backends implement this
contract directly; the GL and D3D11 backends are adapted by glue in `backend.zig`.

## Module layout

Each backend lives in `backends/<name>/` and provides:

- `resources.zig` with `pub fn Resource(comptime Desc: type) type`, returning the
  backend payload struct for `t.BufferDesc`, `t.ImageDesc`, `t.SamplerDesc`,
  `t.ShaderDesc`, `t.PipelineDesc` and `t.ViewDesc` (the `_sg_<backend>_*_t`
  structs of the header, without the `slot` and `cmn` members).
- `backend.zig` with `pub const Backend`, a struct holding the backend state
  (the `_sg_<backend>_backend_t` struct of the header), implementing the methods below.
- Driver interface files as needed (`sdk.zig`, `convert.zig`, ...). There are no
  C imports: driver functions are native Zig function pointers, resolved at runtime.

## Resources

Shared resources are `core.Buffer`, `core.Image`, `core.Sampler`, `core.Shader`,
`core.Pipeline` and `core.View`. Each has:

- `slot`: id, uninit count and state (`_sg_slot_t`).
- `cmn`: the common state (`_sg_buffer_common_t` etc.). References between
  resources are `core.Ref(T)` values: `view.cmn.img.ref.get()`, `pip.cmn.shader.get()`.
- `desc`: the descriptor with defaults applied and every borrowed pointer cleared.
  For texture views, `desc.texture.mip_levels.count` and `slices.count` are resolved.
- `native`: a tagged union with one payload per backend. `create*` sets it, for
  example `buf.native = .{ .vulkan = .{ ... } }`, and later calls use
  `buf.native.vulkan`. `discard*` can be called for resources whose creation
  failed, so check the tag first.

`create*` receives the full caller descriptor (with defaults applied), so it may
read data pointers, shader code and labels. Those pointers are not valid after it returns.

## Methods

```zig
pub fn init(s: *core.State) !Backend            // _sg_<b>_setup_backend: also fills s.features, s.limits, s.formats
pub fn deinit(self: *Backend) void              // _sg_<b>_discard_backend
pub fn resetStateCache(self: *Backend) void
pub fn createBuffer(self, buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState
pub fn discardBuffer(self, buf: *core.Buffer) void
pub fn createImage(self, img: *core.Image, desc: *const t.ImageDesc) e.ResourceState
pub fn discardImage(self, img: *core.Image) void
pub fn createSampler(self, smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState
pub fn discardSampler(self, smp: *core.Sampler) void
pub fn createShader(self, shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState
pub fn discardShader(self, shd: *core.Shader) void
pub fn createPipeline(self, pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState
pub fn discardPipeline(self, pip: *core.Pipeline) void
pub fn createView(self, view: *core.View, desc: *const t.ViewDesc) e.ResourceState
pub fn discardView(self, view: *core.View) void
pub fn beginPass(self, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool  // false invalidates the pass
pub fn endPass(self, atts: *const core.AttachmentsPtrs) void
pub fn applyViewport(self, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void
pub fn applyScissorRect(self, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void
pub fn applyPipeline(self, pip: *core.Pipeline) void
pub fn applyBindings(self, bnd: *const core.BindingsPtrs) bool
pub fn applyUniforms(self, ub_slot: usize, data: *const t.Range) void
pub fn draw(self, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void
pub fn dispatch(self, x: i32, y: i32, z: i32) void
pub fn commit(self) void
pub fn writeBufferTransient(self, buf, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void
pub fn writeImageTransient(self, img, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void
pub fn writeBufferUnsealed(self, buf, desc: *const t.WriteBufferDesc) void
pub fn writeImageUnsealed(self, img, desc: *const t.WriteImageDesc) void
pub fn sealBuffer(self, buf) void
pub fn sealImage(self, img) void
pub fn copyBufferToBuffer(self, src: *core.Buffer, dst: *core.Buffer, desc) void
pub fn copyBufferToImage(self, src: *core.Buffer, dst: *core.Image, desc) void
pub fn pushDebugGroup(self, name: [*:0]const u8) void
pub fn popDebugGroup(self) void
```

Metal additionally provides `device`, `renderCommandEncoder`, `computeCommandEncoder`
and `commandQueue` methods; WebGPU provides `device`, `queue`, `commandEncoder`,
`renderPassEncoder` and `computePassEncoder`. Both export free functions
`query<Kind>Info(res: *const core.<Kind>) t.<Mtl|Wgpu><Kind>Info` for the public
`sg_<backend>_query_*_info` functions.

## Shared state and helpers

- `core.state()` returns the global `core.State` (`_sg`): `desc`, `frame_index`,
  `cur_pass` (`valid`, `is_compute`, `dim`, `action`, `swapchain`), `cur_pip`,
  `use_indexed_draw`, `use_instanced_draw`, `features`, `limits`, `formats`, `allocator`.
- Logging: `core.logError(.item)`, `core.logWarn`, `core.logInfo`, `core.logPanic`,
  `core.logMsg(.item, text)`, the equivalents of `_SG_ERROR` etc.
- Statistics: `core.statsInc("vk.num_cmd_pipeline_barrier")` and `core.statsAdd(path, n)`,
  with a dotted path into `t.FrameStats`, the equivalents of `_sg_stats_inc`/`_sg_stats_add`.
- `core.config.debug` is the equivalent of `SOKOL_DEBUG`.
- `core.miplevelDim`, `core.clipRect`, `core.attachmentsDim`, `core.formats.*` for pixel
  format sizes and pitches.

## Readback and synchronization

`readBuffer(self, buf, offset, out) bool` and
`readImage(self, img, region: *const core.ReadRegion, out) bool` read committed GPU
work outside a pass. They preserve storage row order and the requested pitches.
Depth, compressed and multisampled image reads are rejected by the core.
Synchronous native reads may block; browser WebGPU returns false for them.

All GPU backends also implement owned asynchronous readbacks. Copies are submitted
at request time; ordinary polling never waits. Vulkan, GL/GLES, D3D11, D3D12 and
Metal use `readback_task.Task`: the client owns one reference and the Device
retirement queue another. Prepare queue capacity before recording GPU work;
register the task after submission. Cancellation drops only the client reference.
Commit polls retirement without waiting; teardown drains it before native resources
or loader callbacks are released. Task operations execute in their owning State
scope, including the last client release after Device retirement has completed.

WebGPU's `requestBufferRead` / `requestImageRead` use heap-owned map/future state.
Callbacks retain that state after cancellation, and native teardown drains them.
Every path must keep staging storage, command objects and callbacks alive until
GPU completion or confirmed device removal. Poll failure cannot justify releasing
resources while a healthy GPU might still use them. CPU staging/dummy resources
may complete immediately. Clients release all tickets before destroying the Device
or unloading its native driver library. Browser hosts must yield to their event
loop between polls; synchronous browser WebGPU reads return false.

Transfers and resource retirement must respect command recording order. D3D12
lazily opens a frame for initial/unsealed uploads and retains temporary buffers
until its fence completes. Vulkan records those uploads in the frame's stream
command buffer using mapped chunks owned by that frame slot. A completed slot
caches one normal chunk and discards excess/oversized chunks when it is reused.
No upload submits or waits per resource. Readback submits pending producer work
before its copy. Blocking compatibility reads may still use a one-shot list;
that list never overtakes a pending frame.


## Device ownership and loss

Each public Device owns an independent State. `core.enter` selects it for the
source-shaped internal dispatch and restores the previous selection on return;
native selection is thread-local. Never cache another Device's selected state or
use process-global backend data. Public handles include Device identity. The raw
singleton test API remains separate. Callers synchronize shared native handles
and invalidate a wrapper's state cache after another wrapper changes the same
native context.

Loss is recorded once through `core.recordLoss`. Backend callbacks may record the
atomic loss code, but must not invoke user callbacks from native callback threads.
The public API delivers the notification on the owning thread and rejects new
creation/commands after loss. Reinitialization creates a new Device identity;
resource recovery uses caller-retained CPU descriptors and data.


Vulkan readback fence-query errors retain GPU ownership unless completion or
native device removal is proved. Non-blocking polls never fall back to an idle
wait; teardown may use one to establish completion. Healthy-device idle failures
cannot proceed to resource destruction. Pipeline-cache exports validate headers
using little-endian fields and the complete device UUID; the narrowly guarded
Mesa/lavapipe short-size workaround is documented at its implementation.
