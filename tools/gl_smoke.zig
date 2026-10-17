//! Native offscreen GL/GLES verification. Uses EGL through runtime-loaded
//! function pointers; the library itself has no C imports or C compilation.
const std = @import("std");
const gfx = @import("zicr").gpu.raw;

const Egl = struct {
    library: std.DynLib,
    get_platform_display: *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque,
    initialize: *const fn (?*anyopaque, ?*i32, ?*i32) callconv(.c) u32,
    choose_config: *const fn (?*anyopaque, ?[*]const i32, ?[*]?*anyopaque, i32, ?*i32) callconv(.c) u32,
    bind_api: *const fn (u32) callconv(.c) u32,
    create_context: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque,
    create_surface: *const fn (?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque,
    make_current: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) u32,
    destroy_context: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u32,
    destroy_surface: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) u32,
    terminate: *const fn (?*anyopaque) callconv(.c) u32,
    get_proc: *const fn ([*:0]const u8) callconv(.c) ?*const anyopaque,

    fn open() !Egl {
        var library = try std.DynLib.open("libEGL.so.1");
        errdefer library.close();
        var result: Egl = undefined;
        result.library = library;
        const names = .{
            .{ "get_platform_display", "eglGetPlatformDisplay" }, .{ "initialize", "eglInitialize" },
            .{ "choose_config", "eglChooseConfig" },              .{ "bind_api", "eglBindAPI" },
            .{ "create_context", "eglCreateContext" },            .{ "create_surface", "eglCreatePbufferSurface" },
            .{ "make_current", "eglMakeCurrent" },                .{ "destroy_context", "eglDestroyContext" },
            .{ "destroy_surface", "eglDestroySurface" },          .{ "terminate", "eglTerminate" },
            .{ "get_proc", "eglGetProcAddress" },
        };
        inline for (names) |entry| @field(result, entry[0]) = library.lookup(@TypeOf(@field(result, entry[0])), entry[1]) orelse return error.MissingEglFunction;
        return result;
    }
};
const Loader = struct {
    egl: *Egl,
    gl: *std.DynLib,
    fn resolve(name: [:0]const u8, context: ?*anyopaque) ?*const anyopaque {
        const self: *Loader = @ptrCast(@alignCast(context.?));
        return self.egl.get_proc(name.ptr) orelse self.gl.lookup(*const anyopaque, name);
    }
    fn function(self: *Loader, comptime T: type, name: [:0]const u8) !T {
        return @ptrCast(@alignCast(resolve(name, self) orelse return error.MissingGlFunction));
    }
};
fn logger(_: ?[*:0]const u8, level: u32, item: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    std.debug.print("GL log level={d} item={d}: {s}\n", .{ level, item, if (message) |value| std.mem.span(value) else "" });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const legacy = args.len > 1 and std.mem.eql(u8, args[1], "--legacy");
    var egl = try Egl.open();
    defer egl.library.close();
    const display = egl.get_platform_display(0x31DD, null, null) orelse return error.NoSurfacelessEglDisplay;
    var major: i32 = 0;
    var minor: i32 = 0;
    if (egl.initialize(display, &major, &minor) == 0) return error.EglInitializationFailed;
    defer _ = egl.terminate(display);
    std.debug.print("EGL {d}.{d}\n", .{ major, minor });
    try run(&egl, display, .glcore, legacy);
    try run(&egl, display, .gles3, legacy);
}

