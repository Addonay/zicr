//! Native resource lifecycle and public API. Source: sokol_gfx.h:26939-29555.
//! Unsupported GPU selections return an error rather than falling back to dummy rendering.
const std = @import("std");
const t = @import("types.zig");
const e = @import("enums.zig");
const defaults = @import("defaults.zig");
const formats = @import("formats.zig");
const Pool = @import("pool.zig").Pool;
const validation = @import("validation.zig");
const runtime_validation = @import("runtime_validation.zig");
const D3dBackend = @import("backends/d3d11/backend.zig").Backend;
const d3d_resources = @import("backends/d3d11/resources.zig");
const GlBackend = @import("backends/gl/backend.zig").Backend;
const gl_resources = @import("backends/gl/resources.zig");

const State = struct {
    allocator: std.mem.Allocator,
    desc: t.Desc,
    backend: e.Backend,
    gl_backend: ?GlBackend = null,
    d3d11_backend: ?D3dBackend = null,
    pass_width: i32 = 0,
    pass_height: i32 = 0,
    buffers: Pool(t.BufferDesc),
    images: Pool(t.ImageDesc),
    samplers: Pool(t.SamplerDesc),
    shaders: Pool(t.ShaderDesc),
    pipelines: Pool(t.PipelineDesc),
    views: Pool(t.ViewDesc),
    listeners: []t.CommitListener,
    listener_upper: usize = 0,
    hooks: t.TraceHooks = .{},
    stats: t.Stats = .{},
    stats_enabled: bool = true,
    frame_index: u32 = 1,
    pass_index: u32 = 0,
    write_buffer_transient_missing: bool = false,
    write_image_transient_missing: bool = false,
    current_pass: ?t.Pass = null,
    pass_valid: bool = false,
    current_pipeline: t.Pipeline = .{},
    pipeline_uninit_count: u32 = 0,
    next_draw_valid: bool = false,
    required: u16 = 0,
    applied: u16 = 0,
};
var storage: ?State = null;

fn state() *State {
    return if (storage) |*value| value else @panic("sokol_gfx is not initialized");
}

pub fn setup(allocator: std.mem.Allocator, backend: e.Backend, descriptor: t.Desc) !void {
    std.debug.assert(storage == null);
    if (backend != .dummy and backend != .glcore and backend != .gles3 and backend != .d3d11) return error.BackendNotPorted;
    if ((backend == .glcore or backend == .gles3) and descriptor.environment.gl.get_proc_address == null) return error.MissingGlProcAddress;
    if ((descriptor.allocator.alloc_fn != null) or (descriptor.allocator.free_fn != null)) return error.UseZigAllocator;
    std.debug.assert(descriptor._start_canary == 0 and descriptor._end_canary == 0);
    const desc = defaults.desc(descriptor, backend);
    if (desc.buffer_pool_size <= 0 or desc.buffer_pool_size >= 65536) return error.InvalidPoolSize;
    if (desc.image_pool_size <= 0 or desc.image_pool_size >= 65536) return error.InvalidPoolSize;
    if (desc.sampler_pool_size <= 0 or desc.sampler_pool_size >= 65536) return error.InvalidPoolSize;
    if (desc.shader_pool_size <= 0 or desc.shader_pool_size >= 65536) return error.InvalidPoolSize;
    if (desc.pipeline_pool_size <= 0 or desc.pipeline_pool_size >= 65536) return error.InvalidPoolSize;
    if (desc.view_pool_size <= 0 or desc.view_pool_size >= 65536) return error.InvalidPoolSize;
    if (desc.max_commit_listeners <= 0) return error.InvalidListenerCapacity;
    var buffers = try Pool(t.BufferDesc).init(allocator, @intCast(desc.buffer_pool_size));
    errdefer buffers.deinit(allocator);
    var images = try Pool(t.ImageDesc).init(allocator, @intCast(desc.image_pool_size));
    errdefer images.deinit(allocator);
    var samplers = try Pool(t.SamplerDesc).init(allocator, @intCast(desc.sampler_pool_size));
    errdefer samplers.deinit(allocator);
    var shaders = try Pool(t.ShaderDesc).init(allocator, @intCast(desc.shader_pool_size));
    errdefer shaders.deinit(allocator);
    var pipelines = try Pool(t.PipelineDesc).init(allocator, @intCast(desc.pipeline_pool_size));
    errdefer pipelines.deinit(allocator);
    var views = try Pool(t.ViewDesc).init(allocator, @intCast(desc.view_pool_size));
    errdefer views.deinit(allocator);
    const listeners = try allocator.alloc(t.CommitListener, @intCast(desc.max_commit_listeners));
    @memset(listeners, .{});
    errdefer allocator.free(listeners);
    var gl_backend: ?GlBackend = null;
    if (backend == .glcore or backend == .gles3) {
        gl_backend = try GlBackend.init(allocator, backend, desc.environment.gl.get_proc_address.?, desc.environment.gl.user_data, desc.logger);
        if (desc.enforce_portable_limits) {
            const limits = &gl_backend.?.cache.limits;
            limits.max_color_attachments = 4;
            limits.max_texture_bindings_per_stage = 16;
            if (gl_backend.?.cache.features.compute) {
                limits.max_storage_buffer_bindings_per_stage = 8;
                limits.max_storage_image_bindings_per_stage = 4;
            }
        }
    }
    const d3d11_backend = if (backend == .d3d11) try D3dBackend.init(allocator, desc, null) else null;
    storage = .{
        .allocator = allocator,
        .desc = desc,
        .backend = backend,
        .gl_backend = gl_backend,
        .d3d11_backend = d3d11_backend,
        .buffers = buffers,
        .images = images,
        .samplers = samplers,
        .shaders = shaders,
        .pipelines = pipelines,
        .views = views,
        .listeners = listeners,
    };
}

pub fn shutdown() void {
    const s = state();
    inline for (.{ "views", "pipelines", "shaders", "samplers", "images", "buffers" }) |name| {
        for (@field(s, name).entries[1..]) |entry| _ = uninitialize(name, entry.slot.res_id);
    }
    if (s.gl_backend) |*gl| gl.deinit();
    if (s.d3d11_backend) |*dx| dx.deinit();
    s.views.deinit(s.allocator);
    s.pipelines.deinit(s.allocator);
    s.shaders.deinit(s.allocator);
    s.samplers.deinit(s.allocator);
    s.images.deinit(s.allocator);
    s.buffers.deinit(s.allocator);
    s.allocator.free(s.listeners);
    storage = null;
}

pub fn isValid() bool {
    return storage != null;
}
pub fn queryDesc() t.Desc {
    return state().desc;
}
pub fn queryBackend() e.Backend {
    return state().backend;
}
pub fn queryFeatures() t.Features {
    if (state().gl_backend) |gl| return gl.cache.features;
    if (state().d3d11_backend) |dx| return dx.features;
    return .{};
}
pub fn queryLimits() t.Limits {
    if (state().gl_backend) |gl| return gl.cache.limits;
    if (state().d3d11_backend) |dx| return dx.limits;
    return .{
        .max_image_size_2d = 1024,
        .max_image_size_cube = 1024,
        .max_image_size_3d = 1024,
        .max_image_size_array = 1024,
        .max_image_array_layers = 1024,
        .max_vertex_attrs = 16,
        .max_color_attachments = 4,
        .max_texture_bindings_per_stage = 16,
        .max_storage_buffer_bindings_per_stage = 8,
        .max_storage_image_bindings_per_stage = 4,
    };
}
pub fn queryPixelformat(format: e.PixelFormat) t.PixelformatInfo {
    _ = state();
    std.debug.assert(@backingInt(format) > 1 and @backingInt(format) < 69);
    if (state().gl_backend) |*gl| {
        var info = gl.format_info[@backingInt(format)];
        info.compressed = formats.isCompressed(format);
        info.bytes_per_pixel = if (info.compressed) 0 else formats.pixelSize(format);
        return info;
    }
    if (state().d3d11_backend) |*dx| {
        var info = dx.format_info[@backingInt(format)];
        info.compressed = formats.isCompressed(format);
        info.bytes_per_pixel = if (info.compressed) 0 else formats.pixelSize(format);
        return info;
    }
    const enabled = @backingInt(format) < @backingInt(e.PixelFormat.bc1_rgba);
    const compressed = formats.isCompressed(format);
    return .{
        .sample = enabled,
        .filter = enabled,
        .render = enabled,
        .blend = enabled,
        .msaa = enabled,
        .depth = format == .depth or format == .depth_stencil,
        .compressed = compressed,
        .bytes_per_pixel = if (compressed) 0 else formats.pixelSize(format),
    };
}
pub fn queryRowPitch(format: e.PixelFormat, width: i32, alignment: i32) i32 {
    _ = state();
    std.debug.assert(width > 0 and @backingInt(format) > 1 and @backingInt(format) < 69);
    return formats.rowPitch(format, width, alignment);
}
pub fn querySurfacePitch(format: e.PixelFormat, width: i32, height: i32, alignment: i32) i32 {
    _ = state();
    std.debug.assert(width > 0 and height > 0 and @backingInt(format) > 1 and @backingInt(format) < 69);
    return formats.surfacePitch(format, width, height, alignment);
}
pub fn queryPassState() e.PassState {
    const pass = state().current_pass orelse return .none;
    return if (pass.compute) .compute else .render;
}
pub fn installTraceHooks(hooks: t.TraceHooks) t.TraceHooks {
    const s = state();
    const previous = s.hooks;
    s.hooks = hooks;
    return previous;
}
fn trace(comptime name: []const u8, arguments: anytype) void {
    const s = state();
    if (@field(s.hooks, name)) |callback| @call(.auto, callback, arguments ++ .{s.hooks.user_data});
}
fn log(item: e.LogItem) void {
    const s = state();
    if (s.desc.logger.func) |callback| callback("sg", 1, @backingInt(item), null, 0, null, s.desc.logger.user_data);
}
fn count(comptime name: []const u8, value: u32) void {
    const s = state();
    if (s.stats_enabled) @field(s.stats.cur_frame, name) +%= value;
}
fn resourceCount(comptime name: []const u8, comptime operation: []const u8) void {
    const s = state();
    if (s.stats_enabled) {
        @field(@field(s.stats.cur_frame, name), operation) +%= 1;
        @field(@field(s.stats.total, name), operation) +%= 1;
    }
}

