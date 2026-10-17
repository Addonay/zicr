//! Metal passes, bindings, uniforms, draws, transfers and debug groups, from
//! sokol_gfx.h:17060-18427 (_sg_mtl_begin_pass through _sg_mtl_pop_debug_group).
//!
//! Command buffers and encoders are retained by the backend while they are in use and
//! released when they are ended or committed, so their lifetime does not depend on an
//! autorelease pool. Render pass descriptors are pinned in the id pool until the frames
//! in flight are done with them, as the swapchain descriptors are in the header.
const std = @import("std");
const t = @import("../../types.zig");
const e = @import("../../enums.zig");
const core = @import("../../core.zig");
const constants = @import("../../constants.zig");
const sdk = @import("sdk.zig");
const convert = @import("convert.zig");
const r = @import("resources.zig");
const backend_mod = @import("backend.zig");
const Backend = backend_mod.Backend;

const num_inflight = constants.num_inflight_frames;

/// The encoder kinds a binding is made on.
const Stage = enum { vertex, fragment, compute };

fn uint(value: anytype) sdk.Uint {
    return @intCast(value);
}

/// The mutable Objective-C object behind a `const void*` handle from the application.
fn mutableId(handle: ?*const anyopaque) sdk.Id {
    return if (handle) |ptr| @constCast(ptr) else null;
}

// ---------------------------------------------------------------- passes

fn clearStateCache(self: *Backend) void {
    self.resetStateCache();
}

fn acquireCmdBuffer(self: *Backend) void {
    if (self.cmd_buffer != null) return;
    // block until the oldest frame in flight has finished
    sdk.semaphoreWait(self.sem);
    const cmd_buffer = if (core.state().desc.metal.use_command_buffer_with_retained_references)
        sdk.msg(sdk.Id, self.cmd_queue, "commandBuffer", .{})
    else
        sdk.msg(sdk.Id, self.cmd_queue, "commandBufferWithUnretainedReferences", .{});
    self.cmd_buffer = sdk.retain(cmd_buffer);
    completion_semaphore = self.sem;
    sdk.msg(void, self.cmd_buffer, "enqueue", .{});
    sdk.msg(void, self.cmd_buffer, "addCompletedHandler:", .{sdk.globalBlock(&commandBufferCompleted)});
}

/// Semaphore signaled by the completion handler of every command buffer. Only one
/// Metal backend is active at a time, so it is a plain global like `_sg.mtl.sem`.
var completion_semaphore: sdk.Id = null;

/// Completion handler of the command buffers, called on a Metal thread.
fn commandBufferCompleted(block: ?*anyopaque, cmd_buffer: sdk.Id) callconv(.c) void {
    _ = block;
    _ = cmd_buffer;
    sdk.semaphoreSignal(completion_semaphore);
}

fn acquireBlitCmdEncoder(self: *Backend) void {
    std.debug.assert(self.cmd_buffer != null);
    if (self.blit_cmd_encoder == null) {
        self.blit_cmd_encoder = sdk.retain(sdk.msg(sdk.Id, self.cmd_buffer, "blitCommandEncoder", .{}));
    }
    std.debug.assert(self.blit_cmd_encoder != null);
}

fn finishBlitCmdEncoder(self: *Backend) void {
    if (self.blit_cmd_encoder != null) {
        sdk.msg(void, self.blit_cmd_encoder, "endEncoding", .{});
        sdk.release(self.blit_cmd_encoder);
        self.blit_cmd_encoder = null;
    }
}

fn setLoadAction(desc: sdk.Id, action: e.LoadAction) void {
    sdk.msg(void, desc, "setLoadAction:", .{convert.loadAction(action)});
}

fn setStoreAction(desc: sdk.Id, action: e.StoreAction, resolve: bool) void {
    sdk.msg(void, desc, "setStoreAction:", .{convert.storeAction(action, resolve)});
}

fn clearColor(color: t.Color) sdk.ClearColor {
    return .{ .red = color.r, .green = color.g, .blue = color.b, .alpha = color.a };
}

/// Sets the slice of a cube or array image, or the depth plane of a 3D image.
fn setSliceOrDepthPlane(desc: sdk.Id, image_type: e.ImageType, slice: i32, comptime slice_sel: [:0]const u8, comptime plane_sel: [:0]const u8) void {
    switch (image_type) {
        .cube, .array => sdk.msg(void, desc, slice_sel, .{uint(slice)}),
        .@"3d" => sdk.msg(void, desc, plane_sel, .{uint(slice)}),
        else => {},
    }
}

fn beginComputePass(self: *Backend, pass: *const t.Pass) bool {
    self.compute_cmd_encoder = sdk.retain(sdk.msg(sdk.Id, self.cmd_buffer, "computeCommandEncoder", .{}));
    if (self.compute_cmd_encoder == null) return false;
    if (core.config.debug) if (pass.label) |label| sdk.msg(void, self.compute_cmd_encoder, "setLabel:", .{sdk.nsString(label)});
    return true;
}