fn run(egl: *Egl, display: *anyopaque, backend: gfx.Backend, legacy: bool) !void {
    const es = backend == .gles3;
    var gl = try std.DynLib.open(if (es) "libGLESv2.so.2" else "libGL.so.1");
    defer gl.close();
    const none = 0x3038;
    const config_attributes = [_]i32{
        0x3033, 1, // EGL_SURFACE_TYPE, EGL_PBUFFER_BIT
        0x3040, if (es) 0x40 else 8, // EGL_RENDERABLE_TYPE, ES3/OpenGL
        0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, // RGBA
        none,
    };
    var config: ?*anyopaque = null;
    var count: i32 = 0;
    if (egl.choose_config(display, &config_attributes, @ptrCast(&config), 1, &count) == 0 or count < 1) return error.NoEglConfig;
    if (egl.bind_api(if (es) 0x30A0 else 0x30A2) == 0) return error.EglBindApiFailed;
    const context_attributes = if (es) [_]i32{ 0x3098, 3, 0x30FB, if (legacy) 0 else 1, none, none, none } else [_]i32{ 0x3098, if (legacy) 3 else 4, 0x30FB, 3, 0x30FD, 1, none };
    const context = egl.create_context(display, config, null, &context_attributes) orelse return error.EglContextCreationFailed;
    defer _ = egl.destroy_context(display, context);
    const surface_attributes = [_]i32{ 0x3057, 64, 0x3056, 64, none };
    const surface = egl.create_surface(display, config, &surface_attributes) orelse return error.EglSurfaceCreationFailed;
    defer _ = egl.destroy_surface(display, surface);
    if (egl.make_current(display, surface, surface, context) == 0) return error.EglMakeCurrentFailed;
    defer _ = egl.make_current(display, null, null, null);
    var loader: Loader = .{ .egl = egl, .gl = &gl };
    const get_error = try loader.function(*const fn () callconv(.c) u32, "glGetError");
    const get_string = try loader.function(*const fn (u32) callconv(.c) ?[*:0]const u8, "glGetString");
    std.debug.print("{s}: {s}\n", .{ @tagName(backend), std.mem.span(get_string(0x1F02).?) });
    try gfx.setup(std.heap.page_allocator, backend, .{
        .environment = .{ .gl = .{ .get_proc_address = Loader.resolve, .user_data = &loader }, .defaults = .{ .depth_format = .none } },
        .logger = .{ .func = logger },
    });
    defer gfx.shutdown();
    if (get_error() != 0) return error.GlSetupError;
    const image = gfx.makeImage(.{ .width = 64, .height = 64, .usage = .{ .color_attachment = true } });
    if (gfx.queryImageState(image) != .valid) return error.ImageCreationFailed;
    const view = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    if (gfx.queryViewState(view) != .valid) return error.ViewCreationFailed;
    const vertex = if (es)
        "#version 300 es\nvoid main(){ vec2 p[3]=vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); gl_Position=vec4(p[gl_VertexID],0,1); }"
    else
        "#version 330 core\nvoid main(){ vec2 p[3]=vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); gl_Position=vec4(p[gl_VertexID],0,1); }";
    const fragment = if (es)
        "#version 300 es\nprecision highp float; uniform vec4 color; out vec4 result; void main(){ result=color; }"
    else
        "#version 330 core\nuniform vec4 color; out vec4 result; void main(){ result=color; }";
    var shader_desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    shader_desc.uniform_blocks[0] = .{ .stage = .fragment, .size = 16 };
    shader_desc.uniform_blocks[0].glsl_uniforms[0] = .{ .type = .float4, .glsl_name = "color" };
    const shader = gfx.makeShader(shader_desc);
    if (gfx.queryShaderState(shader) != .valid) return error.ShaderCreationFailed;
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none } });
    if (gfx.queryPipelineState(pipeline) != .valid) return error.PipelineCreationFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = view;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    const color = [_]f32{ 0.25, 0.5, 0.75, 1 };
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &color));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    const read_pixels = try loader.function(*const fn (i32, i32, i32, i32, u32, u32, ?*anyopaque) callconv(.c) void, "glReadPixels");
    var pixel: [4]u8 = undefined;
    read_pixels(32, 32, 1, 1, 0x1908, 0x1401, &pixel);
    if (get_error() != 0) return error.GlRenderingError;
    const expected = [_]i32{ 64, 128, 191, 255 };
    for (pixel, expected) |value, want| {
        if (@abs(@as(i32, value) - want) > 1) {
            std.debug.print("unexpected pixel: {any}\n", .{pixel});
            return error.PixelMismatch;
        }
    }
    gfx.commit();
    const stats = gfx.queryStats();
    if (stats.prev_frame.num_draw != 1 or stats.prev_frame.gl.num_uniform != 1 or stats.prev_frame.gl.num_use_program != 1) return error.FrameStatsMismatch;
    std.debug.print("{s}: native triangle pixel {any}, no GL errors\n", .{ @tagName(backend), pixel });
    try indexed(&loader, es, view);
    try textureCopy(&loader, es, view, vertex);
    try multisample(&loader, shader);
    if (gfx.queryFeatures().compute) {
        try compute(&loader, es);
        try computeRender(&loader, es, view, vertex);
    }
    if (get_error() != 0) return error.GlPostChecksError;
}