pub fn allocBuffer() t.Buffer {
    const id = state().buffers.alloc();
    if (id != 0) resourceCount("buffers", "allocated") else log(.buffer_pool_exhausted);
    const result: t.Buffer = .{ .id = id };
    trace("alloc_buffer", .{result});
    return result;
}
pub fn deallocBuffer(handle: t.Buffer) void {
    if (state().buffers.lookup(handle.id) != null) {
        if (state().buffers.dealloc(handle.id)) resourceCount("buffers", "deallocated") else log(.dealloc_buffer_invalid_state);
    }
    trace("dealloc_buffer", .{handle});
}
pub fn queryBufferDefaults(descriptor: t.BufferDesc) t.BufferDesc {
    _ = state();
    return defaults.buffer(descriptor);
}
fn initializeBuffer(handle: t.Buffer, descriptor: t.BufferDesc) void {
    const s = state();
    const entry = s.buffers.lookup(handle.id) orelse return;
    if (entry.slot.state != .alloc) {
        log(.init_buffer_invalid_state);
        return;
    }
    const valid = validateBuffer(handle, descriptor);
    entry.slot.state = if (valid) .valid else .failed;
    entry.descriptor = if (valid) descriptor else .{};
    if (valid) {
        entry.num_slots = if (descriptor.usage.write_transient) 2 else 1;
    }
    if (valid) if (s.gl_backend) |*gl| {
        if (!gl.createBuffer(&entry.gl_resource, descriptor)) entry.slot.state = .failed;
    };
    if (valid) if (s.d3d11_backend) |*dx| {
        if (!dx.createBuffer(&entry.d3d11_resource, descriptor)) entry.slot.state = .failed;
    };
    if (entry.slot.state == .valid and descriptor.usage.write_unsealed) entry.slot.state = .unsealed;
    resourceCount("buffers", "inited");
}
pub fn initBuffer(handle: t.Buffer, descriptor: t.BufferDesc) void {
    const resolved = queryBufferDefaults(descriptor);
    initializeBuffer(handle, resolved);
    trace("init_buffer", .{ handle, &resolved });
}
pub fn makeBuffer(descriptor: t.BufferDesc) t.Buffer {
    const resolved = queryBufferDefaults(descriptor);
    const id = state().buffers.alloc();
    const result: t.Buffer = .{ .id = id };
    if (id != 0) {
        resourceCount("buffers", "allocated");
        initializeBuffer(result, resolved);
    } else log(.buffer_pool_exhausted);
    trace("make_buffer", .{ &resolved, result });
    return result;
}
pub fn uninitBuffer(handle: t.Buffer) void {
    if (state().buffers.lookup(handle.id)) |entry| {
        if (uninitialize("buffers", handle.id)) resourceCount("buffers", "uninited") else if (entry.slot.state != .alloc) log(.uninit_buffer_invalid_state);
    }
    trace("uninit_buffer", .{handle});
}
pub fn destroyBuffer(handle: t.Buffer) void {
    trace("destroy_buffer", .{handle});
    if (state().buffers.lookup(handle.id) != null) {
        if (uninitialize("buffers", handle.id)) resourceCount("buffers", "uninited");
        if (state().buffers.dealloc(handle.id)) resourceCount("buffers", "deallocated");
    }
}
pub fn failBuffer(handle: t.Buffer) void {
    if (state().buffers.lookup(handle.id)) |entry| {
        if (entry.slot.state == .alloc) entry.slot.state = .failed else log(.fail_buffer_invalid_state);
    }
    trace("fail_buffer", .{handle});
}
pub fn queryBufferState(handle: t.Buffer) e.ResourceState {
    return if (state().buffers.lookup(handle.id)) |entry| entry.slot.state else .invalid;
}
pub fn queryBufferInfo(handle: t.Buffer) t.BufferInfo {
    const entry = state().buffers.lookup(handle.id) orelse return .{};
    return .{ .slot = entry.slot, .num_slots = if (state().d3d11_backend != null) 1 else entry.num_slots, .active_slot = if (state().d3d11_backend != null) 0 else entry.active_slot };
}

pub fn allocImage() t.Image {
    const id = state().images.alloc();
    if (id != 0) resourceCount("images", "allocated") else log(.image_pool_exhausted);
    const result: t.Image = .{ .id = id };
    trace("alloc_image", .{result});
    return result;
}
pub fn deallocImage(handle: t.Image) void {
    if (state().images.lookup(handle.id) != null) {
        if (state().images.dealloc(handle.id)) resourceCount("images", "deallocated") else log(.dealloc_image_invalid_state);
    }
    trace("dealloc_image", .{handle});
}
pub fn queryImageDefaults(descriptor: t.ImageDesc) t.ImageDesc {
    _ = state();
    return defaults.image(descriptor, state().desc.environment.defaults);
}
fn initializeImage(handle: t.Image, descriptor: t.ImageDesc) void {
    const s = state();
    const entry = s.images.lookup(handle.id) orelse return;
    if (entry.slot.state != .alloc) {
        log(.init_image_invalid_state);
        return;
    }
    const valid = validateImage(handle, descriptor);
    entry.slot.state = if (valid) .valid else .failed;
    entry.descriptor = if (valid) descriptor else .{};
    if (valid) {
        entry.num_slots = if (descriptor.usage.write_transient) 2 else 1;
    }
    if (valid) if (s.gl_backend) |*gl| {
        if (!gl.createImage(&entry.gl_resource, descriptor)) entry.slot.state = .failed;
    };
    if (valid) if (s.d3d11_backend) |*dx| {
        if (!dx.createImage(&entry.d3d11_resource, descriptor)) entry.slot.state = .failed;
    };
    if (entry.slot.state == .valid and descriptor.usage.write_unsealed) entry.slot.state = .unsealed;
    resourceCount("images", "inited");
}
pub fn initImage(handle: t.Image, descriptor: t.ImageDesc) void {
    const resolved = queryImageDefaults(descriptor);
    initializeImage(handle, resolved);
    trace("init_image", .{ handle, &resolved });
}
pub fn makeImage(descriptor: t.ImageDesc) t.Image {
    const resolved = queryImageDefaults(descriptor);
    const id = state().images.alloc();
    const result: t.Image = .{ .id = id };
    if (id != 0) {
        resourceCount("images", "allocated");
        initializeImage(result, resolved);
    } else log(.image_pool_exhausted);
    trace("make_image", .{ &resolved, result });
    return result;
}
pub fn uninitImage(handle: t.Image) void {
    if (state().images.lookup(handle.id)) |entry| {
        if (uninitialize("images", handle.id)) resourceCount("images", "uninited") else if (entry.slot.state != .alloc) log(.uninit_image_invalid_state);
    }
    trace("uninit_image", .{handle});
}
pub fn destroyImage(handle: t.Image) void {
    trace("destroy_image", .{handle});
    if (state().images.lookup(handle.id) != null) {
        if (uninitialize("images", handle.id)) resourceCount("images", "uninited");
        if (state().images.dealloc(handle.id)) resourceCount("images", "deallocated");
    }
}
pub fn failImage(handle: t.Image) void {
    if (state().images.lookup(handle.id)) |entry| {
        if (entry.slot.state == .alloc) entry.slot.state = .failed else log(.fail_image_invalid_state);
    }
    trace("fail_image", .{handle});
}
pub fn queryImageState(handle: t.Image) e.ResourceState {
    return if (state().images.lookup(handle.id)) |entry| entry.slot.state else .invalid;
}
pub fn queryImageInfo(handle: t.Image) t.ImageInfo {
    const entry = state().images.lookup(handle.id) orelse return .{};
    return .{ .slot = entry.slot, .num_slots = if (state().d3d11_backend != null) 1 else entry.num_slots, .active_slot = if (state().d3d11_backend != null) 0 else entry.active_slot };
}

pub fn allocSampler() t.Sampler {
    const id = state().samplers.alloc();
    if (id != 0) resourceCount("samplers", "allocated") else log(.sampler_pool_exhausted);
    const result: t.Sampler = .{ .id = id };
    trace("alloc_sampler", .{result});
    return result;
}
pub fn deallocSampler(handle: t.Sampler) void {
    if (state().samplers.lookup(handle.id) != null) {
        if (state().samplers.dealloc(handle.id)) resourceCount("samplers", "deallocated") else log(.dealloc_sampler_invalid_state);
    }
    trace("dealloc_sampler", .{handle});
}
pub fn querySamplerDefaults(descriptor: t.SamplerDesc) t.SamplerDesc {
    _ = state();
    return defaults.sampler(descriptor);
}
fn initializeSampler(handle: t.Sampler, descriptor: t.SamplerDesc) void {
    const s = state();
    const entry = s.samplers.lookup(handle.id) orelse return;
    if (entry.slot.state != .alloc) {
        log(.init_sampler_invalid_state);
        return;
    }
    const valid = validateSampler(handle, descriptor);
    entry.slot.state = if (valid) .valid else .failed;
    entry.descriptor = if (valid) descriptor else .{};
    if (valid) if (s.gl_backend) |*gl| {
        if (!gl.createSampler(&entry.gl_resource, descriptor)) entry.slot.state = .failed;
    };
    if (valid) if (s.d3d11_backend) |*dx| {
        if (!dx.createSampler(&entry.d3d11_resource, descriptor)) entry.slot.state = .failed;
    };
    resourceCount("samplers", "inited");
}
pub fn initSampler(handle: t.Sampler, descriptor: t.SamplerDesc) void {
    const resolved = querySamplerDefaults(descriptor);
    initializeSampler(handle, resolved);
    trace("init_sampler", .{ handle, &resolved });
}
pub fn makeSampler(descriptor: t.SamplerDesc) t.Sampler {
    const resolved = querySamplerDefaults(descriptor);
    const id = state().samplers.alloc();
    const result: t.Sampler = .{ .id = id };
    if (id != 0) {
        resourceCount("samplers", "allocated");
        initializeSampler(result, resolved);
    } else log(.sampler_pool_exhausted);
    trace("make_sampler", .{ &resolved, result });
    return result;
}
pub fn uninitSampler(handle: t.Sampler) void {
    if (state().samplers.lookup(handle.id)) |entry| {
        if (uninitialize("samplers", handle.id)) resourceCount("samplers", "uninited") else if (entry.slot.state != .alloc) log(.uninit_sampler_invalid_state);
    }
    trace("uninit_sampler", .{handle});
}
pub fn destroySampler(handle: t.Sampler) void {
    trace("destroy_sampler", .{handle});
    if (state().samplers.lookup(handle.id) != null) {
        if (uninitialize("samplers", handle.id)) resourceCount("samplers", "uninited");
        if (state().samplers.dealloc(handle.id)) resourceCount("samplers", "deallocated");
    }
}
pub fn failSampler(handle: t.Sampler) void {
    if (state().samplers.lookup(handle.id)) |entry| {
        if (entry.slot.state == .alloc) entry.slot.state = .failed else log(.fail_sampler_invalid_state);
    }
    trace("fail_sampler", .{handle});
}
pub fn querySamplerState(handle: t.Sampler) e.ResourceState {
    return if (state().samplers.lookup(handle.id)) |entry| entry.slot.state else .invalid;
}
pub fn querySamplerInfo(handle: t.Sampler) t.SamplerInfo {
    const entry = state().samplers.lookup(handle.id) orelse return .{};
    return .{ .slot = entry.slot };
}