fn beginRenderPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
    const action = &pass.action;
    const pass_desc = sdk.allocInit("MTLRenderPassDescriptor");

    if (!atts.empty) {
        // offscreen rendering into the attachment views
        for (0..atts.num_color_views) |i| {
            const color_view = atts.color_views[i] orelse unreachable;
            const resolve_view = atts.resolve_views[i];
            const color_img = color_view.cmn.img.ref.get();
            std.debug.assert(color_img.slot.state == .valid);
            std.debug.assert(color_img.cmn.active_slot == 0);
            std.debug.assert(color_img.native.metal.tex[0] != 0);
            const color = sdk.msg(sdk.Id, sdk.msg(sdk.Id, pass_desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{uint(i)});
            setLoadAction(color, action.colors[i].load_action);
            setStoreAction(color, action.colors[i].store_action, resolve_view != null);
            sdk.msg(void, color, "setClearColor:", .{clearColor(action.colors[i].clear_value)});
            sdk.msg(void, color, "setTexture:", .{self.idpool.id(color_img.native.metal.tex[0])});
            sdk.msg(void, color, "setLevel:", .{uint(color_view.cmn.img.mip_level)});
            setSliceOrDepthPlane(color, color_img.cmn.type, color_view.cmn.img.slice, "setSlice:", "setDepthPlane:");
            if (resolve_view) |resolve| {
                const resolve_img = resolve.cmn.img.ref.get();
                std.debug.assert(resolve_img.slot.state == .valid);
                std.debug.assert(resolve_img.cmn.active_slot == 0);
                std.debug.assert(resolve_img.native.metal.tex[0] != 0);
                sdk.msg(void, color, "setResolveTexture:", .{self.idpool.id(resolve_img.native.metal.tex[0])});
                sdk.msg(void, color, "setResolveLevel:", .{uint(resolve.cmn.img.mip_level)});
                setSliceOrDepthPlane(color, resolve_img.cmn.type, resolve.cmn.img.slice, "setResolveSlice:", "setResolveDepthPlane:");
            }
        }
        if (atts.ds_view) |ds_view| {
            const ds_img = ds_view.cmn.img.ref.get();
            std.debug.assert(ds_img.slot.state == .valid);
            std.debug.assert(ds_img.cmn.active_slot == 0);
            std.debug.assert(ds_img.native.metal.tex[0] != 0);
            const depth = sdk.msg(sdk.Id, pass_desc, "depthAttachment", .{});
            sdk.msg(void, depth, "setTexture:", .{self.idpool.id(ds_img.native.metal.tex[0])});
            setLoadAction(depth, action.depth.load_action);
            setStoreAction(depth, action.depth.store_action, false);
            sdk.msg(void, depth, "setClearDepth:", .{@as(f64, action.depth.clear_value)});
            setSliceOrDepthPlane(depth, ds_img.cmn.type, ds_view.cmn.img.slice, "setSlice:", "setDepthPlane:");
            if (core.isDepthStencilFormat(ds_img.cmn.pixel_format)) {
                const stencil = sdk.msg(sdk.Id, pass_desc, "stencilAttachment", .{});
                sdk.msg(void, stencil, "setTexture:", .{self.idpool.id(ds_img.native.metal.tex[0])});
                setLoadAction(stencil, action.stencil.load_action);
                setStoreAction(stencil, action.stencil.store_action, false);
                sdk.msg(void, stencil, "setClearStencil:", .{@as(sdk.Uint, action.stencil.clear_value)});
                setSliceOrDepthPlane(stencil, ds_img.cmn.type, ds_view.cmn.img.slice, "setSlice:", "setDepthPlane:");
            }
        }
    } else {
        // swapchain rendering, the drawable is only valid while the window is not minimized
        const drawable = mutableId(pass.swapchain.metal.current_drawable);
        if (drawable == null) {
            sdk.release(pass_desc);
            return false;
        }
        self.cur_drawable = drawable;
        const drawable_texture = sdk.msg(sdk.Id, drawable, "texture", .{});
        const color = sdk.msg(sdk.Id, sdk.msg(sdk.Id, pass_desc, "colorAttachments", .{}), "objectAtIndexedSubscript:", .{uint(0)});
        if (pass.swapchain.sample_count > 1) {
            // multi-sampling: render into the msaa texture, resolve into the drawable texture
            const msaa_tex = mutableId(pass.swapchain.metal.msaa_color_texture);
            std.debug.assert(msaa_tex != null);
            sdk.msg(void, color, "setTexture:", .{msaa_tex});
            sdk.msg(void, color, "setResolveTexture:", .{drawable_texture});
            sdk.msg(void, color, "setStoreAction:", .{sdk.StoreAction.multisample_resolve});
        } else {
            // non-msaa: render into the drawable
            sdk.msg(void, color, "setTexture:", .{drawable_texture});
            sdk.msg(void, color, "setStoreAction:", .{sdk.StoreAction.store});
        }
        setLoadAction(color, action.colors[0].load_action);
        sdk.msg(void, color, "setClearColor:", .{clearColor(action.colors[0].clear_value)});

        // optional depth-stencil texture
        if (mutableId(pass.swapchain.metal.depth_stencil_texture)) |ds_tex| {
            const depth = sdk.msg(sdk.Id, pass_desc, "depthAttachment", .{});
            sdk.msg(void, depth, "setTexture:", .{ds_tex});
            setStoreAction(depth, .dontcare, false);
            setLoadAction(depth, action.depth.load_action);
            sdk.msg(void, depth, "setClearDepth:", .{@as(f64, action.depth.clear_value)});
            if (core.isDepthStencilFormat(pass.swapchain.depth_format)) {
                const stencil = sdk.msg(sdk.Id, pass_desc, "stencilAttachment", .{});
                sdk.msg(void, stencil, "setTexture:", .{ds_tex});
                setStoreAction(stencil, .dontcare, false);
                setLoadAction(stencil, action.stencil.load_action);
                sdk.msg(void, stencil, "setClearStencil:", .{@as(sdk.Uint, action.stencil.clear_value)});
            }
        }
    }

    // pin the attachments in the id pool so that they outlive the command buffer, which
    // does not retain its references
    const pass_desc_ref = self.idpool.addResource(pass_desc);
    self.idpool.releaseResource(core.state().frame_index, pass_desc_ref);

    // this might be null if the window is minimized
    self.render_cmd_encoder = sdk.retain(sdk.msg(sdk.Id, self.cmd_buffer, "renderCommandEncoderWithDescriptor:", .{pass_desc}));
    if (self.render_cmd_encoder == null) return false;
    if (core.config.debug) if (pass.label) |label| sdk.msg(void, self.render_cmd_encoder, "setLabel:", .{sdk.nsString(label)});
    return true;
}