fn checkPixel(loader: *Loader, expected: [4]i32) !void {
    const read_pixels = try loader.function(*const fn (i32, i32, i32, i32, u32, u32, ?*anyopaque) callconv(.c) void, "glReadPixels");
    const get_error = try loader.function(*const fn () callconv(.c) u32, "glGetError");
    var pixel: [4]u8 = undefined;
    read_pixels(32, 32, 1, 1, 0x1908, 0x1401, &pixel);
    const gl_error = get_error();
    if (gl_error != 0) {
        std.debug.print("readback GL error: 0x{x}\n", .{gl_error});
        return error.GlReadbackError;
    }
    for (pixel, expected) |value, want| {
        if (@abs(@as(i32, value) - want) > 1) {
            std.debug.print("readback mismatch {any}, expected {any}\n", .{ pixel, expected });
            return error.PixelMismatch;
        }
    }
}

fn indexed(loader: *Loader, es: bool, target: gfx.View) !void {
    const positions = [_][2]f32{ .{ 0, 0 }, .{ -1, -1 }, .{ 3, -1 }, .{ -1, 3 } };
    const indices = [_]u16{ 0, 1, 2 };
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice([2]f32, &positions) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &indices) });
    if (gfx.queryBufferState(vb) != .valid or gfx.queryBufferState(ib) != .valid) return error.BufferCreationFailed;
    const vertex = if (es) "#version 300 es\nin vec2 position; void main(){gl_Position=vec4(position,0,1);}" else "#version 330 core\nin vec2 position; void main(){gl_Position=vec4(position,0,1);}";
    const fragment = if (es) "#version 300 es\nprecision highp float; out vec4 result; void main(){result=vec4(1,0,0,1);}" else "#version 330 core\nout vec4 result; void main(){result=vec4(1,0,0,1);}";
    var desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    desc.attrs[0].glsl_name = "position";
    const shader = gfx.makeShader(desc);
    if (gfx.queryShaderState(shader) != .valid) return error.IndexedShaderFailed;
    var pipeline_desc: gfx.PipelineDesc = .{ .shader = shader, .index_type = .uint16, .depth = .{ .pixel_format = .none } };
    pipeline_desc.layout.attrs[0] = .{ .format = .float2 };
    const pipeline = gfx.makePipeline(pipeline_desc);
    if (gfx.queryPipelineState(pipeline) != .valid) return error.IndexedPipelineFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = target;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{ .index_buffer = ib };
    bindings.vertex_buffers[0] = vb;
    bindings.vertex_buffer_offsets[0] = 8;
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 2);
    gfx.endPass();
    try checkPixel(loader, .{ 255, 0, 0, 255 });
    if (gfx.queryFeatures().draw_base_vertex) {
        gfx.beginPass(pass);
        gfx.applyPipeline(pipeline);
        bindings.vertex_buffer_offsets[0] = 0;
        gfx.applyBindings(bindings);
        gfx.drawEx(0, 3, 2, 1, 0);
        gfx.endPass();
        try checkPixel(loader, .{ 255, 0, 0, 255 });
    }
    gfx.commit();
    std.debug.print("  indexed and instanced vertex-buffer rendering passed\n", .{});
}

