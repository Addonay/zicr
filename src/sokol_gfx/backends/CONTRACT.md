# Backend contract

The shared core (`core.zig`, `api.zig`, `validation.zig`) implements everything in
sokol_gfx.h outside the backend sections. `backend.zig` dispatches to the backend
selected in `setup()`, the counterpart of the "generic backend" section of the
header (lines 24132-24741). The Vulkan, WebGPU and Metal backends implement this
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