/// Starts a pass, returns false if its encoder cannot be created (_sg_mtl_begin_pass).
pub fn beginPass(self: *Backend, pass: *const t.Pass, atts: *const core.AttachmentsPtrs) bool {
    std.debug.assert(self.cmd_queue != null);
    std.debug.assert(self.compute_cmd_encoder == null and self.render_cmd_encoder == null);
    std.debug.assert(self.cur_drawable == null);

    finishBlitCmdEncoder(self);
    clearStateCache(self);
    acquireCmdBuffer(self);
    std.debug.assert(self.cmd_buffer != null);

    // if this is the first pass in the frame, get the uniform buffer base pointer
    if (self.cur_ub_base_ptr == null) {
        const contents = sdk.msg(?*anyopaque, self.uniform_buffers[self.cur_frame_rotate_index], "contents", .{});
        self.cur_ub_base_ptr = @ptrCast(contents);
    }

    const valid = if (pass.compute) beginComputePass(self, pass) else beginRenderPass(self, pass, atts);
    // bind the uniform buffers, these bindings remain valid for the entire pass
    if (valid) bindUniformBuffers(self);
    return valid;
}

/// Binds the uniform buffer of the frame to every slot, the offsets are set in applyUniforms
/// (_sg_mtl_bind_uniform_buffers).
fn bindUniformBuffers(self: *Backend) void {
    const buffer = self.uniform_buffers[self.cur_frame_rotate_index];
    if (core.state().cur_pass.is_compute) {
        std.debug.assert(self.compute_cmd_encoder != null);
        for (0..constants.max_uniformblock_bindslots) |slot| {
            sdk.msg(void, self.compute_cmd_encoder, "setBuffer:offset:atIndex:", .{ buffer, uint(0), uint(slot) });
        }
    } else {
        std.debug.assert(self.render_cmd_encoder != null);
        for (0..constants.max_uniformblock_bindslots) |slot| {
            sdk.msg(void, self.render_cmd_encoder, "setVertexBuffer:offset:atIndex:", .{ buffer, uint(0), uint(slot) });
            sdk.msg(void, self.render_cmd_encoder, "setFragmentBuffer:offset:atIndex:", .{ buffer, uint(0), uint(slot) });
        }
    }
}

/// Ends the pass and presents the swapchain drawable (_sg_mtl_end_pass).
pub fn endPass(self: *Backend, atts: *const core.AttachmentsPtrs) void {
    _ = atts;
    if (self.render_cmd_encoder != null) {
        sdk.msg(void, self.render_cmd_encoder, "endEncoding", .{});
        sdk.release(self.render_cmd_encoder);
        self.render_cmd_encoder = null;
    }
    if (self.compute_cmd_encoder != null) {
        sdk.msg(void, self.compute_cmd_encoder, "endEncoding", .{});
        sdk.release(self.compute_cmd_encoder);
        self.compute_cmd_encoder = null;
    }
    // if this is a swapchain pass, present the drawable
    if (self.cur_drawable != null) {
        sdk.msg(void, self.cmd_buffer, "presentDrawable:", .{self.cur_drawable});
        self.cur_drawable = null;
    }
}

/// Commits the frame's command buffer and advances to the next uniform buffer (_sg_mtl_commit).
pub fn commit(self: *Backend) void {
    std.debug.assert(self.render_cmd_encoder == null and self.compute_cmd_encoder == null);
    finishBlitCmdEncoder(self);

    if (self.cmd_buffer != null) {
        sdk.msg(void, self.cmd_buffer, "commit", .{});
        sdk.release(self.cmd_buffer);
    }

    // garbage-collect the resources pending for release
    self.idpool.garbageCollect(core.state().frame_index);

    // rotate the uniform buffer slot
    self.cur_frame_rotate_index = (self.cur_frame_rotate_index + 1) % @as(u32, num_inflight);
    self.cur_ub_offset = 0;
    self.cur_ub_base_ptr = null;
    self.cmd_buffer = null;
}

// ---------------------------------------------------------------- viewport, scissor, pipeline

pub fn applyViewport(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
    std.debug.assert(self.render_cmd_encoder != null);
    const dim = core.state().cur_pass.dim;
    std.debug.assert(dim.height > 0);
    const vp: sdk.Viewport = .{
        .origin_x = @floatFromInt(x),
        .origin_y = @floatFromInt(if (origin_top_left) y else dim.height - (y + h)),
        .width = @floatFromInt(w),
        .height = @floatFromInt(h),
        .znear = 0.0,
        .zfar = 1.0,
    };
    sdk.msg(void, self.render_cmd_encoder, "setViewport:", .{vp});
}

pub fn applyScissorRect(self: *Backend, x: i32, y: i32, w: i32, h: i32, origin_top_left: bool) void {
    std.debug.assert(self.render_cmd_encoder != null);
    const dim = core.state().cur_pass.dim;
    std.debug.assert(dim.width > 0 and dim.height > 0);
    // clip against the framebuffer rect
    const clip = core.clipRect(x, y, w, h, dim.width, dim.height);
    const rect: sdk.ScissorRect = .{
        .x = uint(clip.x),
        .y = uint(if (origin_top_left) clip.y else dim.height - (clip.y + clip.h)),
        .width = uint(clip.w),
        .height = uint(clip.h),
    };
    sdk.msg(void, self.render_cmd_encoder, "setScissorRect:", .{rect});
}