fn textureCopy(loader: *Loader, es: bool, target: gfx.View, vertex: [*:0]const u8) !void {
    const pixels: [16][4]u8 = @splat(.{ 23, 47, 89, 255 });
    const staging = gfx.makeBuffer(.{ .size = @sizeOf(@TypeOf(pixels)), .usage = .{ .staging_buffer = true, .copy_src = true, .write_transient = true } });
    if (gfx.queryBufferState(staging) != .valid) return error.StagingBufferFailed;
    gfx.writeBufferTransient(.{ .src = .{ .data = gfx.Range.fromSlice([4]u8, &pixels) }, .dst = .{ .buffer = staging } });
    const image = gfx.makeImage(.{ .width = 4, .height = 4, .usage = .{ .copy_dst = true } });
    if (gfx.queryImageState(image) != .valid) return error.SampleImageFailed;
    gfx.copyBufferToImage(.{ .src = .{ .buffer = staging }, .dst = .{ .image = image } });
    const view = gfx.makeView(.{ .texture = .{ .image = image } });
    const sampler = gfx.makeSampler(.{});
    if (gfx.queryViewState(view) != .valid or gfx.querySamplerState(sampler) != .valid) return error.TextureBindingCreationFailed;
    const fragment = if (es) "#version 300 es\nprecision highp float; uniform sampler2D source_texture; out vec4 result; void main(){result=texture(source_texture,vec2(0.5));}" else "#version 330 core\nuniform sampler2D source_texture; out vec4 result; void main(){result=texture(source_texture,vec2(0.5));}";
    var desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    desc.views[0].texture = .{ .stage = .fragment };
    desc.samplers[0] = .{ .stage = .fragment };
    desc.texture_sampler_pairs[0] = .{ .stage = .fragment, .glsl_name = "source_texture" };
    const shader = gfx.makeShader(desc);
    if (gfx.queryShaderState(shader) != .valid) return error.TextureShaderFailed;
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none } });
    if (gfx.queryPipelineState(pipeline) != .valid) return error.TexturePipelineFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = target;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = view;
    bindings.samplers[0] = sampler;
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try checkPixel(loader, .{ 23, 47, 89, 255 });
    gfx.commit();
    std.debug.print("  transient staging upload, buffer-to-image copy and texture sampling passed\n", .{});
}

fn multisample(loader: *Loader, shader: gfx.Shader) !void {
    const image = gfx.makeImage(.{ .width = 64, .height = 64, .sample_count = 4, .usage = .{ .color_attachment = true } });
    const resolved = gfx.makeImage(.{ .width = 64, .height = 64, .usage = .{ .resolve_attachment = true } });
    if (gfx.queryImageState(image) != .valid or gfx.queryImageState(resolved) != .valid) return error.MsaaImageFailed;
    const color = gfx.makeView(.{ .color_attachment = .{ .image = image } });
    const resolve = gfx.makeView(.{ .resolve_attachment = .{ .image = resolved } });
    if (gfx.queryViewState(color) != .valid or gfx.queryViewState(resolve) != .valid) return error.MsaaViewFailed;
    const pipeline = gfx.makePipeline(.{ .shader = shader, .depth = .{ .pixel_format = .none }, .sample_count = 4 });
    if (gfx.queryPipelineState(pipeline) != .valid) return error.MsaaPipelineFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = color;
    pass.attachments.resolves[0] = resolve;
    gfx.beginPass(pass);
    gfx.applyPipeline(pipeline);
    const uniform = [_]f32{ 0.25, 0.5, 0.75, 1 };
    gfx.applyUniforms(0, gfx.Range.fromSlice(f32, &uniform));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    const bind_fb = try loader.function(*const fn (u32, u32) callconv(.c) void, "glBindFramebuffer");
    bind_fb(0x8CA8, gfx.glQueryViewInfo(resolve).msaa_resolve_frame_buffer);
    try checkPixel(loader, .{ 64, 128, 191, 255 });
    gfx.resetStateCache();
    gfx.commit();
    std.debug.print("  multisample rendering and framebuffer resolve passed\n", .{});
}

