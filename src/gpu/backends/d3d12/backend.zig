//! Placeholder D3D12 backend implementing the backend contract (see ../CONTRACT.md).
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");

pub const Backend = struct {
    pub fn init(s: *core.State) !Backend {
        _ = s;
        return error.BackendNotPorted;
    }
    pub fn deinit(self: *Backend) void {
        _ = self;
    }
    pub fn resetStateCache(self: *Backend) void {
        _ = self;
    }
    pub fn createBuffer(self: *Backend, buf: *core.Buffer, desc: *const t.BufferDesc) e.ResourceState {
        _ = .{ self, buf, desc };
        return .failed;
    }
    pub fn discardBuffer(self: *Backend, buf: *core.Buffer) void {
        _ = .{ self, buf };
    }
    pub fn createImage(self: *Backend, img: *core.Image, desc: *const t.ImageDesc) e.ResourceState {
        _ = .{ self, img, desc };
        return .failed;
    }
    pub fn discardImage(self: *Backend, img: *core.Image) void {
        _ = .{ self, img };
    }
    pub fn createSampler(self: *Backend, smp: *core.Sampler, desc: *const t.SamplerDesc) e.ResourceState {
        _ = .{ self, smp, desc };
        return .failed;
    }
    pub fn discardSampler(self: *Backend, smp: *core.Sampler) void {
        _ = .{ self, smp };
    }
    pub fn createShader(self: *Backend, shd: *core.Shader, desc: *const t.ShaderDesc) e.ResourceState {
        _ = .{ self, shd, desc };
        return .failed;
    }
    pub fn discardShader(self: *Backend, shd: *core.Shader) void {
        _ = .{ self, shd };
    }
    pub fn createPipeline(self: *Backend, pip: *core.Pipeline, desc: *const t.PipelineDesc) e.ResourceState {
        _ = .{ self, pip, desc };
        return .failed;
    }
    pub fn discardPipeline(self: *Backend, pip: *core.Pipeline) void {
        _ = .{ self, pip };
    }
    pub fn createView(self: *Backend, view: *core.View, desc: *const t.ViewDesc) e.ResourceState {
        _ = .{ self, view, desc };
        return .failed;
    }
    pub fn discardView(self: *Backend, view: *core.View) void {
        _ = .{ self, view };
    }
    pub fn beginPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
        _ = .{ self, pass, atts };
        return false;
    }
    pub fn endPass(self: *Backend, atts: *const core.AttachmentsPtrs) void {
        _ = .{ self, atts };
    }
    pub fn applyViewport(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
        _ = .{ self, x, y, w, h, origin_top_left };
    }
    pub fn applyScissorRect(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
        _ = .{ self, x, y, w, h, origin_top_left };
    }
    pub fn applyPipeline(self: *Backend, pip: *core.Pipeline) void {
        _ = .{ self, pip };
    }
    pub fn applyBindings(self: *Backend, bnd: *const core.BindingsPtrs) bool {
        _ = .{ self, bnd };
        return false;
    }
    pub fn applyUniforms(self: *Backend, ub_slot: usize, data: *const t.Range) void {
        _ = .{ self, ub_slot, data };
    }
    pub fn draw(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
        _ = .{ self, base_element, num_elements, num_instances, base_vertex, base_instance };
    }
    pub fn dispatch(self: *Backend, x: i32, y: i32, z: i32) void {
        _ = .{ self, x, y, z };
    }
    pub fn commit(self: *Backend) void {
        _ = self;
    }
    pub fn writeBufferTransient(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void {
        _ = .{ self, buf, desc, first_time_in_frame };
    }
    pub fn writeImageTransient(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void {
        _ = .{ self, img, desc, first_time_in_frame };
    }
    pub fn writeBufferUnsealed(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
        _ = .{ self, buf, desc };
    }
    pub fn writeImageUnsealed(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc) void {
        _ = .{ self, img, desc };
    }
    pub fn sealBuffer(self: *Backend, buf: *core.Buffer) void {
        _ = .{ self, buf };
    }
    pub fn sealImage(self: *Backend, img: *core.Image) void {
        _ = .{ self, img };
    }
    pub fn copyBufferToBuffer(self: *Backend, src: *core.Buffer, dst: *core.Buffer, desc: *const t.CopyBufferToBufferDesc) void {
        _ = .{ self, src, dst, desc };
    }
    pub fn copyBufferToImage(self: *Backend, src: *core.Buffer, dst: *core.Image, desc: *const t.CopyBufferToImageDesc) void {
        _ = .{ self, src, dst, desc };
    }
    pub fn pushDebugGroup(self: *Backend, name: [*:0]const u8) void {
        _ = .{ self, name };
    }
    pub fn popDebugGroup(self: *Backend) void {
        _ = self;
    }
    pub fn readBuffer(self: *Backend, buf: *core.Buffer, offset: usize, out: []u8) bool {
        _ = .{ self, buf, offset, out };
        return false;
    }
    pub fn readImage(self: *Backend, img: *core.Image, region: *const core.ReadRegion, out: []u8) bool {
        _ = .{ self, img, region, out };
        return false;
    }
};