/// Sets the pipeline state and its fixed-function state, skipped when already current (_sg_mtl_apply_pipeline).
pub fn applyPipeline(self: *Backend, pip: *core.Pipeline) void {
    if (self.cache.cur_pip.eqlSlot(&pip.slot)) return;
    self.cache.cur_pip = core.SlotRef.of(&pip.slot);
    const res = &pip.native.metal;
    const s = core.state();
    if (pip.cmn.is_compute) {
        std.debug.assert(s.cur_pass.is_compute);
        std.debug.assert(self.compute_cmd_encoder != null);
        std.debug.assert(res.cps != 0);
        sdk.msg(void, self.compute_cmd_encoder, "setComputePipelineState:", .{self.idpool.id(res.cps)});
    } else {
        std.debug.assert(!s.cur_pass.is_compute);
        std.debug.assert(self.render_cmd_encoder != null);
        const c = pip.cmn.blend_color;
        sdk.msg(void, self.render_cmd_encoder, "setBlendColorRed:green:blue:alpha:", .{ c.r, c.g, c.b, c.a });
        core.statsInc("metal.pipeline.num_set_blend_color");
        sdk.msg(void, self.render_cmd_encoder, "setCullMode:", .{res.cull_mode});
        core.statsInc("metal.pipeline.num_set_cull_mode");
        sdk.msg(void, self.render_cmd_encoder, "setFrontFacingWinding:", .{res.winding});
        core.statsInc("metal.pipeline.num_set_front_facing_winding");
        sdk.msg(void, self.render_cmd_encoder, "setStencilReferenceValue:", .{res.stencil_ref});
        core.statsInc("metal.pipeline.num_set_stencil_reference_value");
        sdk.msg(void, self.render_cmd_encoder, "setDepthBias:slopeScale:clamp:", .{ pip.cmn.depth.bias, pip.cmn.depth.bias_slope_scale, pip.cmn.depth.bias_clamp });
        core.statsInc("metal.pipeline.num_set_depth_bias");
        std.debug.assert(res.rps != 0);
        sdk.msg(void, self.render_cmd_encoder, "setRenderPipelineState:", .{self.idpool.id(res.rps)});
        core.statsInc("metal.pipeline.num_set_render_pipeline_state");
        std.debug.assert(res.dss != 0);
        sdk.msg(void, self.render_cmd_encoder, "setDepthStencilState:", .{self.idpool.id(res.dss)});
        core.statsInc("metal.pipeline.num_set_depth_stencil_state");
    }
}

// ---------------------------------------------------------------- bindings

/// Last-applied buffer state of a slot, compared against the new binding (_sg_mtl_cache_buf_cmp).
fn cacheBufCmp(item: *const backend_mod.CacheBuf, slot: *const core.Slot, active_slot: i32, offset: i32) u8 {
    var res: u8 = backend_mod.cache_cmp_equal;
    if (!item.sref.eqlSlot(slot)) res |= backend_mod.cache_cmp_sref;
    if (item.active_slot != active_slot) res |= backend_mod.cache_cmp_activeslot;
    if (item.offset != offset) res |= backend_mod.cache_cmp_offset;
    return res;
}

fn cacheBufUpd(item: *backend_mod.CacheBuf, slot: *const core.Slot, active_slot: i32, offset: i32) void {
    item.* = .{ .sref = core.SlotRef.of(slot), .active_slot = active_slot, .offset = offset };
}

fn cacheTexCmp(item: *const backend_mod.CacheTex, slot: *const core.Slot, active_slot: i32) u8 {
    var res: u8 = backend_mod.cache_cmp_equal;
    if (!item.sref.eqlSlot(slot)) res |= backend_mod.cache_cmp_sref;
    if (item.active_slot != active_slot) res |= backend_mod.cache_cmp_activeslot;
    return res;
}

fn cacheTexUpd(item: *backend_mod.CacheTex, slot: *const core.Slot, active_slot: i32) void {
    item.* = .{ .sref = core.SlotRef.of(slot), .active_slot = active_slot };
}

fn setStageBuffer(self: *Backend, comptime stage: Stage, buffer: sdk.Id, offset: sdk.Uint, index: sdk.Uint) void {
    switch (stage) {
        .vertex => sdk.msg(void, self.render_cmd_encoder, "setVertexBuffer:offset:atIndex:", .{ buffer, offset, index }),
        .fragment => sdk.msg(void, self.render_cmd_encoder, "setFragmentBuffer:offset:atIndex:", .{ buffer, offset, index }),
        .compute => sdk.msg(void, self.compute_cmd_encoder, "setBuffer:offset:atIndex:", .{ buffer, offset, index }),
    }
}

fn setStageBufferOffset(self: *Backend, comptime stage: Stage, offset: sdk.Uint, index: sdk.Uint) void {
    switch (stage) {
        .vertex => sdk.msg(void, self.render_cmd_encoder, "setVertexBufferOffset:atIndex:", .{ offset, index }),
        .fragment => sdk.msg(void, self.render_cmd_encoder, "setFragmentBufferOffset:atIndex:", .{ offset, index }),
        .compute => sdk.msg(void, self.compute_cmd_encoder, "setBufferOffset:atIndex:", .{ offset, index }),
    }
}