pub fn allocShader() t.Shader {
    const id = state().shaders.alloc();
    if (id != 0) resourceCount("shaders", "allocated") else log(.shader_pool_exhausted);
    const result: t.Shader = .{ .id = id };
    trace("alloc_shader", .{result});
    return result;
}
pub fn deallocShader(handle: t.Shader) void {
    if (state().shaders.lookup(handle.id) != null) {
        if (state().shaders.dealloc(handle.id)) resourceCount("shaders", "deallocated") else log(.dealloc_shader_invalid_state);
    }
    trace("dealloc_shader", .{handle});
}
pub fn queryShaderDefaults(descriptor: t.ShaderDesc) t.ShaderDesc {
    _ = state();
    return defaults.shader(descriptor, state().backend);
}
fn initializeShader(handle: t.Shader, descriptor: t.ShaderDesc) void {
    const s = state();
    const entry = s.shaders.lookup(handle.id) orelse return;
    if (entry.slot.state != .alloc) {
        log(.init_shader_invalid_state);
        return;
    }
    const valid = validateShader(handle, descriptor);
    entry.slot.state = if (valid) .valid else .failed;
    entry.descriptor = if (valid) descriptor else .{};
    entry.is_compute = valid and (descriptor.compute_func.source != null or descriptor.compute_func.bytecode.ptr != null);
    if (valid) if (s.gl_backend) |*gl| {
        if (!gl.createShader(&entry.gl_resource, descriptor)) entry.slot.state = .failed;
    };
    if (valid) if (s.d3d11_backend) |*dx| {
        if (!dx.createShader(&entry.d3d11_resource, descriptor)) entry.slot.state = .failed;
    };
    if (valid) resourceCount("shaders", "inited");
}
pub fn initShader(handle: t.Shader, descriptor: t.ShaderDesc) void {
    const resolved = queryShaderDefaults(descriptor);
    initializeShader(handle, resolved);
    trace("init_shader", .{ handle, &resolved });
}
pub fn makeShader(descriptor: t.ShaderDesc) t.Shader {
    const resolved = queryShaderDefaults(descriptor);
    const id = state().shaders.alloc();
    const result: t.Shader = .{ .id = id };
    if (id != 0) {
        resourceCount("shaders", "allocated");
        initializeShader(result, resolved);
    } else log(.shader_pool_exhausted);
    trace("make_shader", .{ &resolved, result });
    return result;
}
pub fn uninitShader(handle: t.Shader) void {
    if (state().shaders.lookup(handle.id)) |entry| {
        if (uninitialize("shaders", handle.id)) resourceCount("shaders", "uninited") else if (entry.slot.state != .alloc) log(.uninit_shader_invalid_state);
    }
    trace("uninit_shader", .{handle});
}
pub fn destroyShader(handle: t.Shader) void {
    trace("destroy_shader", .{handle});
    if (state().shaders.lookup(handle.id) != null) {
        if (uninitialize("shaders", handle.id)) resourceCount("shaders", "uninited");
        if (state().shaders.dealloc(handle.id)) resourceCount("shaders", "deallocated");
    }
}
pub fn failShader(handle: t.Shader) void {
    if (state().shaders.lookup(handle.id)) |entry| {
        if (entry.slot.state == .alloc) entry.slot.state = .failed else log(.fail_shader_invalid_state);
    }
    trace("fail_shader", .{handle});
}
pub fn queryShaderState(handle: t.Shader) e.ResourceState {
    return if (state().shaders.lookup(handle.id)) |entry| entry.slot.state else .invalid;
}
pub fn queryShaderInfo(handle: t.Shader) t.ShaderInfo {
    const entry = state().shaders.lookup(handle.id) orelse return .{};
    return .{ .slot = entry.slot };
}

pub fn allocPipeline() t.Pipeline {
    const id = state().pipelines.alloc();
    if (id != 0) resourceCount("pipelines", "allocated") else log(.pipeline_pool_exhausted);
    const result: t.Pipeline = .{ .id = id };
    trace("alloc_pipeline", .{result});
    return result;
}
pub fn deallocPipeline(handle: t.Pipeline) void {
    if (state().pipelines.lookup(handle.id) != null) {
        if (state().pipelines.dealloc(handle.id)) resourceCount("pipelines", "deallocated") else log(.dealloc_pipeline_invalid_state);
    }
    trace("dealloc_pipeline", .{handle});
}
pub fn queryPipelineDefaults(descriptor: t.PipelineDesc) t.PipelineDesc {
    _ = state();
    return defaults.pipeline(descriptor, state().desc.environment.defaults);
}
fn initializePipeline(handle: t.Pipeline, descriptor: t.PipelineDesc) void {
    const s = state();
    const entry = s.pipelines.lookup(handle.id) orelse return;
    if (entry.slot.state != .alloc) {
        log(.init_pipeline_invalid_state);
        return;
    }
    const valid = validatePipeline(handle, descriptor);
    entry.slot.state = if (valid) .valid else .failed;
    entry.descriptor = if (valid) descriptor else .{};
    if (s.shaders.lookup(descriptor.shader.id)) |dependency| {
        entry.dependency_id = dependency.slot.res_id;
        entry.dependency_uninit_count = dependency.slot.uninit_count;
    }
    if (valid) if (s.gl_backend) |*gl| {
        const shader = s.shaders.lookup(descriptor.shader.id).?;
        if (!gl.createPipeline(&entry.gl_resource, &shader.gl_resource, descriptor)) entry.slot.state = .failed;
    };
    if (valid) if (s.d3d11_backend) |*dx| {
        const shader = s.shaders.lookup(descriptor.shader.id).?;
        if (!dx.createPipeline(&entry.d3d11_resource, &shader.d3d11_resource, descriptor)) entry.slot.state = .failed;
    };
    resourceCount("pipelines", "inited");
}
pub fn initPipeline(handle: t.Pipeline, descriptor: t.PipelineDesc) void {
    const resolved = queryPipelineDefaults(descriptor);
    initializePipeline(handle, resolved);
    trace("init_pipeline", .{ handle, &resolved });
}
pub fn makePipeline(descriptor: t.PipelineDesc) t.Pipeline {
    const resolved = queryPipelineDefaults(descriptor);
    const id = state().pipelines.alloc();
    const result: t.Pipeline = .{ .id = id };
    if (id != 0) {
        resourceCount("pipelines", "allocated");
        initializePipeline(result, resolved);
    } else log(.pipeline_pool_exhausted);
    trace("make_pipeline", .{ &resolved, result });
    return result;
}
pub fn uninitPipeline(handle: t.Pipeline) void {
    if (state().pipelines.lookup(handle.id)) |entry| {
        if (uninitialize("pipelines", handle.id)) resourceCount("pipelines", "uninited") else if (entry.slot.state != .alloc) log(.uninit_pipeline_invalid_state);
    }
    trace("uninit_pipeline", .{handle});
}
pub fn destroyPipeline(handle: t.Pipeline) void {
    trace("destroy_pipeline", .{handle});
    if (state().pipelines.lookup(handle.id) != null) {
        if (uninitialize("pipelines", handle.id)) resourceCount("pipelines", "uninited");
        if (state().pipelines.dealloc(handle.id)) resourceCount("pipelines", "deallocated");
    }
}
pub fn failPipeline(handle: t.Pipeline) void {
    if (state().pipelines.lookup(handle.id)) |entry| {
        if (entry.slot.state == .alloc) entry.slot.state = .failed else log(.fail_pipeline_invalid_state);
    }
    trace("fail_pipeline", .{handle});
}
pub fn queryPipelineState(handle: t.Pipeline) e.ResourceState {
    return if (state().pipelines.lookup(handle.id)) |entry| entry.slot.state else .invalid;
}
pub fn queryPipelineInfo(handle: t.Pipeline) t.PipelineInfo {
    const entry = state().pipelines.lookup(handle.id) orelse return .{};
    return .{ .slot = entry.slot };
}

pub fn allocView() t.View {
    const id = state().views.alloc();
    if (id != 0) resourceCount("views", "allocated") else log(.view_pool_exhausted);
    const result: t.View = .{ .id = id };
    trace("alloc_view", .{result});
    return result;
}
pub fn deallocView(handle: t.View) void {
    if (state().views.lookup(handle.id) != null) {
        if (state().views.dealloc(handle.id)) resourceCount("views", "deallocated") else log(.dealloc_view_invalid_state);
    }
    trace("dealloc_view", .{handle});
}
pub fn queryViewDefaults(descriptor: t.ViewDesc) t.ViewDesc {
    _ = state();
    return descriptor;
}
fn initializeView(handle: t.View, descriptor: t.ViewDesc) void {
    const s = state();
    const entry = s.views.lookup(handle.id) orelse return;
    if (entry.slot.state != .alloc) {
        log(.init_view_invalid_state);
        return;
    }
    const valid = validateView(handle, descriptor);
    entry.slot.state = if (valid) .valid else .failed;
    entry.descriptor = if (valid) descriptor else .{};
    if (entry.slot.state == .valid) resolveView(entry);
    if (valid) if (s.gl_backend) |*gl| {
        const image = s.images.lookup(viewImage(descriptor).id);
        if (!gl.createView(&entry.gl_resource, entry.descriptor, if (image) |img| &img.gl_resource else null, if (image) |img| img.descriptor else .{})) entry.slot.state = .failed;
    };
    if (valid) if (s.d3d11_backend) |*dx| {
        const image = s.images.lookup(viewImage(descriptor).id);
        const buffer = s.buffers.lookup(descriptor.storage_buffer.buffer.id);
        if (!dx.createView(&entry.d3d11_resource, entry.descriptor, if (buffer) |item| &item.d3d11_resource else null, if (buffer) |item| item.descriptor else .{}, if (image) |item| &item.d3d11_resource else null, if (image) |item| item.descriptor else .{})) entry.slot.state = .failed;
    };
    resourceCount("views", "inited");
}
pub fn initView(handle: t.View, descriptor: t.ViewDesc) void {
    const resolved = queryViewDefaults(descriptor);
    initializeView(handle, resolved);
    trace("init_view", .{ handle, &resolved });
}
pub fn makeView(descriptor: t.ViewDesc) t.View {
    const resolved = queryViewDefaults(descriptor);
    const id = state().views.alloc();
    const result: t.View = .{ .id = id };
    if (id != 0) {
        resourceCount("views", "allocated");
        initializeView(result, resolved);
    } else log(.view_pool_exhausted);
    trace("make_view", .{ &resolved, result });
    return result;
}
pub fn uninitView(handle: t.View) void {
    if (state().views.lookup(handle.id)) |entry| {
        if (uninitialize("views", handle.id)) resourceCount("views", "uninited") else if (entry.slot.state != .alloc) log(.uninit_view_invalid_state);
    }
    trace("uninit_view", .{handle});
}
pub fn destroyView(handle: t.View) void {
    trace("destroy_view", .{handle});
    if (state().views.lookup(handle.id) != null) {
        if (uninitialize("views", handle.id)) resourceCount("views", "uninited");
        if (state().views.dealloc(handle.id)) resourceCount("views", "deallocated");
    }
}
pub fn failView(handle: t.View) void {
    if (state().views.lookup(handle.id)) |entry| {
        if (entry.slot.state == .alloc) entry.slot.state = .failed else log(.fail_view_invalid_state);
    }
    trace("fail_view", .{handle});
}
pub fn queryViewState(handle: t.View) e.ResourceState {
    return if (state().views.lookup(handle.id)) |entry| entry.slot.state else .invalid;
}
pub fn queryViewInfo(handle: t.View) t.ViewInfo {
    const entry = state().views.lookup(handle.id) orelse return .{};
    return .{ .slot = entry.slot };
}