fn compute(loader: *Loader, es: bool) !void {
    const buffer = gfx.makeBuffer(.{ .size = 16, .usage = .{ .storage_buffer = true, .copy_src = true } });
    const copy = gfx.makeBuffer(.{ .size = 16, .usage = .{ .copy_dst = true } });
    if (gfx.queryBufferState(buffer) != .valid or gfx.queryBufferState(copy) != .valid) return error.ComputeBufferFailed;
    const view = gfx.makeView(.{ .storage_buffer = .{ .buffer = buffer } });
    if (gfx.queryViewState(view) != .valid) return error.ComputeViewFailed;
    const source = if (es) "#version 310 es\nprecision highp int; layout(local_size_x=1) in; layout(std430,binding=0) buffer Data {uint values[];}; void main(){ uint i=gl_GlobalInvocationID.x; values[i]=100u+3u*i; }" else "#version 430 core\nlayout(local_size_x=1) in; layout(std430,binding=0) buffer Data {uint values[];}; void main(){ uint i=gl_GlobalInvocationID.x; values[i]=100u+3u*i; }";
    var desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = source } };
    desc.views[0].storage_buffer = .{ .stage = .compute };
    const shader = gfx.makeShader(desc);
    if (gfx.queryShaderState(shader) != .valid) return error.ComputeShaderFailed;
    const pipeline = gfx.makePipeline(.{ .shader = shader, .compute = true });
    if (gfx.queryPipelineState(pipeline) != .valid) return error.ComputePipelineFailed;
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(pipeline);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = view;
    gfx.applyBindings(bindings);
    gfx.dispatch(4, 1, 1);
    gfx.endPass();
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = buffer }, .dst = .{ .buffer = copy }, .size = 16 });
    const bind_buffer = try loader.function(*const fn (u32, u32) callconv(.c) void, "glBindBuffer");
    const map_buffer = try loader.function(*const fn (u32, isize, isize, u32) callconv(.c) ?*anyopaque, "glMapBufferRange");
    const unmap_buffer = try loader.function(*const fn (u32) callconv(.c) u8, "glUnmapBuffer");
    bind_buffer(0x8F36, gfx.glQueryBufferInfo(copy).buf[0]);
    const mapped = map_buffer(0x8F36, 0, 16, 1) orelse return error.ComputeReadbackMapFailed;
    var values: [4]u32 = undefined;
    @memcpy(std.mem.asBytes(&values), @as([*]const u8, @ptrCast(mapped))[0..16]);
    if (unmap_buffer(0x8F36) == 0) return error.ComputeReadbackUnmapFailed;
    bind_buffer(0x8F36, 0);
    if (!std.mem.eql(u32, &values, &.{ 100, 103, 106, 109 })) {
        std.debug.print("compute readback mismatch: {any}\n", .{values});
        return error.ComputeReadbackMismatch;
    }
    gfx.resetStateCache();
    gfx.commit();
    std.debug.print("  compute dispatch, storage buffer and GPU copy readback {any} passed\n", .{values});
}