fn setStageTexture(self: *Backend, comptime stage: Stage, texture: sdk.Id, index: sdk.Uint) void {
    switch (stage) {
        .vertex => sdk.msg(void, self.render_cmd_encoder, "setVertexTexture:atIndex:", .{ texture, index }),
        .fragment => sdk.msg(void, self.render_cmd_encoder, "setFragmentTexture:atIndex:", .{ texture, index }),
        .compute => sdk.msg(void, self.compute_cmd_encoder, "setTexture:atIndex:", .{ texture, index }),
    }
}

fn setStageSampler(self: *Backend, comptime stage: Stage, sampler: sdk.Id, index: sdk.Uint) void {
    switch (stage) {
        .vertex => sdk.msg(void, self.render_cmd_encoder, "setVertexSamplerState:atIndex:", .{ sampler, index }),
        .fragment => sdk.msg(void, self.render_cmd_encoder, "setFragmentSamplerState:atIndex:", .{ sampler, index }),
        .compute => sdk.msg(void, self.compute_cmd_encoder, "setSamplerState:atIndex:", .{ sampler, index }),
    }
}

/// Binds a buffer to a stage slot, or only moves its offset when that is the only change.
fn bindStageBuffer(self: *Backend, comptime stage: Stage, cache_item: *backend_mod.CacheBuf, buf: *core.Buffer, offset: i32, mtl_slot: usize) void {
    const active_slot = buf.cmn.active_slot;
    const cmp = cacheBufCmp(cache_item, &buf.slot, active_slot, offset);
    if (cmp == backend_mod.cache_cmp_equal) {
        core.statsInc("metal.bindings.num_skip_redundant_" ++ @tagName(stage) ++ "_buffer");
        return;
    }
    cacheBufUpd(cache_item, &buf.slot, active_slot, offset);
    if ((cmp & ~backend_mod.cache_cmp_offset) == 0) {
        // only the offset has changed
        setStageBufferOffset(self, stage, uint(offset), uint(mtl_slot));
        core.statsInc("metal.bindings.num_set_" ++ @tagName(stage) ++ "_buffer_offset");
    } else {
        const mtl_buf = self.idpool.id(buf.native.metal.buf[@intCast(active_slot)]);
        setStageBuffer(self, stage, mtl_buf, uint(offset), uint(mtl_slot));
        core.statsInc("metal.bindings.num_set_" ++ @tagName(stage) ++ "_buffer");
    }
}

/// Binds a texture view to a stage slot, skipped when already bound.
fn bindStageTexture(self: *Backend, comptime stage: Stage, cache_item: *backend_mod.CacheTex, view: *core.View, active_slot: i32, mtl_slot: usize) void {
    const cmp = cacheTexCmp(cache_item, &view.slot, active_slot);
    if (cmp == backend_mod.cache_cmp_equal) {
        core.statsInc("metal.bindings.num_skip_redundant_" ++ @tagName(stage) ++ "_texture");
        return;
    }
    cacheTexUpd(cache_item, &view.slot, active_slot);
    const tex_view = self.idpool.id(view.native.metal.tex_view[@intCast(active_slot)]);
    setStageTexture(self, stage, tex_view, uint(mtl_slot));
    core.statsInc("metal.bindings.num_set_" ++ @tagName(stage) ++ "_texture");
}

/// Binds a sampler to a stage slot, skipped when already bound.
fn bindStageSampler(self: *Backend, comptime stage: Stage, cache_slot: *core.SlotRef, smp: *core.Sampler, mtl_slot: usize) void {
    if (cache_slot.eqlSlot(&smp.slot)) {
        core.statsInc("metal.bindings.num_skip_redundant_" ++ @tagName(stage) ++ "_sampler_state");
        return;
    }
    cache_slot.* = core.SlotRef.of(&smp.slot);
    setStageSampler(self, stage, self.idpool.id(smp.native.metal.sampler_state), uint(mtl_slot));
    core.statsInc("metal.bindings.num_set_" ++ @tagName(stage) ++ "_sampler_state");
}