pub fn queryStats() t.Stats {
    const s = state();
    s.stats.total.buffers.free = @intCast(s.buffers.free_count);
    s.stats.total.buffers.alive = @intCast(s.buffers.entries.len - 1 - s.buffers.free_count);
    s.stats.total.images.free = @intCast(s.images.free_count);
    s.stats.total.images.alive = @intCast(s.images.entries.len - 1 - s.images.free_count);
    s.stats.total.samplers.free = @intCast(s.samplers.free_count);
    s.stats.total.samplers.alive = @intCast(s.samplers.entries.len - 1 - s.samplers.free_count);
    s.stats.total.shaders.free = @intCast(s.shaders.free_count);
    s.stats.total.shaders.alive = @intCast(s.shaders.entries.len - 1 - s.shaders.free_count);
    s.stats.total.pipelines.free = @intCast(s.pipelines.free_count);
    s.stats.total.pipelines.alive = @intCast(s.pipelines.entries.len - 1 - s.pipelines.free_count);
    s.stats.total.views.free = @intCast(s.views.free_count);
    s.stats.total.views.alive = @intCast(s.views.entries.len - 1 - s.views.free_count);
    if (s.gl_backend) |gl| s.stats.cur_frame.gl = gl.cache.stats;
    if (s.d3d11_backend) |dx| s.stats.cur_frame.d3d11 = dx.stats;
    return s.stats;
}
pub fn enableStats() void {
    state().stats_enabled = true;
    if (state().gl_backend) |*gl| gl.cache.stats_enabled = true;
    if (state().d3d11_backend) |*dx| dx.stats_enabled = true;
}
pub fn disableStats() void {
    state().stats_enabled = false;
    if (state().gl_backend) |*gl| gl.cache.stats_enabled = false;
    if (state().d3d11_backend) |*dx| dx.stats_enabled = false;
}
pub fn statsEnabled() bool {
    return state().stats_enabled;
}
pub fn addCommitListener(listener: t.CommitListener) bool {
    std.debug.assert(listener.func != null);
    const s = state();
    for (s.listeners[0..s.listener_upper]) |item| {
        if (item.func == listener.func and item.user_data == listener.user_data) {
            log(.identical_commit_listener);
            return false;
        }
    }
    for (s.listeners[0..s.listener_upper]) |*item| {
        if (item.func == null) {
            item.* = listener;
            return true;
        }
    }
    if (s.listener_upper == s.listeners.len) {
        log(.commit_listener_array_full);
        return false;
    }
    s.listeners[s.listener_upper] = listener;
    s.listener_upper += 1;
    return true;
}
pub fn removeCommitListener(listener: t.CommitListener) bool {
    std.debug.assert(listener.func != null);
    const s = state();
    for (s.listeners[0..s.listener_upper]) |*item| {
        if (item.func == listener.func and item.user_data == listener.user_data) {
            item.* = .{};
            return true;
        }
    }
    return false;
}
pub fn commit() void {
    const s = state();
    std.debug.assert(s.current_pass == null);
    if (s.gl_backend) |*gl| {
        gl.commit();
        s.stats.cur_frame.gl = gl.cache.stats;
        gl.cache.stats = .{};
    }
    if (s.d3d11_backend) |*dx| {
        s.stats.cur_frame.d3d11 = dx.stats;
        dx.stats = .{};
    }
    s.stats.cur_frame.frame_index = s.frame_index;
    s.stats.prev_frame = s.stats.cur_frame;
    s.stats.cur_frame = .{};
    var i: usize = 0;
    while (i < s.listener_upper) : (i += 1) {
        const listener = s.listeners[i];
        if (listener.func) |callback| callback(listener.user_data);
    }
    trace("commit", .{});
    s.frame_index +%= 1;
}
pub fn resetStateCache() void {
    if (state().gl_backend) |*gl| gl.cache.reset(gl.vao, gl.gles);
    trace("reset_state_cache", .{});
}
pub fn pushDebugGroup(name: [*:0]const u8) void {
    trace("push_debug_group", .{name});
}
pub fn popDebugGroup() void {
    trace("pop_debug_group", .{});
}

pub fn queryBufferDesc(handle: t.Buffer) t.BufferDesc {
    const entry = state().buffers.lookup(handle.id) orelse return .{};
    return .{
        .size = entry.descriptor.size,
        .usage = entry.descriptor.usage,
    };
}

pub fn queryImageDesc(handle: t.Image) t.ImageDesc {
    const entry = state().images.lookup(handle.id) orelse return .{};
    return .{
        .type = entry.descriptor.type,
        .width = entry.descriptor.width,
        .height = entry.descriptor.height,
        .num_slices = entry.descriptor.num_slices,
        .num_mipmaps = entry.descriptor.num_mipmaps,
        .usage = entry.descriptor.usage,
        .pixel_format = entry.descriptor.pixel_format,
        .sample_count = entry.descriptor.sample_count,
    };
}

pub fn querySamplerDesc(handle: t.Sampler) t.SamplerDesc {
    const entry = state().samplers.lookup(handle.id) orelse return .{};
    return .{
        .min_filter = entry.descriptor.min_filter,
        .mag_filter = entry.descriptor.mag_filter,
        .mipmap_filter = entry.descriptor.mipmap_filter,
        .wrap_u = entry.descriptor.wrap_u,
        .wrap_v = entry.descriptor.wrap_v,
        .wrap_w = entry.descriptor.wrap_w,
        .min_lod = entry.descriptor.min_lod,
        .max_lod = entry.descriptor.max_lod,
        .border_color = entry.descriptor.border_color,
        .compare = entry.descriptor.compare,
        .max_anisotropy = entry.descriptor.max_anisotropy,
    };
}

pub fn queryShaderDesc(handle: t.Shader) t.ShaderDesc {
    const entry = state().shaders.lookup(handle.id) orelse return .{};
    return shaderDescriptor(entry.descriptor);
}

pub fn queryPipelineDesc(handle: t.Pipeline) t.PipelineDesc {
    const entry = state().pipelines.lookup(handle.id) orelse return .{};
    return .{
        .compute = entry.descriptor.compute,
        .shader = entry.descriptor.shader,
        .layout = entry.descriptor.layout,
        .depth = entry.descriptor.depth,
        .stencil = entry.descriptor.stencil,
        .color_count = entry.descriptor.color_count,
        .colors = entry.descriptor.colors,
        .primitive_type = entry.descriptor.primitive_type,
        .index_type = entry.descriptor.index_type,
        .cull_mode = entry.descriptor.cull_mode,
        .face_winding = entry.descriptor.face_winding,
        .sample_count = entry.descriptor.sample_count,
        .blend_color = entry.descriptor.blend_color,
        .alpha_to_coverage_enabled = entry.descriptor.alpha_to_coverage_enabled,
    };
}

pub fn queryViewDesc(handle: t.View) t.ViewDesc {
    const entry = state().views.lookup(handle.id) orelse return .{};
    return .{
        .texture = entry.descriptor.texture,
        .storage_buffer = entry.descriptor.storage_buffer,
        .storage_image = entry.descriptor.storage_image,
        .color_attachment = entry.descriptor.color_attachment,
        .resolve_attachment = entry.descriptor.resolve_attachment,
        .depth_stencil_attachment = entry.descriptor.depth_stencil_attachment,
    };
}
pub fn queryBufferSize(handle: t.Buffer) usize {
    return queryBufferDesc(handle).size;
}
pub fn queryBufferUsage(handle: t.Buffer) t.BufferUsage {
    return queryBufferDesc(handle).usage;
}
pub fn queryImageType(handle: t.Image) e.ImageType {
    return queryImageDesc(handle).type;
}
pub fn queryImageWidth(handle: t.Image) i32 {
    return queryImageDesc(handle).width;
}
pub fn queryImageHeight(handle: t.Image) i32 {
    return queryImageDesc(handle).height;
}
pub fn queryImageNumSlices(handle: t.Image) i32 {
    return queryImageDesc(handle).num_slices;
}
pub fn queryImageNumMipmaps(handle: t.Image) i32 {
    return queryImageDesc(handle).num_mipmaps;
}
pub fn queryImagePixelformat(handle: t.Image) e.PixelFormat {
    return queryImageDesc(handle).pixel_format;
}
pub fn queryImageUsage(handle: t.Image) t.ImageUsage {
    return queryImageDesc(handle).usage;
}
pub fn queryImageSampleCount(handle: t.Image) i32 {
    return queryImageDesc(handle).sample_count;
}

fn validationEnabled() bool {
    return !state().desc.disable_validation and (@import("builtin").mode == .debug or @import("builtin").mode == .safe);
}
fn validateBuffer(_: t.Buffer, descriptor: t.BufferDesc) bool {
    return !validationEnabled() or validation.buffer(descriptor, queryFeatures(), state().desc.logger);
}
fn validateImage(_: t.Image, descriptor: t.ImageDesc) bool {
    return !validationEnabled() or validation.image(descriptor, queryLimits(), queryPixelformat(descriptor.pixel_format), state().desc.logger);
}
fn validateSampler(_: t.Sampler, descriptor: t.SamplerDesc) bool {
    return !validationEnabled() or validation.sampler(descriptor, state().desc.logger);
}
fn validateShader(_: t.Shader, descriptor: t.ShaderDesc) bool {
    if (validationEnabled() and !validation.shader(descriptor, state().desc.logger)) return false;
    if (validationEnabled() and state().gl_backend != null and !validation.glShader(descriptor, state().desc.logger)) return false;
    if (validationEnabled() and state().d3d11_backend != null and !validation.d3dShader(descriptor, state().desc.logger)) return false;
    return validation.shaderBindingLimits(descriptor, queryLimits(), state().desc.logger);
}
fn validatePipeline(_: t.Pipeline, descriptor: t.PipelineDesc) bool {
    const dependency = state().shaders.lookup(descriptor.shader.id);
    const valid = if (dependency) |shader| shader.slot.state == .valid else false;
    if (!validationEnabled()) return valid;
    if (!validation.pipeline(descriptor, if (valid) dependency.?.descriptor else null, if (valid) dependency.?.is_compute else false, queryFeatures(), state().desc.logger)) return false;
    if (state().d3d11_backend != null) {
        var shader_desc = dependency.?.descriptor;
        // Shader creation copies semantic names; validation must use those
        // owned copies after the caller's descriptor storage has expired.
        for (&shader_desc.attrs, &dependency.?.d3d11_resource.semantic_names) |*attribute, *name| attribute.hlsl_sem_name = name;
        return validation.d3dPipeline(descriptor, shader_desc, queryLimits(), state().desc.logger);
    }
    return true;
}