fn computeRender(loader: *Loader, es: bool, target: gfx.View, fullscreen_vertex: [*:0]const u8) !void {
    const positions = gfx.makeBuffer(.{ .size = 24, .usage = .{ .storage_buffer = true, .vertex_buffer = true } });
    const storage = gfx.makeView(.{ .storage_buffer = .{ .buffer = positions } });
    const compute_source = if (es)
        "#version 310 es\nprecision highp float; layout(local_size_x=1) in; layout(std430,binding=0) buffer Points {vec2 points[];}; void main(){ uint i=gl_GlobalInvocationID.x; vec2 p[3]=vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); points[i]=p[i]; }"
    else
        "#version 430 core\nlayout(local_size_x=1) in; layout(std430,binding=0) buffer Points {vec2 points[];}; void main(){ uint i=gl_GlobalInvocationID.x; vec2 p[3]=vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3)); points[i]=p[i]; }";
    var compute_desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = compute_source } };
    compute_desc.views[0].storage_buffer = .{ .stage = .compute };
    const compute_shader = gfx.makeShader(compute_desc);
    const compute_pipeline = gfx.makePipeline(.{ .shader = compute_shader, .compute = true });
    if (gfx.queryViewState(storage) != .valid or gfx.queryPipelineState(compute_pipeline) != .valid) return error.ComputeVertexSetupFailed;
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(compute_pipeline);
    var compute_bindings: gfx.Bindings = .{};
    compute_bindings.views[0] = storage;
    gfx.applyBindings(compute_bindings);
    gfx.dispatch(3, 1, 1);
    gfx.endPass();
    const vertex = if (es) "#version 300 es\nin vec2 position; void main(){gl_Position=vec4(position,0,1);}" else "#version 330 core\nin vec2 position; void main(){gl_Position=vec4(position,0,1);}";
    const fragment = if (es) "#version 300 es\nprecision highp float; out vec4 result; void main(){result=vec4(0,1,0,1);}" else "#version 330 core\nout vec4 result; void main(){result=vec4(0,1,0,1);}";
    var render_desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = vertex }, .fragment_func = .{ .source = fragment } };
    render_desc.attrs[0].glsl_name = "position";
    const render_shader = gfx.makeShader(render_desc);
    var render_pipeline_desc: gfx.PipelineDesc = .{ .shader = render_shader, .depth = .{ .pixel_format = .none } };
    render_pipeline_desc.layout.attrs[0].format = .float2;
    const render_pipeline = gfx.makePipeline(render_pipeline_desc);
    if (gfx.queryPipelineState(render_pipeline) != .valid) return error.ComputeVertexRenderPipelineFailed;
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = target;
    gfx.beginPass(pass);
    gfx.applyPipeline(render_pipeline);
    var render_bindings: gfx.Bindings = .{};
    render_bindings.vertex_buffers[0] = positions;
    gfx.applyBindings(render_bindings);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try checkPixel(loader, .{ 0, 255, 0, 255 });
    gfx.commit();
    if (gfx.queryStats().prev_frame.gl.num_memory_barriers < 1) return error.MissingVertexBarrier;

    const image = gfx.makeImage(.{ .width = 4, .height = 4, .usage = .{ .storage_image = true } });
    const storage_image = gfx.makeView(.{ .storage_image = .{ .image = image } });
    const image_source = if (es)
        "#version 310 es\nprecision highp float; layout(local_size_x=1,local_size_y=1) in; layout(rgba8,binding=0) writeonly uniform highp image2D output_image; void main(){imageStore(output_image,ivec2(gl_GlobalInvocationID.xy),vec4(17,34,68,255)/255.0); }"
    else
        "#version 430 core\nlayout(local_size_x=1,local_size_y=1) in; layout(rgba8,binding=0) writeonly uniform image2D output_image; void main(){imageStore(output_image,ivec2(gl_GlobalInvocationID.xy),vec4(17,34,68,255)/255.0); }";
    var image_shader_desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = image_source } };
    image_shader_desc.views[0].storage_image = .{ .stage = .compute, .access_format = .rgba8, .writeonly = true };
    const image_shader = gfx.makeShader(image_shader_desc);
    const image_pipeline = gfx.makePipeline(.{ .shader = image_shader, .compute = true });
    if (gfx.queryViewState(storage_image) != .valid or gfx.queryPipelineState(image_pipeline) != .valid) return error.ComputeImageSetupFailed;
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(image_pipeline);
    compute_bindings = .{};
    compute_bindings.views[0] = storage_image;
    gfx.applyBindings(compute_bindings);
    gfx.dispatch(4, 4, 1);
    gfx.endPass();
    const texture_view = gfx.makeView(.{ .texture = .{ .image = image } });
    const sampler = gfx.makeSampler(.{});
    const sample_source = if (es) "#version 300 es\nprecision highp float; uniform sampler2D source_texture; out vec4 result; void main(){result=texture(source_texture,vec2(0.5));}" else "#version 330 core\nuniform sampler2D source_texture; out vec4 result; void main(){result=texture(source_texture,vec2(0.5));}";
    var sample_desc: gfx.ShaderDesc = .{ .vertex_func = .{ .source = fullscreen_vertex }, .fragment_func = .{ .source = sample_source } };
    sample_desc.views[0].texture = .{ .stage = .fragment };
    sample_desc.samplers[0] = .{ .stage = .fragment };
    sample_desc.texture_sampler_pairs[0] = .{ .stage = .fragment, .glsl_name = "source_texture" };
    const sample_shader = gfx.makeShader(sample_desc);
    const sample_pipeline = gfx.makePipeline(.{ .shader = sample_shader, .depth = .{ .pixel_format = .none } });
    if (gfx.queryViewState(texture_view) != .valid or gfx.querySamplerState(sampler) != .valid or gfx.queryPipelineState(sample_pipeline) != .valid) return error.ComputeImageSampleSetupFailed;
    gfx.beginPass(pass);
    gfx.applyPipeline(sample_pipeline);
    render_bindings = .{};
    render_bindings.views[0] = texture_view;
    render_bindings.samplers[0] = sampler;
    gfx.applyBindings(render_bindings);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    try checkPixel(loader, .{ 17, 34, 68, 255 });
    gfx.commit();
    if (gfx.queryStats().prev_frame.gl.num_memory_barriers < 1) return error.MissingTextureBarrier;
    std.debug.print("  compute-to-vertex and storage-image-to-texture rendering barriers passed\n", .{});
}