/// Applies the vertex, index, view and sampler bindings (_sg_mtl_apply_bindings).
pub fn applyBindings(self: *Backend, bnd: *const core.BindingsPtrs) bool {
    const shd = bnd.pip.cmn.shader.get();
    const shd_res = &shd.native.metal;
    const s = core.state();

    // don't set vertex- and index-buffers in compute passes
    if (!s.cur_pass.is_compute) {
        std.debug.assert(self.render_cmd_encoder != null);
        // store the index buffer binding, it is needed by draw
        self.cache.cur_ibuf = core.Ref(core.Buffer).init(bnd.ib);
        self.cache.cur_ibuf_offset = bnd.ib_offset;
        if (bnd.ib) |ib| {
            std.debug.assert(bnd.pip.cmn.index_type != .none);
            if (ib.cmn.usage.write_transient) commitBufferWriteRange(self, ib);
        } else {
            std.debug.assert(bnd.pip.cmn.index_type == .none);
        }
        // vertex buffers
        for (bnd.vbs, 0..) |optional_vb, i| {
            const vb = optional_vb orelse continue;
            if (vb.cmn.usage.write_transient) commitBufferWriteRange(self, vb);
            const mtl_slot = backend_mod.vertexBufferBindslot(i);
            std.debug.assert(mtl_slot < r.max_stage_buffer_bindings);
            bindStageBuffer(self, .vertex, &self.cache.cur_vsbufs[i], vb, bnd.vb_offsets[i], mtl_slot);
        }
    }

    // views: textures, storage images and storage buffers
    for (bnd.views, 0..) |optional_view, i| {
        const view = optional_view orelse continue;
        const shd_view = &shd.cmn.views[i];
        const mtl_slot = shd_res.view_buffer_texture_n[i];
        switch (shd_view.view_type) {
            .texture, .storageimage => {
                std.debug.assert(mtl_slot < r.max_stage_texture_bindings);
                const active_slot = view.cmn.img.ref.get().cmn.active_slot;
                std.debug.assert(view.native.metal.tex_view[@intCast(active_slot)] != 0);
                switch (shd_view.stage) {
                    .vertex => bindStageTexture(self, .vertex, &self.cache.cur_vstexs[mtl_slot], view, active_slot, mtl_slot),
                    .fragment => bindStageTexture(self, .fragment, &self.cache.cur_fstexs[mtl_slot], view, active_slot, mtl_slot),
                    .compute => bindStageTexture(self, .compute, &self.cache.cur_cstexs[mtl_slot], view, active_slot, mtl_slot),
                    else => unreachable,
                }
            },
            .storagebuffer => {
                std.debug.assert(mtl_slot < r.max_stage_ub_sbuf_bindings);
                const sbuf = view.cmn.buf.ref.get();
                if (sbuf.cmn.usage.write_transient) commitBufferWriteRange(self, sbuf);
                const offset = view.cmn.buf.offset;
                switch (shd_view.stage) {
                    .vertex => bindStageBuffer(self, .vertex, &self.cache.cur_vsbufs[mtl_slot], sbuf, offset, mtl_slot),
                    .fragment => bindStageBuffer(self, .fragment, &self.cache.cur_fsbufs[mtl_slot], sbuf, offset, mtl_slot),
                    .compute => bindStageBuffer(self, .compute, &self.cache.cur_csbufs[mtl_slot], sbuf, offset, mtl_slot),
                    else => unreachable,
                }
            },
            else => unreachable,
        }
    }

    // samplers
    for (bnd.smps, 0..) |optional_smp, i| {
        const smp = optional_smp orelse continue;
        std.debug.assert(smp.native.metal.sampler_state != 0);
        const mtl_slot = shd_res.smp_sampler_n[i];
        std.debug.assert(mtl_slot < r.max_stage_sampler_bindings);
        switch (shd.cmn.samplers[i].stage) {
            .vertex => bindStageSampler(self, .vertex, &self.cache.cur_vssmps[mtl_slot], smp, mtl_slot),
            .fragment => bindStageSampler(self, .fragment, &self.cache.cur_fssmps[mtl_slot], smp, mtl_slot),
            .compute => bindStageSampler(self, .compute, &self.cache.cur_cssmps[mtl_slot], smp, mtl_slot),
            else => unreachable,
        }
    }
    return true;
}

// ---------------------------------------------------------------- uniforms

/// Alignment of uniform data in the uniform buffer, see _SG_MTL_UB_ALIGN.
fn uniformAlign(self: *const Backend) i32 {
    return self.uniformAlignment();
}

/// Copies uniform data into the frame's uniform buffer and sets its offset (_sg_mtl_apply_uniforms).
pub fn applyUniforms(self: *Backend, ub_slot: usize, data: *const t.Range) void {
    std.debug.assert(ub_slot < constants.max_uniformblock_bindslots);
    const align_bytes = uniformAlign(self);
    std.debug.assert(@as(usize, @intCast(self.cur_ub_offset)) + data.size <= @as(usize, @intCast(self.ub_size)));
    std.debug.assert(@mod(self.cur_ub_offset, align_bytes) == 0);
    const pip = core.state().cur_pip.get();
    const shd = pip.cmn.shader.get();
    std.debug.assert(data.size == shd.cmn.uniform_blocks[ub_slot].size);

    const stage = shd.cmn.uniform_blocks[ub_slot].stage;
    const mtl_slot = shd.native.metal.ub_buffer_n[ub_slot];

    // copy to the frame's uniform buffer, record the offset into the encoder, advance
    const base: [*]u8 = self.cur_ub_base_ptr orelse unreachable;
    const dst = base + @as(usize, @intCast(self.cur_ub_offset));
    const src: [*]const u8 = @ptrCast(data.ptr orelse unreachable);
    @memcpy(dst[0..data.size], src[0..data.size]);

    switch (stage) {
        .vertex => {
            sdk.msg(void, self.render_cmd_encoder, "setVertexBufferOffset:atIndex:", .{ uint(self.cur_ub_offset), uint(mtl_slot) });
            core.statsInc("metal.uniforms.num_set_vertex_buffer_offset");
        },
        .fragment => {
            sdk.msg(void, self.render_cmd_encoder, "setFragmentBufferOffset:atIndex:", .{ uint(self.cur_ub_offset), uint(mtl_slot) });
            core.statsInc("metal.uniforms.num_set_fragment_buffer_offset");
        },
        .compute => {
            sdk.msg(void, self.compute_cmd_encoder, "setBufferOffset:atIndex:", .{ uint(self.cur_ub_offset), uint(mtl_slot) });
            core.statsInc("metal.uniforms.num_set_compute_buffer_offset");
        },
        else => unreachable,
    }
    const next = self.cur_ub_offset + @as(i32, @intCast(data.size));
    self.cur_ub_offset = (next + align_bytes - 1) & ~(align_bytes - 1);
}

// ---------------------------------------------------------------- draws and dispatch

fn drawBase0(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32) void {
    std.debug.assert(self.render_cmd_encoder != null);
    const pip = core.state().cur_pip.get();
    const res = &pip.native.metal;
    if (core.state().use_indexed_draw) {
        // indexed rendering
        const ib = self.cache.cur_ibuf.get();
        const active_slot: usize = @intCast(ib.cmn.active_slot);
        std.debug.assert(ib.native.metal.buf[active_slot] != 0);
        const index_buffer_offset = self.cache.cur_ibuf_offset + base_element * res.index_size;
        sdk.msg(void, self.render_cmd_encoder, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:", .{
            res.prim_type,
            uint(num_elements),
            res.index_type,
            self.idpool.id(ib.native.metal.buf[active_slot]),
            uint(index_buffer_offset),
            uint(num_instances),
        });
    } else {
        // non-indexed rendering
        sdk.msg(void, self.render_cmd_encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{
            res.prim_type,
            uint(base_element),
            uint(num_elements),
            uint(num_instances),
        });
    }
}