fn viewImage(descriptor: t.ViewDesc) t.Image {
    if (descriptor.texture.image.id != 0) return descriptor.texture.image;
    if (descriptor.storage_image.image.id != 0) return descriptor.storage_image.image;
    if (descriptor.color_attachment.image.id != 0) return descriptor.color_attachment.image;
    if (descriptor.resolve_attachment.image.id != 0) return descriptor.resolve_attachment.image;
    return descriptor.depth_stencil_attachment.image;
}
fn viewType(descriptor: t.ViewDesc) e.ViewType {
    if (descriptor.texture.image.id != 0) return .texture;
    if (descriptor.storage_buffer.buffer.id != 0) return .storagebuffer;
    if (descriptor.storage_image.image.id != 0) return .storageimage;
    if (descriptor.color_attachment.image.id != 0) return .colorattachment;
    if (descriptor.resolve_attachment.image.id != 0) return .resolveattachment;
    if (descriptor.depth_stencil_attachment.image.id != 0) return .depthstencilattachment;
    return .invalid;
}
fn validateView(_: t.View, descriptor: t.ViewDesc) bool {
    const s = state();
    var check: validation.Check = .{ .logger = s.desc.logger };
    check.require(descriptor._start_canary == 0 and descriptor._end_canary == 0, .validate_viewdesc_canary);
    var num_types: u32 = @intFromBool(descriptor.storage_buffer.buffer.id != 0);
    inline for (.{ "texture", "storage_image", "color_attachment", "resolve_attachment", "depth_stencil_attachment" }) |name| num_types += @intFromBool(@field(descriptor, name).image.id != 0);
    check.require(num_types <= 1, .validate_viewdesc_unique_viewtype);
    check.require(num_types > 0, .validate_viewdesc_any_viewtype);
    if (num_types != 1) return false;
    const kind = viewType(descriptor);
    if (kind == .storagebuffer) {
        const maybe_buffer = s.buffers.lookup(descriptor.storage_buffer.buffer.id);
        check.require(maybe_buffer != null, .validate_viewdesc_resource_alive);
        const buffer = maybe_buffer orelse return false;
        check.require(buffer.slot.state == .valid, .validate_viewdesc_resource_valid);
        if (buffer.slot.state != .valid) return false;
        if (!validationEnabled()) return true;
        check.require(buffer.descriptor.usage.storage_buffer, .validate_viewdesc_storagebuffer_usage);
        const offset = descriptor.storage_buffer.offset;
        check.require(offset >= 0 and @as(usize, @intCast(@max(offset, 0))) < buffer.descriptor.size, .validate_viewdesc_storagebuffer_offset_vs_buffer_size);
        check.require(offset >= 0 and @mod(offset, 256) == 0, .validate_viewdesc_storagebuffer_offset_multiple_256);
    } else {
        const maybe_image = s.images.lookup(viewImage(descriptor).id);
        check.require(maybe_image != null, .validate_viewdesc_resource_alive);
        const image = maybe_image orelse return false;
        const valid = image.slot.state == .valid or (kind == .texture and image.slot.state == .unsealed);
        check.require(valid, if (kind == .texture) .validate_viewdesc_image_valid_unsealed else .validate_viewdesc_resource_valid);
        if (!valid) return false;
        if (!validationEnabled()) return true;
        const desc = image.descriptor;
        const info = queryPixelformat(desc.pixel_format);
        var image_view: t.ImageViewDesc = .{};
        switch (kind) {
            .texture => check.require(queryFeatures().msaa_texture_bindings or desc.sample_count == 1, .validate_viewdesc_texture_expect_no_msaa),
            .storageimage => {
                check.require(desc.usage.storage_image, .validate_viewdesc_storageimage_usage);
                check.require(info.read or info.write, .validate_viewdesc_storageimage_pixelformat);
                image_view = descriptor.storage_image;
            },
            .colorattachment => {
                check.require(desc.usage.color_attachment, .validate_viewdesc_colorattachment_usage);
                check.require(info.render and !info.depth, .validate_viewdesc_colorattachment_pixelformat);
                image_view = descriptor.color_attachment;
            },
            .resolveattachment => {
                check.require(desc.usage.resolve_attachment, .validate_viewdesc_resolveattachment_usage);
                check.require(desc.sample_count == 1, .validate_viewdesc_resolveattachment_samplecount);
                image_view = descriptor.resolve_attachment;
            },
            .depthstencilattachment => {
                check.require(desc.usage.depth_stencil_attachment, .validate_viewdesc_depthstencilattachment_usage);
                check.require(info.render and info.depth, .validate_viewdesc_depthstencilattachment_pixelformat);
                image_view = descriptor.depth_stencil_attachment;
            },
            else => return false,
        }
        if (kind == .texture) {
            const mip = descriptor.texture.mip_levels;
            const slices = descriptor.texture.slices;
            check.require(mip.base >= 0 and @as(i64, mip.base) + mip.count <= desc.num_mipmaps, .validate_viewdesc_texture_miplevels);
            switch (desc.type) {
                .@"2d" => check.require(slices.base == 0 and @as(i64, slices.base) + slices.count <= 1, .validate_viewdesc_texture_2d_slices),
                .cube => check.require(slices.base == 0 and @as(i64, slices.base) + slices.count <= 1, .validate_viewdesc_texture_cubemap_slices),
                .@"3d" => check.require(slices.base == 0 and @as(i64, slices.base) + slices.count <= 1, .validate_viewdesc_texture_3d_slices),
                .array => check.require(slices.base >= 0 and @as(i64, slices.base) + slices.count <= desc.num_slices, .validate_viewdesc_texture_array_slices),
                else => return false,
            }
        } else {
            check.require(image_view.mip_level >= 0 and image_view.mip_level < desc.num_mipmaps, .validate_viewdesc_image_miplevel);
            switch (desc.type) {
                .@"2d" => check.require(image_view.slice == 0, .validate_viewdesc_image_2d_slice),
                .cube => check.require(image_view.slice >= 0 and image_view.slice < 6, .validate_viewdesc_image_cubemap_slice),
                .array => check.require(image_view.slice >= 0 and image_view.slice < desc.num_slices, .validate_viewdesc_image_array_slice),
                .@"3d" => check.require(image_view.slice == 0, .validate_viewdesc_image_3d_slice),
                else => return false,
            }
        }
    }
    return !validationEnabled() or check.valid;
}

fn resolveView(entry: *Pool(t.ViewDesc).Entry) void {
    const s = state();
    if (entry.descriptor.storage_buffer.buffer.id != 0) {
        const dependency = s.buffers.lookup(entry.descriptor.storage_buffer.buffer.id).?;
        entry.dependency_id = dependency.slot.res_id;
        entry.dependency_uninit_count = dependency.slot.uninit_count;
    } else {
        const dependency = s.images.lookup(viewImage(entry.descriptor).id).?;
        entry.dependency_id = dependency.slot.res_id;
        entry.dependency_uninit_count = dependency.slot.uninit_count;
        if (entry.descriptor.texture.image.id != 0) {
            const desc = &entry.descriptor.texture;
            if (desc.mip_levels.count == 0) desc.mip_levels.count = dependency.descriptor.num_mipmaps - desc.mip_levels.base;
            desc.slices.count = switch (dependency.descriptor.type) {
                .@"2d", .@"3d" => 1,
                .cube => 6,
                .array => if (desc.slices.count == 0) dependency.descriptor.num_slices - desc.slices.base else desc.slices.count,
                else => unreachable,
            };
        }
    }
}
fn shaderDescriptor(source: t.ShaderDesc) t.ShaderDesc {
    var result: t.ShaderDesc = .{};
    for (&result.uniform_blocks, source.uniform_blocks) |*dst, src| dst.* = .{ .stage = src.stage, .size = src.size };
    for (&result.views, source.views) |*dst, src| {
        if (src.texture.stage != .none) {
            dst.texture = .{ .stage = src.texture.stage, .image_type = src.texture.image_type, .sample_type = src.texture.sample_type, .multisampled = src.texture.multisampled };
        } else if (src.storage_buffer.stage != .none) {
            dst.storage_buffer = .{ .stage = src.storage_buffer.stage, .readonly = src.storage_buffer.readonly };
        } else if (src.storage_image.stage != .none) {
            dst.storage_image = .{ .stage = src.storage_image.stage, .access_format = src.storage_image.access_format, .image_type = src.storage_image.image_type, .writeonly = src.storage_image.writeonly };
        }
    }
    for (&result.samplers, source.samplers) |*dst, src| dst.* = .{ .stage = src.stage, .sampler_type = src.sampler_type };
    for (&result.texture_sampler_pairs, source.texture_sampler_pairs) |*dst, src| dst.* = .{ .stage = src.stage, .view_slot = src.view_slot, .sampler_slot = src.sampler_slot };
    return result;
}
pub fn queryViewType(handle: t.View) e.ViewType {
    const entry = state().views.lookup(handle.id) orelse return .invalid;
    return viewType(entry.descriptor);
}
pub fn queryViewImage(handle: t.View) t.Image {
    const entry = state().views.lookup(handle.id) orelse return .{};
    return viewImage(entry.descriptor);
}
pub fn queryViewBuffer(handle: t.View) t.Buffer {
    const entry = state().views.lookup(handle.id) orelse return .{};
    return entry.descriptor.storage_buffer.buffer;
}