fn drawEx(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
    std.debug.assert(self.render_cmd_encoder != null);
    std.debug.assert(core.state().features.draw_base_instance);
    const pip = core.state().cur_pip.get();
    const res = &pip.native.metal;
    if (core.state().use_indexed_draw) {
        // indexed rendering
        std.debug.assert(core.state().features.draw_base_vertex);
        const ib = self.cache.cur_ibuf.get();
        const active_slot: usize = @intCast(ib.cmn.active_slot);
        std.debug.assert(ib.native.metal.buf[active_slot] != 0);
        const index_buffer_offset = self.cache.cur_ibuf_offset + base_element * res.index_size;
        sdk.msg(void, self.render_cmd_encoder, "drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:", .{
            res.prim_type,
            uint(num_elements),
            res.index_type,
            self.idpool.id(ib.native.metal.buf[active_slot]),
            uint(index_buffer_offset),
            uint(num_instances),
            @as(isize, base_vertex),
            uint(base_instance),
        });
    } else {
        // non-indexed rendering
        sdk.msg(void, self.render_cmd_encoder, "drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:", .{
            res.prim_type,
            uint(base_element),
            uint(num_elements),
            uint(num_instances),
            uint(base_instance),
        });
    }
}

/// Draws the primitives of the current pipeline (_sg_mtl_draw). The base vertex and base
/// instance variants are only used when needed, the others fail on some older GPUs.
pub fn draw(self: *Backend, base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
    if (base_vertex == 0 and base_instance == 0) {
        drawBase0(self, base_element, num_elements, num_instances);
    } else {
        drawEx(self, base_element, num_elements, num_instances, base_vertex, base_instance);
    }
}

pub fn dispatch(self: *Backend, num_groups_x: i32, num_groups_y: i32, num_groups_z: i32) void {
    std.debug.assert(self.compute_cmd_encoder != null);
    const pip = core.state().cur_pip.get();
    const thread_groups: sdk.Size = .{ .width = uint(num_groups_x), .height = uint(num_groups_y), .depth = uint(num_groups_z) };
    sdk.msg(void, self.compute_cmd_encoder, "dispatchThreadgroups:threadsPerThreadgroup:", .{ thread_groups, pip.native.metal.threads_per_threadgroup });
}

// ---------------------------------------------------------------- transfers

/// Makes the modified range of a managed buffer visible to the GPU (_sg_mtl_commit_buffer_write_range).
fn commitBufferWriteRange(self: *Backend, buf: *core.Buffer) void {
    // only macOS has managed storage
    if (!self.macos) return;
    const res = &buf.native.metal;
    if (res.write_range_end > res.write_range_start) {
        const mtl_buf = self.idpool.id(res.buf[@intCast(buf.cmn.active_slot)]);
        if (!self.use_shared_storage_mode) {
            sdk.msg(void, mtl_buf, "didModifyRange:", .{sdk.NSRange{
                .location = res.write_range_start,
                .length = res.write_range_end - res.write_range_start,
            }});
        }
        // the range is also reset on the first write of a frame, a written buffer may not be used in a frame
        resetBufferWriteRange(buf);
    }
}

fn resetBufferWriteRange(buf: *core.Buffer) void {
    buf.native.metal.write_range_start = buf.cmn.size;
    buf.native.metal.write_range_end = 0;
}

pub fn sealBuffer(self: *Backend, buf: *core.Buffer) void {
    commitBufferWriteRange(self, buf);
}

pub fn sealImage(self: *Backend, img: *core.Image) void {
    _ = self;
    _ = img;
}

/// Copies bytes into a buffer slot, and records the range for the GPU (_sg_mtl_write_buffer_common).
fn writeBufferCommon(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
    std.debug.assert(desc.src.data.ptr != null and desc.src.data.size > 0);
    std.debug.assert(desc.dst.offset + desc.size <= buf.cmn.size);
    std.debug.assert(desc.src.offset + desc.size <= desc.src.data.size);
    std.debug.assert(buf.cmn.active_slot < buf.cmn.num_slots);

    // copy the data
    const mtl_buf = self.idpool.id(buf.native.metal.buf[@intCast(buf.cmn.active_slot)]);
    const contents: [*]u8 = @ptrCast(sdk.msg(?*anyopaque, mtl_buf, "contents", .{}) orelse unreachable);
    const dst = contents + desc.dst.offset;
    const src_base: [*]const u8 = @ptrCast(desc.src.data.ptr orelse unreachable);
    @memcpy(dst[0..desc.size], (src_base + desc.src.offset)[0..desc.size]);

    // update the dirty range
    const cur_range_start = desc.dst.offset;
    const cur_range_end = desc.dst.offset + desc.size;
    if (cur_range_start < buf.native.metal.write_range_start) buf.native.metal.write_range_start = cur_range_start;
    if (cur_range_end > buf.native.metal.write_range_end) buf.native.metal.write_range_end = cur_range_end;
}

pub fn writeBufferTransient(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc, first_time_in_frame: bool) void {
    std.debug.assert(buf.slot.state == .valid);
    std.debug.assert(buf.cmn.usage.write_transient);
    // reset the write range on the first write in a frame, the range is set in the bindings
    if (first_time_in_frame) resetBufferWriteRange(buf);
    writeBufferCommon(self, buf, desc);
}

pub fn writeBufferUnsealed(self: *Backend, buf: *core.Buffer, desc: *const t.WriteBufferDesc) void {
    std.debug.assert(buf.slot.state == .unsealed);
    std.debug.assert(buf.cmn.usage.write_unsealed);
    std.debug.assert(buf.cmn.active_slot == 0);
    writeBufferCommon(self, buf, desc);
}

fn writeImageCommon(img: *core.Image, mtl_tex: sdk.Id, desc: *const t.WriteImageDesc) void {
    Backend.writeMiplevelData(
        img,
        mtl_tex,
        @ptrCast(desc.src.data.ptr orelse unreachable),
        desc.src.data.size,
        desc.src.offset,
        desc.src.bytes_per_row,
        desc.src.bytes_per_slice,
        desc.dst.mip_level,
        desc.dst.x,
        desc.dst.y,
        desc.dst.slice,
        desc.size.width,
        desc.size.height,
        desc.size.num_slices,
    );
}

pub fn writeImageTransient(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc, first_time_in_frame: bool) void {
    _ = first_time_in_frame;
    std.debug.assert(img.slot.state == .valid);
    std.debug.assert(img.cmn.usage.write_transient);
    const mtl_tex = self.idpool.id(img.native.metal.tex[@intCast(img.cmn.active_slot)]);
    writeImageCommon(img, mtl_tex, desc);
}

pub fn writeImageUnsealed(self: *Backend, img: *core.Image, desc: *const t.WriteImageDesc) void {
    std.debug.assert(img.slot.state == .unsealed);
    std.debug.assert(img.cmn.usage.write_unsealed);
    std.debug.assert(img.cmn.active_slot == 0);
    const mtl_tex = self.idpool.id(img.native.metal.tex[@intCast(img.cmn.active_slot)]);
    writeImageCommon(img, mtl_tex, desc);
}

pub fn copyBufferToBuffer(self: *Backend, src: *core.Buffer, dst: *core.Buffer, desc: *const t.CopyBufferToBufferDesc) void {
    std.debug.assert(src.cmn.usage.copy_src);
    std.debug.assert(dst.cmn.usage.copy_dst);
    acquireCmdBuffer(self);
    acquireBlitCmdEncoder(self);
    commitBufferWriteRange(self, src);
    const mtl_src = self.idpool.id(src.native.metal.buf[@intCast(src.cmn.active_slot)]);
    const mtl_dst = self.idpool.id(dst.native.metal.buf[@intCast(dst.cmn.active_slot)]);
    sdk.msg(void, self.blit_cmd_encoder, "copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:", .{
        mtl_src,
        desc.src.offset,
        mtl_dst,
        desc.dst.offset,
        desc.size,
    });
}

pub fn copyBufferToImage(self: *Backend, src: *core.Buffer, dst: *core.Image, desc: *const t.CopyBufferToImageDesc) void {
    std.debug.assert(src.cmn.usage.copy_src);
    std.debug.assert(dst.cmn.usage.copy_dst);
    std.debug.assert(!src.cmn.usage.staging_index_buffer);
    acquireCmdBuffer(self);
    acquireBlitCmdEncoder(self);
    commitBufferWriteRange(self, src);

    const mtl_src = self.idpool.id(src.native.metal.buf[@intCast(src.cmn.active_slot)]);
    const mtl_dst = self.idpool.id(dst.native.metal.tex[@intCast(dst.cmn.active_slot)]);

    const is_3d = dst.cmn.type == .@"3d";
    const size: sdk.Size = .{
        .width = uint(desc.size.width),
        .height = uint(desc.size.height),
        .depth = if (is_3d) uint(desc.size.num_slices) else 1,
    };
    const origin: sdk.Origin = .{
        .x = uint(desc.dst.x),
        .y = uint(desc.dst.y),
        .z = if (is_3d) uint(desc.dst.slice) else 0,
    };
    // bytesPerImage is only used for 3D textures
    const bytes_per_image: i32 = if (is_3d) desc.src.bytes_per_slice else 0;
    const mtl_slice_index: i32 = if (is_3d) 0 else desc.dst.slice;
    const mtl_num_slices: i32 = if (is_3d) 1 else desc.size.num_slices;
    var i: i32 = 0;
    while (i < mtl_num_slices) : (i += 1) {
        const offset = desc.src.offset + @as(usize, @intCast(i)) * @as(usize, @intCast(desc.src.bytes_per_slice));
        sdk.msg(void, self.blit_cmd_encoder, "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:", .{
            mtl_src,
            offset,
            uint(desc.src.bytes_per_row),
            uint(bytes_per_image),
            size,
            mtl_dst,
            uint(mtl_slice_index + i),
            uint(desc.dst.mip_level),
            origin,
        });
    }
}

// ---------------------------------------------------------------- debug groups

pub fn pushDebugGroup(self: *Backend, name: [*:0]const u8) void {
    if (self.render_cmd_encoder != null) {
        sdk.msg(void, self.render_cmd_encoder, "pushDebugGroup:", .{sdk.nsString(name)});
    } else if (self.compute_cmd_encoder != null) {
        sdk.msg(void, self.compute_cmd_encoder, "pushDebugGroup:", .{sdk.nsString(name)});
    }
}

pub fn popDebugGroup(self: *Backend) void {
    if (self.render_cmd_encoder != null) {
        sdk.msg(void, self.render_cmd_encoder, "popDebugGroup", .{});
    } else if (self.compute_cmd_encoder != null) {
        sdk.msg(void, self.compute_cmd_encoder, "popDebugGroup", .{});
    }
}