fn viewAlive(handle: t.View, require_valid: bool) bool {
    const s = state();
    const entry = s.views.lookup(handle.id) orelse return false;
    if (require_valid and entry.slot.state != .valid) return false;
    if (viewType(entry.descriptor) == .storagebuffer) {
        const resource = s.buffers.lookup(entry.dependency_id) orelse return false;
        return resource.slot.uninit_count == entry.dependency_uninit_count and (!require_valid or resource.slot.state == .valid);
    }
    const resource = s.images.lookup(entry.dependency_id) orelse return false;
    return resource.slot.uninit_count == entry.dependency_uninit_count and (!require_valid or resource.slot.state == .valid);
}
fn pipelineAlive() ?*Pool(t.PipelineDesc).Entry {
    const s = state();
    const entry = s.pipelines.lookup(s.current_pipeline.id) orelse return null;
    if (entry.slot.uninit_count != s.pipeline_uninit_count or entry.slot.state != .valid) return null;
    const shader = s.shaders.lookup(entry.dependency_id) orelse return null;
    if (shader.slot.uninit_count != entry.dependency_uninit_count or shader.slot.state != .valid) return null;
    return entry;
}
pub fn beginPass(descriptor: t.Pass) void {
    const s = state();
    std.debug.assert(s.current_pass == null);
    std.debug.assert(descriptor._start_canary == 0 and descriptor._end_canary == 0);
    const pass = defaults.pass(descriptor, s.desc.environment.defaults);
    if (validationEnabled()) s.pass_index +%= 1;
    s.current_pass = pass;
    s.pass_valid = false;
    s.next_draw_valid = false;
    s.current_pipeline = .{};
    trace("begin_pass", .{&pass});
    if (pass.compute and validationEnabled() and !queryFeatures().compute) return;
    if (defaults.attachmentsEmpty(pass.attachments)) {
        if (pass.swapchain.invalid) return;
        if (!pass.compute and validationEnabled() and (pass.swapchain.width <= 0 or pass.swapchain.height <= 0)) return;
    } else {
        if (pass.compute) return;
        var num_colors: u32 = 0;
        for (pass.attachments.colors, pass.attachments.resolves) |color, resolved| {
            if (color.id != 0) {
                num_colors += 1;
                if (!viewAlive(color, true) or queryViewType(color) != .colorattachment) return;
            }
            if (resolved.id != 0) {
                if (color.id == 0 or !viewAlive(resolved, true) or queryViewType(resolved) != .resolveattachment) return;
            }
        }
        if (num_colors > @as(u32, @intCast(queryLimits().max_color_attachments))) return;
        const depth = pass.attachments.depth_stencil;
        if (depth.id != 0 and (!viewAlive(depth, true) or queryViewType(depth) != .depthstencilattachment)) return;
    }
    const attachments = nativeAttachments(gl_resources, "gl_resource", pass.attachments) orelse return;
    s.pass_width = if (attachments.empty()) pass.swapchain.width else attachments.width;
    s.pass_height = if (attachments.empty()) pass.swapchain.height else attachments.height;
    s.pass_valid = if (s.gl_backend) |*gl| gl.beginPass(pass, &attachments) else true;
    if (s.d3d11_backend) |*dx| {
        const native = nativeAttachments(d3d_resources, "d3d11_resource", pass.attachments) orelse {
            s.pass_valid = false;
            return;
        };
        s.pass_valid = dx.beginPass(pass, &native);
    }
}
pub fn endPass() void {
    const s = state();
    std.debug.assert(s.current_pass != null);
    if (s.gl_backend) |*gl| {
        const pass = s.current_pass.?;
        if (!pass.swapchain.invalid) if (nativeAttachments(gl_resources, "gl_resource", pass.attachments)) |attachments| gl.endPass(pass, &attachments);
    }
    if (s.d3d11_backend) |*dx| {
        const pass = s.current_pass.?;
        if (!pass.swapchain.invalid) if (nativeAttachments(d3d_resources, "d3d11_resource", pass.attachments)) |atts| dx.endPass(pass, &atts);
    }
    count("num_passes", 1);
    trace("end_pass", .{});
    s.current_pass = null;
    s.current_pipeline = .{};
    s.pass_valid = false;
    s.next_draw_valid = false;
}
pub fn applyViewport(x: i32, y: i32, width: i32, height: i32, origin_top_left: bool) void {
    count("num_apply_viewport", 1);
    trace("apply_viewport", .{ x, y, width, height, origin_top_left });
    if (state().pass_valid) if (state().gl_backend) |*gl| gl.viewport(state().pass_height, x, y, width, height, origin_top_left);
    if (state().pass_valid) if (state().d3d11_backend) |*dx| dx.viewport(state().pass_height, x, y, width, height, origin_top_left);
}
pub fn applyViewportf(x: f32, y: f32, width: f32, height: f32, origin_top_left: bool) void {
    applyViewport(@intFromFloat(x), @intFromFloat(y), @intFromFloat(width), @intFromFloat(height), origin_top_left);
}
pub fn applyScissorRect(x: i32, y: i32, width: i32, height: i32, origin_top_left: bool) void {
    count("num_apply_scissor_rect", 1);
    trace("apply_scissor_rect", .{ x, y, width, height, origin_top_left });
    if (state().pass_valid) if (state().gl_backend) |*gl| gl.scissor(state().pass_height, x, y, width, height, origin_top_left);
    if (state().pass_valid) if (state().d3d11_backend) |*dx| dx.scissor(state().pass_height, x, y, width, height, origin_top_left);
}
pub fn applyScissorRectf(x: f32, y: f32, width: f32, height: f32, origin_top_left: bool) void {
    applyScissorRect(@intFromFloat(x), @intFromFloat(y), @intFromFloat(width), @intFromFloat(height), origin_top_left);
}
pub fn applyPipeline(handle: t.Pipeline) void {
    count("num_apply_pipeline", 1);
    trace("apply_pipeline", .{handle});
    const s = state();
    if (!s.pass_valid) return;
    s.next_draw_valid = false;
    const entry = s.pipelines.lookup(handle.id) orelse return;
    s.current_pipeline = handle;
    s.pipeline_uninit_count = entry.slot.uninit_count;
    if (pipelineAlive() == null) return;
    const pass = s.current_pass.?;
    const desc = entry.descriptor;
    const shader = s.shaders.lookup(entry.dependency_id).?;
    s.required = 0;
    s.applied = 0;
    s.write_buffer_transient_missing = false;
    s.write_image_transient_missing = false;
    for (shader.descriptor.uniform_blocks, 0..) |block, i| {
        if (block.stage != .none) s.required |= @as(u16, 1) << @as(u4, @intCast(i));
    }
    for (shader.descriptor.views) |view| {
        if (view.storage_buffer.stage != .none or view.storage_image.stage != .none) s.required |= 256;
    }
    for (shader.descriptor.samplers) |sampler| {
        if (sampler.stage != .none) s.required |= 256;
    }
    for (desc.layout.attrs) |attr| {
        if (attr.format != .invalid) s.required |= 256;
    }
    if (desc.index_type != .none) s.required |= 256;
    if (validationEnabled()) {
        if (desc.compute != pass.compute) return;
        if (!pass.compute and defaults.attachmentsEmpty(pass.attachments)) {
            if (desc.color_count != 1 or desc.colors[0].pixel_format != pass.swapchain.color_format or
                desc.depth.pixel_format != pass.swapchain.depth_format or desc.sample_count != pass.swapchain.sample_count) return;
        } else if (!pass.compute) {
            var num_colors: i32 = 0;
            for (pass.attachments.colors, 0..) |view, i| {
                if (view.id == 0) continue;
                num_colors += 1;
                if (!viewAlive(view, true)) return;
                const image = queryImageDesc(queryViewImage(view));
                if (desc.colors[i].pixel_format != image.pixel_format or desc.sample_count != image.sample_count) return;
            }
            if (num_colors != desc.color_count) return;
            const depth = pass.attachments.depth_stencil;
            if (depth.id == 0) {
                if (desc.depth.pixel_format != .none) return;
            } else {
                if (!viewAlive(depth, true)) return;
                const image = queryImageDesc(queryViewImage(depth));
                if (desc.depth.pixel_format != image.pixel_format or desc.sample_count != image.sample_count) return;
            }
        }
    }
    s.next_draw_valid = true;
    if (s.gl_backend) |*gl| gl.applyPipeline(.{ .resource = &entry.gl_resource, .desc = &entry.descriptor, .slot = entry.slot }, &shader.gl_resource);
    if (s.d3d11_backend) |*dx| dx.applyPipeline(.{ .resource = &entry.d3d11_resource, .desc = &entry.descriptor, .slot = entry.slot }, &shader.d3d11_resource);
}
pub fn applyBindings(bindings: t.Bindings) void {
    count("num_apply_bindings", 1);
    trace("apply_bindings", .{&bindings});
    const s = state();
    if (!s.pass_valid) return;
    const pipeline = pipelineAlive() orelse {
        s.next_draw_valid = false;
        return;
    };
    if (!s.next_draw_valid) return;
    s.applied |= 256;
    if (bindings._start_canary != 0 or bindings._end_canary != 0) {
        s.next_draw_valid = false;
        return;
    }
    const shader = s.shaders.lookup(pipeline.dependency_id).?;
    var active: [8]bool = @splat(false);
    if (s.gl_backend != null) active = pipeline.gl_resource.active_vertex_buffers;
    if (!s.current_pass.?.compute) {
        if (s.gl_backend == null) for (pipeline.descriptor.layout.attrs) |attr| {
            if (attr.format != .invalid) active[@intCast(attr.buffer_index)] = true;
        };
        for (active, bindings.vertex_buffers, bindings.vertex_buffer_offsets) |used, handle, offset| {
            if (!used) continue;
            const buffer = s.buffers.lookup(handle.id) orelse {
                s.next_draw_valid = false;
                continue;
            };
            if (buffer.slot.state != .valid or (validationEnabled() and (!buffer.descriptor.usage.vertex_buffer or offset < 0))) s.next_draw_valid = false;
            if (validationEnabled() and buffer.descriptor.usage.write_transient and buffer.write_frame != s.frame_index) s.write_buffer_transient_missing = true;
            buffer.bind_frame = s.frame_index;
        }
        if (pipeline.descriptor.index_type != .none or bindings.index_buffer.id != 0) {
            if (s.buffers.lookup(bindings.index_buffer.id)) |buffer| {
                if (buffer.slot.state != .valid or (validationEnabled() and (!buffer.descriptor.usage.index_buffer or bindings.index_buffer_offset < 0))) s.next_draw_valid = false;
                buffer.bind_frame = s.frame_index;
            } else s.next_draw_valid = false;
        }
    }
    for (shader.descriptor.views, bindings.views) |required, handle| {
        if (required.texture.stage == .none and required.storage_buffer.stage == .none and required.storage_image.stage == .none) continue;
        if (!viewAlive(handle, true)) {
            s.next_draw_valid = false;
            continue;
        }
        const view = s.views.lookup(handle.id).?;
        if (viewType(view.descriptor) == .storagebuffer) {
            s.buffers.lookup(view.dependency_id).?.bind_frame = s.frame_index;
        } else {
            const image = s.images.lookup(view.dependency_id).?;
            if (validationEnabled() and image.descriptor.usage.write_transient and image.write_frame != s.frame_index) s.write_image_transient_missing = true;
            image.bind_frame = s.frame_index;
        }
    }
    for (shader.descriptor.samplers, bindings.samplers) |required, handle| {
        if (required.stage == .none) continue;
        if (querySamplerState(handle) != .valid) s.next_draw_valid = false;
    }
    if (validationEnabled() and !runtime_validation.bindings(s, bindings, active, queryPixelformat)) s.next_draw_valid = false;
    if (s.next_draw_valid) if (s.gl_backend) |*gl| {
        const resolved = nativeBindings(gl_resources, "gl_resource", pipeline, shader, bindings, active);
        s.next_draw_valid = gl.applyBindings(&resolved);
    };
    if (s.next_draw_valid) if (s.d3d11_backend) |*dx| {
        const resolved = nativeBindings(d3d_resources, "d3d11_resource", pipeline, shader, bindings, active);
        s.next_draw_valid = dx.applyBindings(&resolved);
    };
}
pub fn applyUniforms(slot: i32, data: t.Range) void {
    std.debug.assert(slot >= 0 and slot < 8 and data.ptr != null and data.size > 0);
    count("num_apply_uniforms", 1);
    count("size_apply_uniforms", @truncate(data.size));
    trace("apply_uniforms", .{ slot, &data });
    const s = state();
    if (!s.pass_valid or !s.next_draw_valid) return;
    s.applied |= @as(u16, 1) << @as(u4, @intCast(slot));
    const pipeline = pipelineAlive() orelse {
        s.next_draw_valid = false;
        return;
    };
    const shader = s.shaders.lookup(pipeline.dependency_id).?;
    const block = shader.descriptor.uniform_blocks[@intCast(slot)];
    if (validationEnabled() and (block.stage == .none or data.size != block.size)) s.next_draw_valid = false;
    if (s.next_draw_valid) if (s.gl_backend) |*gl| gl.applyUniforms(&shader.gl_resource, @intCast(slot), data);
    if (s.next_draw_valid) if (s.d3d11_backend) |*dx| dx.applyUniforms(&shader.d3d11_resource, @intCast(slot), data);
}
pub fn draw(base_element: i32, num_elements: i32, num_instances: i32) void {
    count("num_draw", 1);
    trace("draw", .{ base_element, num_elements, num_instances });
    if (!validDraw(base_element, num_elements, num_instances)) return;
    if (state().gl_backend) |*gl| gl.draw(useInstanced(pipelineAlive().?.descriptor), base_element, num_elements, num_instances, 0, 0);
    if (state().d3d11_backend) |*dx| dx.draw(pipelineAlive().?.descriptor.index_type != .none, useInstanced(pipelineAlive().?.descriptor), base_element, num_elements, num_instances, 0, 0);
}
fn validDraw(base_element: i32, num_elements: i32, num_instances: i32) bool {
    const s = state();
    if (!s.pass_valid or !s.next_draw_valid or num_elements == 0 or num_instances == 0) return false;
    if (pipelineAlive() == null) return false;
    if (validationEnabled()) {
        if (s.current_pass.?.compute or base_element < 0 or num_elements < 0 or num_instances < 0 or s.required != s.applied) return false;
        if (s.write_buffer_transient_missing) {
            log(.validate_draw_write_buffer_transient_missing);
            return false;
        }
        if (s.write_image_transient_missing) {
            log(.validate_draw_write_image_transient_missing);
            return false;
        }
    }
    return true;
}
pub fn drawEx(base_element: i32, num_elements: i32, num_instances: i32, base_vertex: i32, base_instance: i32) void {
    count("num_draw_ex", 1);
    trace("draw_ex", .{ base_element, num_elements, num_instances, base_vertex, base_instance });
    if (!validDraw(base_element, num_elements, num_instances)) return;
    if (validationEnabled()) {
        if (base_instance < 0 or (base_vertex != 0 and !queryFeatures().draw_base_vertex) or (base_instance > 0 and !queryFeatures().draw_base_instance)) return;
    }
    const instanced = useInstanced(pipelineAlive().?.descriptor);
    if (validationEnabled() and ((base_vertex != 0 and pipelineAlive().?.descriptor.index_type == .none) or (base_instance != 0 and !(instanced or num_instances > 1)))) return;
    if (state().gl_backend) |*gl| gl.draw(instanced, base_element, num_elements, num_instances, base_vertex, base_instance);
    if (state().d3d11_backend) |*dx| dx.draw(pipelineAlive().?.descriptor.index_type != .none, instanced, base_element, num_elements, num_instances, base_vertex, base_instance);
}
pub fn dispatch(x: i32, y: i32, z: i32) void {
    count("num_dispatch", 1);
    trace("dispatch", .{ x, y, z });
    const s = state();
    if (!s.pass_valid or !s.next_draw_valid or x == 0 or y == 0 or z == 0) return;
    if (validationEnabled() and (!s.current_pass.?.compute or x < 0 or y < 0 or z < 0 or s.required != s.applied)) return;
    if (validationEnabled() and (s.write_buffer_transient_missing or s.write_image_transient_missing)) return;
    if (s.gl_backend) |*gl| gl.dispatch(x, y, z);
    if (s.d3d11_backend) |*dx| dx.dispatch(x, y, z);
}
fn fits(offset: usize, size: usize, capacity: usize) bool {
    return offset <= capacity and size <= capacity - offset;
}
fn writeBuffer(comptime transient: bool, descriptor: t.WriteBufferDesc) void {
    const name = if (transient) "write_buffer_transient" else "write_buffer_unsealed";
    count("num_" ++ name, 1);
    const s = state();
    const entry = s.buffers.lookup(descriptor.dst.buffer.id) orelse return;
    if (entry.slot.state != (if (transient) e.ResourceState.valid else e.ResourceState.unsealed)) return;
    const desc = defaults.writeBuffer(descriptor);
    const usage = entry.descriptor.usage;
    var valid = true;
    if (validationEnabled()) {
        valid = desc.src.data.ptr != null and desc.size > 0 and fits(desc.src.offset, desc.size, desc.src.data.size) and
            fits(desc.dst.offset, desc.size, entry.descriptor.size) and
            (if (transient) usage.write_transient and desc.dst.offset % 4 == 0 and entry.bind_frame != s.frame_index and entry.copy_frame != s.frame_index else usage.write_unsealed);
    }
    const first = entry.write_frame != s.frame_index;
    if (valid and transient and first) {
        entry.write_frame = s.frame_index;
        entry.active_slot = @mod(entry.active_slot + 1, 2);
    }
    if (valid) if (s.gl_backend) |*gl| gl.writeBuffer(&entry.gl_resource, usage, entry.active_slot, desc);
    if (valid) if (s.d3d11_backend) |*dx| dx.writeBuffer(&entry.d3d11_resource, desc, transient, first);
    trace(name, .{&descriptor});
}
pub fn writeBufferTransient(descriptor: t.WriteBufferDesc) void {
    writeBuffer(true, descriptor);
}
pub fn writeBufferUnsealed(descriptor: t.WriteBufferDesc) void {
    writeBuffer(false, descriptor);
}
fn validImageTransfer(comptime T: type, desc: T, image: t.ImageDesc) bool {
    if (desc.dst.mip_level < 0 or desc.dst.mip_level >= image.num_mipmaps) return false;
    const width = formats.mipDimension(image.width, desc.dst.mip_level);
    const height = formats.mipDimension(image.height, desc.dst.mip_level);
    const slices = if (image.type == .@"3d") formats.mipDimension(image.num_slices, desc.dst.mip_level) else image.num_slices;
    const size = desc.size;
    if (size.width <= 0 or size.height <= 0 or size.num_slices <= 0 or desc.dst.x < 0 or desc.dst.y < 0 or desc.dst.slice < 0) return false;
    if (desc.dst.x > width or size.width > width - desc.dst.x or desc.dst.y > height or size.height > height - desc.dst.y or desc.dst.slice > slices or size.num_slices > slices - desc.dst.slice) return false;
    const block = formats.blockDimension(image.pixel_format);
    const block_bytes = formats.blockSize(image.pixel_format);
    const bpr = desc.src.bytes_per_row;
    const bps = desc.src.bytes_per_slice;
    if (bpr <= 0 or bps <= 0 or @mod(bpr, block_bytes) != 0 or @mod(bps, bpr) != 0) return false;
    if (bpr < formats.rowPitch(image.pixel_format, size.width, 1) or bps < formats.numRows(image.pixel_format, size.height) * bpr) return false;
    if (@mod(desc.dst.x, block) != 0 or @mod(desc.dst.y, block) != 0) return false;
    if (@mod(size.width, block) != 0 and desc.dst.x + size.width != width) return false;
    if (@mod(size.height, block) != 0 and desc.dst.y + size.height != height) return false;
    return true;
}
fn writeImage(comptime transient: bool, descriptor: t.WriteImageDesc) void {
    const name = if (transient) "write_image_transient" else "write_image_unsealed";
    count("num_" ++ name, 1);
    const s = state();
    const entry = s.images.lookup(descriptor.dst.image.id) orelse return;
    if (entry.slot.state != (if (transient) e.ResourceState.valid else e.ResourceState.unsealed)) return;
    if (descriptor.dst.mip_level < 0 or descriptor.dst.mip_level >= entry.descriptor.num_mipmaps) return;
    const desc = defaults.imageTransfer(t.WriteImageDesc, descriptor, entry.descriptor);
    const usage = entry.descriptor.usage;
    var valid = true;
    if (validationEnabled()) {
        valid = validImageTransfer(t.WriteImageDesc, desc, entry.descriptor) and desc.src.data.ptr != null and
            fits(desc.src.offset, @as(usize, @intCast(desc.src.bytes_per_slice)) * @as(usize, @intCast(desc.size.num_slices)), desc.src.data.size) and
            (if (transient) !usage.immutable and usage.write_transient and entry.bind_frame != s.frame_index else usage.immutable and usage.write_unsealed);
    }
    if (valid and transient and entry.write_frame != s.frame_index) {
        entry.write_frame = s.frame_index;
        entry.active_slot = @mod(entry.active_slot + 1, 2);
    }
    if (valid) if (s.gl_backend) |*gl| gl.writeImage(&entry.gl_resource, entry.descriptor, entry.active_slot, desc);
    if (valid) if (s.d3d11_backend) |*dx| dx.writeImage(&entry.d3d11_resource, entry.descriptor, desc);
    trace(name, .{&descriptor});
}
pub fn writeImageTransient(descriptor: t.WriteImageDesc) void {
    writeImage(true, descriptor);
}
pub fn writeImageUnsealed(descriptor: t.WriteImageDesc) void {
    writeImage(false, descriptor);
}
pub fn sealBuffer(handle: t.Buffer) void {
    count("num_seal_buffer", 1);
    const entry = state().buffers.lookup(handle.id) orelse return;
    if (!validationEnabled() or entry.slot.state == .unsealed) entry.slot.state = .valid;
    trace("seal_buffer", .{handle});
}
pub fn sealImage(handle: t.Image) void {
    count("num_seal_image", 1);
    const entry = state().images.lookup(handle.id) orelse return;
    if (!validationEnabled() or entry.slot.state == .unsealed) entry.slot.state = .valid;
    trace("seal_image", .{handle});
}
pub fn copyBufferToBuffer(desc: t.CopyBufferToBufferDesc) void {
    count("num_copy_buffer_to_buffer", 1);
    const s = state();
    const src = s.buffers.lookup(desc.src.buffer.id) orelse return;
    const dst = s.buffers.lookup(desc.dst.buffer.id) orelse return;
    if (src.slot.state != .valid or dst.slot.state != .valid) return;
    src.copy_frame = s.frame_index;
    const valid = !validationEnabled() or (s.current_pass == null and desc.src.buffer.id != desc.dst.buffer.id and src.descriptor.usage.copy_src and dst.descriptor.usage.copy_dst and desc.size > 0 and desc.src.offset % 4 == 0 and desc.dst.offset % 4 == 0 and fits(desc.src.offset, desc.size, src.descriptor.size) and fits(desc.dst.offset, desc.size, dst.descriptor.size));
    if (valid) if (s.gl_backend) |*gl| gl.copyBuffer(&src.gl_resource, &dst.gl_resource, src.descriptor.usage, dst.descriptor.usage, src.active_slot, dst.active_slot, desc);
    if (valid) if (s.d3d11_backend) |*dx| dx.copyBuffer(&src.d3d11_resource, &dst.d3d11_resource, desc);
    if (valid) count("size_copy_buffer_to_buffer", @truncate(desc.size));
    trace("copy_buffer_to_buffer", .{&desc});
}
pub fn copyBufferToImage(descriptor: t.CopyBufferToImageDesc) void {
    count("num_copy_buffer_to_image", 1);
    const s = state();
    const src = s.buffers.lookup(descriptor.src.buffer.id) orelse return;
    const dst = s.images.lookup(descriptor.dst.image.id) orelse return;
    if (src.slot.state != .valid or dst.slot.state != .valid) return;
    if (descriptor.dst.mip_level < 0 or descriptor.dst.mip_level >= dst.descriptor.num_mipmaps) return;
    src.copy_frame = s.frame_index;
    const desc = defaults.imageTransfer(t.CopyBufferToImageDesc, descriptor, dst.descriptor);
    var valid = !validationEnabled();
    if (!valid and validImageTransfer(t.CopyBufferToImageDesc, desc, dst.descriptor)) {
        const size = formats.imageCopySize(dst.descriptor.pixel_format, desc.src.bytes_per_row, desc.src.bytes_per_slice, desc.size.width, desc.size.height, desc.size.num_slices);
        valid = s.current_pass == null and src.descriptor.usage.copy_src and dst.descriptor.usage.copy_dst and !src.descriptor.usage.staging_index_buffer and
            (src.descriptor.usage.staging_buffer or queryFeatures().copy_buffer_to_image_relaxed_buffer_type) and
            (!queryFeatures().separate_buffer_types or !src.descriptor.usage.index_buffer) and
            (src.descriptor.usage.staging_buffer or queryFeatures().copy_buffer_to_image_relaxed_bytes_per_row or @mod(desc.src.bytes_per_row, 256) == 0) and desc.src.offset % @as(usize, @intCast(formats.blockSize(dst.descriptor.pixel_format))) == 0 and fits(desc.src.offset, size, src.descriptor.size);
    }
    if (valid) if (s.gl_backend) |*gl| gl.copyBufferToImage(&src.gl_resource, &dst.gl_resource, src.descriptor.usage, dst.descriptor, src.active_slot, dst.active_slot, desc);
    if (valid) if (s.d3d11_backend) |*dx| dx.copyBufferToImage(&src.d3d11_resource, &dst.d3d11_resource, dst.descriptor, desc);
    if (valid) count("size_copy_buffer_to_image", @truncate(formats.imageCopySize(dst.descriptor.pixel_format, desc.src.bytes_per_row, desc.src.bytes_per_slice, desc.size.width, desc.size.height, desc.size.num_slices)));
    trace("copy_buffer_to_image", .{&descriptor});
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11Device() ?*const anyopaque {
    return if (storage) |*value| (if (value.d3d11_backend) |dx| dx.device else null) else null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11DeviceContext() ?*const anyopaque {
    return if (storage) |*value| (if (value.d3d11_backend) |dx| dx.context else null) else null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11QueryBufferInfo(buf: t.Buffer) t.D3d11BufferInfo {
    if (state().d3d11_backend != null) if (state().buffers.lookup(buf.id)) |entry| return .{ .buf = entry.d3d11_resource.object };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11QueryImageInfo(img: t.Image) t.D3d11ImageInfo {
    if (state().d3d11_backend != null) if (state().images.lookup(img.id)) |entry| return .{ .tex2d = entry.d3d11_resource.texture_2d, .tex3d = entry.d3d11_resource.texture_3d, .res = entry.d3d11_resource.resource };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11QuerySamplerInfo(smp: t.Sampler) t.D3d11SamplerInfo {
    if (state().d3d11_backend != null) if (state().samplers.lookup(smp.id)) |entry| return .{ .smp = entry.d3d11_resource.object };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11QueryShaderInfo(shd: t.Shader) t.D3d11ShaderInfo {
    if (state().d3d11_backend != null) if (state().shaders.lookup(shd.id)) |entry| {
        var result: t.D3d11ShaderInfo = .{ .vs = entry.d3d11_resource.vertex, .fs = entry.d3d11_resource.fragment };
        for (&result.cbufs, entry.d3d11_resource.uniform_buffers) |*target, source| target.* = source;
        return result;
    };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11QueryPipelineInfo(pip: t.Pipeline) t.D3d11PipelineInfo {
    if (state().d3d11_backend != null) if (state().pipelines.lookup(pip.id)) |entry| return .{ .il = entry.d3d11_resource.input_layout, .rs = entry.d3d11_resource.rasterizer, .dss = entry.d3d11_resource.depth_stencil, .bs = entry.d3d11_resource.blend };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn d3d11QueryViewInfo(view: t.View) t.D3d11ViewInfo {
    if (state().d3d11_backend != null) if (state().views.lookup(view.id)) |entry| return .{ .srv = entry.d3d11_resource.srv, .uav = entry.d3d11_resource.uav, .rtv = entry.d3d11_resource.rtv, .dsv = entry.d3d11_resource.dsv };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlDevice() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlRenderCommandEncoder() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlComputeCommandEncoder() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlCommandQueue() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlQueryBufferInfo(buf: t.Buffer) t.MtlBufferInfo {
    _ = state();
    _ = buf;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlQueryImageInfo(img: t.Image) t.MtlImageInfo {
    _ = state();
    _ = img;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlQuerySamplerInfo(smp: t.Sampler) t.MtlSamplerInfo {
    _ = state();
    _ = smp;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlQueryShaderInfo(shd: t.Shader) t.MtlShaderInfo {
    _ = state();
    _ = shd;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn mtlQueryPipelineInfo(pip: t.Pipeline) t.MtlPipelineInfo {
    _ = state();
    _ = pip;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuDevice() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQueue() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuCommandEncoder() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuRenderPassEncoder() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuComputePassEncoder() ?*const anyopaque {
    return null;
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQueryBufferInfo(buf: t.Buffer) t.WgpuBufferInfo {
    _ = state();
    _ = buf;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQueryImageInfo(img: t.Image) t.WgpuImageInfo {
    _ = state();
    _ = img;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQuerySamplerInfo(smp: t.Sampler) t.WgpuSamplerInfo {
    _ = state();
    _ = smp;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQueryShaderInfo(shd: t.Shader) t.WgpuShaderInfo {
    _ = state();
    _ = shd;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQueryPipelineInfo(pip: t.Pipeline) t.WgpuPipelineInfo {
    _ = state();
    _ = pip;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn wgpuQueryViewInfo(view: t.View) t.WgpuViewInfo {
    _ = state();
    _ = view;
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn glQueryBufferInfo(buf: t.Buffer) t.GlBufferInfo {
    if (state().gl_backend != null) if (state().buffers.lookup(buf.id)) |entry| return .{ .buf = entry.gl_resource.ids, .active_slot = entry.active_slot };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn glQueryImageInfo(img: t.Image) t.GlImageInfo {
    if (state().gl_backend != null) if (state().images.lookup(img.id)) |entry| return .{ .tex = entry.gl_resource.ids, .tex_target = entry.gl_resource.target, .active_slot = entry.active_slot };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn glQuerySamplerInfo(smp: t.Sampler) t.GlSamplerInfo {
    if (state().gl_backend != null) if (state().samplers.lookup(smp.id)) |entry| return .{ .smp = entry.gl_resource.id };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn glQueryShaderInfo(shd: t.Shader) t.GlShaderInfo {
    if (state().gl_backend != null) if (state().shaders.lookup(shd.id)) |entry| return .{ .prog = entry.gl_resource.program };
    return .{};
}

/// Native backend query: the dummy backend has no graphics API objects.
pub fn glQueryViewInfo(view: t.View) t.GlViewInfo {
    if (state().gl_backend != null) if (state().views.lookup(view.id)) |entry| return .{ .tex_view = entry.gl_resource.texture_views, .msaa_render_buffer = entry.gl_resource.msaa_renderbuffer, .msaa_resolve_frame_buffer = entry.gl_resource.resolve_framebuffer };
    return .{};
}

fn uninitialize(comptime name: []const u8, id: u32) bool {
    const s = state();
    const pool = &@field(s, name);
    const entry = pool.lookup(id) orelse return false;
    switch (entry.slot.state) {
        .valid, .unsealed, .failed => {},
        else => return false,
    }
    if (s.gl_backend) |*gl| {
        if (comptime std.mem.eql(u8, name, "buffers")) gl.discardBuffer(&entry.gl_resource);
        if (comptime std.mem.eql(u8, name, "images")) gl.discardImage(&entry.gl_resource);
        if (comptime std.mem.eql(u8, name, "samplers")) gl.discardSampler(&entry.gl_resource);
        if (comptime std.mem.eql(u8, name, "shaders")) gl.discardShader(&entry.gl_resource);
        if (comptime std.mem.eql(u8, name, "views")) gl.discardView(&entry.gl_resource);
        if (comptime std.mem.eql(u8, name, "pipelines")) gl.cache.invalidatePipeline(entry.slot);
    }
    if (s.d3d11_backend) |*dx| {
        if (comptime std.mem.eql(u8, name, "buffers")) dx.discardBuffer(&entry.d3d11_resource);
        if (comptime std.mem.eql(u8, name, "images")) dx.discardImage(&entry.d3d11_resource);
        if (comptime std.mem.eql(u8, name, "samplers")) dx.discardSampler(&entry.d3d11_resource);
        if (comptime std.mem.eql(u8, name, "shaders")) dx.discardShader(&entry.d3d11_resource);
        if (comptime std.mem.eql(u8, name, "views")) dx.discardView(&entry.d3d11_resource);
        if (comptime std.mem.eql(u8, name, "pipelines")) dx.discardPipeline(&entry.d3d11_resource);
    }
    return pool.uninit(id);
}
fn nativeBufferBinding(comptime R: type, comptime field: []const u8, entry: *Pool(t.BufferDesc).Entry) R.BufferBinding {
    return .{ .resource = &@field(entry, field), .desc = &entry.descriptor, .active_slot = entry.active_slot };
}
fn nativeImageBinding(comptime R: type, comptime field: []const u8, entry: *Pool(t.ImageDesc).Entry) R.ImageBinding {
    return .{ .resource = &@field(entry, field), .desc = &entry.descriptor, .active_slot = entry.active_slot };
}
fn nativeViewBinding(comptime R: type, comptime field: []const u8, handle: t.View) ?R.ViewBinding {
    const s = state();
    const entry = s.views.lookup(handle.id) orelse return null;
    var binding: R.ViewBinding = .{ .resource = &@field(entry, field), .desc = &entry.descriptor };
    if (viewType(entry.descriptor) == .storagebuffer) {
        const buffer = s.buffers.lookup(entry.dependency_id) orelse return null;
        if (buffer.slot.uninit_count != entry.dependency_uninit_count) return null;
        binding.buffer = nativeBufferBinding(R, field, buffer);
    } else {
        const image = s.images.lookup(entry.dependency_id) orelse return null;
        if (image.slot.uninit_count != entry.dependency_uninit_count) return null;
        binding.image = nativeImageBinding(R, field, image);
    }
    return binding;
}
fn nativeAttachments(comptime R: type, comptime field: []const u8, attachments: t.Attachments) ?R.Attachments {
    var result: R.Attachments = .{};
    var gap = false;
    for (attachments.colors, attachments.resolves, 0..) |color, resolve, i| {
        if (color.id != 0) {
            if (gap) return null;
            result.colors[i] = nativeViewBinding(R, field, color) orelse return null;
            result.num_colors += 1;
        } else gap = true;
        if (resolve.id != 0) result.resolves[i] = nativeViewBinding(R, field, resolve) orelse return null;
    }
    if (attachments.depth_stencil.id != 0) result.depth_stencil = nativeViewBinding(R, field, attachments.depth_stencil) orelse return null;
    if (!result.empty()) {
        const view = result.depth_stencil orelse result.colors[0].?;
        const image = view.image.?;
        const mip = if (view.desc.depth_stencil_attachment.image.id != 0) view.desc.depth_stencil_attachment.mip_level else view.desc.color_attachment.mip_level;
        result.width = formats.mipDimension(image.desc.width, mip);
        result.height = formats.mipDimension(image.desc.height, mip);
    }
    return result;
}
fn useInstanced(desc: t.PipelineDesc) bool {
    for (desc.layout.buffers) |layout| {
        if (layout.step_func == .per_instance) return true;
    }
    return false;
}

fn nativeBindings(comptime R: type, comptime field: []const u8, pipeline: *Pool(t.PipelineDesc).Entry, shader: *Pool(t.ShaderDesc).Entry, bindings: t.Bindings, active: [8]bool) R.Bindings {
    const s = state();
    var resolved: R.Bindings = .{
        .pipeline = .{ .resource = &@field(pipeline, field), .desc = &pipeline.descriptor, .slot = pipeline.slot },
        .shader = .{ .resource = &@field(shader, field), .desc = &shader.descriptor },
        .vertex_offsets = bindings.vertex_buffer_offsets,
        .index_offset = bindings.index_buffer_offset,
    };
    for (active, bindings.vertex_buffers, 0..) |used, handle, i| {
        if (used) if (s.buffers.lookup(handle.id)) |entry| {
            resolved.vertex_buffers[i] = nativeBufferBinding(R, field, entry);
        };
    }
    if (s.buffers.lookup(bindings.index_buffer.id)) |entry| resolved.index_buffer = nativeBufferBinding(R, field, entry);
    for (shader.descriptor.views, bindings.views, 0..) |required, handle, i| {
        if (required.texture.stage != .none or required.storage_buffer.stage != .none or required.storage_image.stage != .none) resolved.views[i] = nativeViewBinding(R, field, handle);
    }
    for (bindings.samplers, 0..) |handle, i| {
        if (s.samplers.lookup(handle.id)) |entry| resolved.samplers[i] = &@field(entry, field);
    }
    return resolved;
}
