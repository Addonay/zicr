const std = @import("std");
const e = @import("../../enums.zig");
const c = @import("constants.zig");
const convert = @import("convert.zig");
const caps = @import("capabilities.zig");
const dispatch = @import("dispatch.zig");
const Cache = @import("cache.zig").Cache;

const Mock = struct {
    const Kind = enum { bind_buffer, active_texture, bind_texture, bind_sampler, bind_range, bind_base, use_program };
    const Call = struct { kind: Kind, a: u32, b: u32 };
    var calls: [256]Call = undefined;
    var count: usize = 0;
    fn record(kind: Kind, a: u32, b: u32) void {
        calls[count] = .{ .kind = kind, .a = a, .b = b };
        count += 1;
    }
    fn bindBuffer(target: u32, buffer: u32) callconv(dispatch.call_conv) void {
        record(.bind_buffer, target, buffer);
    }
    fn activeTexture(unit: u32) callconv(dispatch.call_conv) void {
        record(.active_texture, unit, 0);
    }
    fn bindTexture(target: u32, texture: u32) callconv(dispatch.call_conv) void {
        record(.bind_texture, target, texture);
    }
    fn bindSampler(unit: u32, sampler: u32) callconv(dispatch.call_conv) void {
        record(.bind_sampler, unit, sampler);
    }
    fn bindRange(target: u32, binding: u32, buffer: u32, offset: isize, size: isize) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.shader_storage_buffer and offset >= 0 and size > 0);
        record(.bind_range, binding, buffer);
    }
    fn bindBase(target: u32, binding: u32, buffer: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.shader_storage_buffer);
        record(.bind_base, binding, buffer);
    }
    fn useProgram(program: u32) callconv(dispatch.call_conv) void {
        record(.use_program, program, 0);
    }
    fn resolve(name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque {
        std.debug.assert(user_data == null);
        if (std.mem.eql(u8, name, "glBindBuffer")) return @ptrCast(&bindBuffer);
        if (std.mem.eql(u8, name, "glActiveTexture")) return @ptrCast(&activeTexture);
        return null;
    }
    fn cache() Cache {
        count = 0;
        return .{ .driver = .{ .bindBuffer = bindBuffer, .activeTexture = activeTexture, .bindTexture = bindTexture, .bindSampler = bindSampler, .bindBufferRange = bindRange, .bindBufferBase = bindBase, .useProgram = useProgram }, .features = .{ .compute = true }, .limits = .{ .gl_max_combined_texture_image_units = 4, .max_storage_buffer_bindings_per_stage = 4 } };
    }
};

test "GL dispatch resolves exact symbol names and detects missing requirements" {
    const driver = dispatch.Dispatch.load(Mock.resolve, null);
    try std.testing.expect(driver.bindBuffer != null);
    try std.testing.expect(driver.activeTexture != null);
    try std.testing.expect(driver.bindTexture == null);
    try driver.require(.{ "bindBuffer", "activeTexture" });
    try std.testing.expectError(error.MissingOpenGlFunction, driver.require(.{"bindTexture"}));
}

test "GL conversion tables cover integer attributes, compressed formats and normalized values" {
    try std.testing.expectEqual(@as(i32, 4), convert.vertexComponents(.uint10_n2));
    try std.testing.expectEqual(c.unsigned_int_2_10_10_10_rev, convert.vertexType(.uint10_n2));
    try std.testing.expectEqual(@as(u8, 1), convert.vertexNormalized(.uint10_n2));
    try std.testing.expectEqual(@as(u8, 0), convert.vertexNormalized(.uint4));
    try std.testing.expectEqual(c.red_integer, convert.pixelFormat(.r16ui));
    try std.testing.expectEqual(c.unsigned_short, convert.pixelType(.r16ui));
    try std.testing.expectEqual(c.compressed_red_green_rgtc2, convert.pixelInternalFormat(.bc5_rg));
    try std.testing.expectEqual(c.clamp_to_edge, convert.wrap(.clamp_to_border, true));
    try std.testing.expectEqual(c.clamp_to_border, convert.wrap(.clamp_to_border, false));
}

test "GL capability rules distinguish normalized, integer, floating and compressed formats" {
    const desktop = caps.formats(false, true, .{ .s3tc = true });
    const integer = desktop[@backingInt(e.PixelFormat.r8ui)];
    try std.testing.expect(integer.sample and integer.render and integer.msaa and !integer.filter and !integer.blend);
    try std.testing.expect(desktop[@backingInt(e.PixelFormat.r32f)].filter);
    try std.testing.expect(desktop[@backingInt(e.PixelFormat.rgba32f)].read);
    try std.testing.expect(desktop[@backingInt(e.PixelFormat.bc1_rgba)].sample);
    try std.testing.expect(!desktop[@backingInt(e.PixelFormat.bc1_rgba)].render);
    try std.testing.expect(!desktop[@backingInt(e.PixelFormat.bgra8)].sample);
    const es = caps.formats(true, true, .{});
    try std.testing.expect(!es[@backingInt(e.PixelFormat.r16)].sample);
    try std.testing.expect(!es[@backingInt(e.PixelFormat.r32f)].filter);
    try std.testing.expect(!es[@backingInt(e.PixelFormat.r32f)].render);
    try std.testing.expect(es[@backingInt(e.PixelFormat.rgba32f)].read);
    try std.testing.expect(!es[@backingInt(e.PixelFormat.rg32f)].read);
}

test "GL buffer cache avoids redundant binds and invalidates every alias" {
    var cache = Mock.cache();
    cache.bindBuffer(c.array_buffer, 7);
    cache.bindBuffer(c.array_buffer, 7);
    try std.testing.expectEqual(@as(usize, 1), Mock.count);
    cache.restoreBuffer(c.array_buffer, 0);
    try std.testing.expectEqual(@as(u32, 7), cache.buffers[0]);
    cache.bindBuffer(c.element_array_buffer, 7);
    cache.bindStorageBuffer(1, 7, 256, 1024);
    cache.attrs[0].buffer = 7;
    cache.invalidateBuffer(7);
    try std.testing.expectEqual(@as(u32, 0), cache.buffers[0]);
    try std.testing.expectEqual(@as(u32, 0), cache.buffers[1]);
    try std.testing.expectEqual(@as(u32, 0), cache.buffers[2]);
    try std.testing.expectEqual(@as(u32, 0), cache.storage_buffers[1]);
    try std.testing.expectEqual(@as(u32, 0), cache.attrs[0].buffer);
    try std.testing.expectEqual(@as(u32, 7), cache.stats.num_bind_buffer);
}

test "GL texture target changes unbind the old target and restore only nonzero saves" {
    var cache = Mock.cache();
    cache.bindTexture(0, c.texture_2d, 2, 3);
    const saved = cache.textures[0];
    const previous = Mock.count;
    cache.bindTexture(0, c.texture_2d, 2, 3);
    try std.testing.expectEqual(previous, Mock.count);
    cache.bindTexture(0, c.texture_cube_map, 4, 5);
    try std.testing.expectEqual(Mock.Kind.bind_texture, Mock.calls[previous].kind);
    try std.testing.expectEqual(c.texture_2d, Mock.calls[previous].a);
    try std.testing.expectEqual(@as(u32, 0), Mock.calls[previous].b);
    cache.restoreTexture(0, saved);
    try std.testing.expectEqual(saved, cache.textures[0]);
    cache.restoreTexture(0, .{});
    try std.testing.expectEqual(saved, cache.textures[0]);
    cache.invalidateTexture(2, 0);
    try std.testing.expectEqual(@as(u32, 0), cache.textures[0].texture);
    const calls = Mock.count;
    cache.bindTexture(5, c.texture_2d, 8, 9);
    try std.testing.expectEqual(calls, Mock.count);
}

test "GL soft clear leaves unused bindings alone and honors disabled statistics" {
    var cache = Mock.cache();
    cache.bindBuffer(c.array_buffer, 8);
    cache.clearBuffers(false);
    try std.testing.expectEqual(@as(usize, 2), Mock.count);
    cache.stats_enabled = false;
    const before = cache.stats;
    cache.bindTexture(0, c.texture_2d, 11, 12);
    cache.clearTextures(false);
    try std.testing.expectEqual(before, cache.stats);
}

test "all nongeneric GL cache and conversion functions compile" {
    inline for (.{ Cache, convert }) |Namespace| {
        inline for (@typeInfo(Namespace).@"struct".decl_names) |name| {
            const declaration = @field(Namespace, name);
            if (@typeInfo(@TypeOf(declaration)) == .@"fn" and !@typeInfo(@TypeOf(declaration)).@"fn".is_generic) _ = &declaration;
        }
    }
}

test "all native GL resource operations compile without external symbols" {
    const Backend = @import("backend.zig").Backend;
    inline for (@typeInfo(Backend).@"struct".decl_names) |name| {
        const declaration = @field(Backend, name);
        if (@typeInfo(@TypeOf(declaration)) == .@"fn" and !@typeInfo(@TypeOf(declaration)).@"fn".is_generic) _ = &declaration;
    }
}

const ResourceMock = struct {
    const Backend = @import("backend.zig").Backend;
    const t = @import("../../types.zig");
    const r = @import("resources.zig");
    var next_id: u32 = 20;
    var generated: usize = 0;
    var deleted: usize = 0;
    var writes: usize = 0;
    var storage_calls: usize = 0;
    var shader_compiles: usize = 0;
    var shader_deletes: usize = 0;
    var program_deletes: usize = 0;
    var compile_ok: bool = true;
    var link_ok: bool = true;
    var current_program: u32 = 17;
    var framebuffer: u32 = 22;
    var last_offset: isize = 0;
    var last_size: isize = 0;
    var last_lod: f32 = 0;
    var texture_views: usize = 0;

    fn gen(n: i32, ids: ?[*]u32) callconv(dispatch.call_conv) void {
        for (0..@intCast(n)) |i| {
            ids.?[i] = next_id;
            next_id += 1;
            generated += 1;
        }
    }
    fn delete(n: i32, ids: ?[*]const u32) callconv(dispatch.call_conv) void {
        for (0..@intCast(n)) |i| std.debug.assert(ids.?[i] != 0);
        deleted += @intCast(n);
    }
    fn bufferData(target: u32, size: isize, data: ?*const anyopaque, usage: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.array_buffer and size > 0 and data == null and usage != 0);
    }
    fn bufferSubData(target: u32, offset: isize, size: isize, data: ?*const anyopaque) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.array_buffer and data != null);
        last_offset = offset;
        last_size = size;
        writes += 1;
    }
    fn samplerParameteri(sampler: u32, param: u32, value: i32) callconv(dispatch.call_conv) void {
        std.debug.assert(sampler != 0 and param != 0);
        _ = value;
    }
    fn samplerParameterf(sampler: u32, param: u32, value: f32) callconv(dispatch.call_conv) void {
        std.debug.assert(sampler != 0);
        if (param == c.texture_max_lod) last_lod = value;
    }
    fn samplerParameterfv(sampler: u32, param: u32, value: ?[*]const f32) callconv(dispatch.call_conv) void {
        std.debug.assert(sampler != 0 and param == c.texture_border_color and value != null);
    }
    fn textureStorage2D(target: u32, levels: i32, format: u32, w: i32, h: i32) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.texture_2d and levels > 0 and format == c.rgba8 and w > 0 and h > 0);
        storage_calls += 1;
    }
    fn textureSubImage2D(target: u32, mip: i32, x: i32, y: i32, width: i32, height: i32, format: u32, kind: u32, data: ?*const anyopaque) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.texture_2d and mip == 0 and x == 0 and y == 0 and width > 0 and height > 0 and format == c.rgba and kind == c.unsigned_byte and data != null);
        writes += 1;
    }
    fn pixelStorei(param: u32, value: i32) callconv(dispatch.call_conv) void {
        std.debug.assert(param == c.unpack_row_length or param == c.unpack_image_height);
        _ = value;
    }
    fn createShader(stage: u32) callconv(dispatch.call_conv) u32 {
        std.debug.assert(stage == c.vertex_shader or stage == c.fragment_shader or stage == c.compute_shader);
        const id = next_id;
        next_id += 1;
        return id;
    }
    fn createProgram() callconv(dispatch.call_conv) u32 {
        const id = next_id;
        next_id += 1;
        return id;
    }
    fn shaderSource(shader: u32, count: i32, sources: ?[*]const [*:0]const u8, lengths: ?[*]const i32) callconv(dispatch.call_conv) void {
        std.debug.assert(shader != 0 and count == 1 and sources != null and lengths == null);
    }
    fn compileShader(shader: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(shader != 0);
        shader_compiles += 1;
    }
    fn deleteShader(shader: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(shader != 0);
        shader_deletes += 1;
    }
    fn deleteProgram(program: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(program != 0);
        program_deletes += 1;
    }
    fn attachShader(program: u32, shader: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(program != 0 and shader != 0);
    }
    fn linkProgram(program: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(program != 0);
    }
    fn getShaderiv(shader: u32, param: u32, output: ?[*]i32) callconv(dispatch.call_conv) void {
        std.debug.assert(shader != 0);
        output.?[0] = if (param == c.compile_status) @intFromBool(compile_ok) else 0;
    }
    fn getProgramiv(program: u32, param: u32, output: ?[*]i32) callconv(dispatch.call_conv) void {
        std.debug.assert(program != 0);
        output.?[0] = if (param == c.link_status) @intFromBool(link_ok) else 0;
    }
    fn getIntegerv(param: u32, output: ?[*]i32) callconv(dispatch.call_conv) void {
        output.?[0] = @intCast(if (param == c.current_program) current_program else framebuffer);
    }
    fn getUniformLocation(program: u32, name: ?[*:0]const u8) callconv(dispatch.call_conv) i32 {
        std.debug.assert(program != 0 and name != null);
        return if (std.mem.eql(u8, std.mem.span(name.?), "missing")) -1 else 3;
    }
    fn getAttribLocation(program: u32, name: ?[*:0]const u8) callconv(dispatch.call_conv) i32 {
        std.debug.assert(program != 0 and name != null);
        return 3;
    }
    fn useProgram(program: u32) callconv(dispatch.call_conv) void {
        current_program = program;
    }
    fn uniform1i(location: i32, unit: i32) callconv(dispatch.call_conv) void {
        std.debug.assert(location == 3 and unit == 0);
    }
    fn textureView(texture: u32, target: u32, original: u32, format: u32, min_level: u32, levels: u32, min_layer: u32, layers: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(texture != 0 and original != 0 and target == c.texture_2d and format == c.rgba8 and min_level == 0 and levels == 1 and min_layer == 0 and layers == 1);
        texture_views += 1;
    }
    fn bindFramebuffer(target: u32, id: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.framebuffer);
        framebuffer = id;
    }
    fn framebufferTexture2D(target: u32, attachment: u32, texture_target: u32, texture: u32, level: i32) callconv(dispatch.call_conv) void {
        std.debug.assert(target == c.framebuffer and attachment == c.color_attachment0 and texture_target == c.texture_2d and texture != 0 and level == 0);
    }
    fn checkFramebufferStatus(target: u32) callconv(dispatch.call_conv) u32 {
        std.debug.assert(target == c.framebuffer);
        return c.framebuffer_complete;
    }
    fn drawBuffers(count: i32, buffers: ?[*]const u32) callconv(dispatch.call_conv) void {
        std.debug.assert(count == 1 and buffers.?[0] == c.color_attachment0);
    }

    fn backend() Backend {
        next_id = 20;
        generated = 0;
        deleted = 0;
        writes = 0;
        storage_calls = 0;
        shader_compiles = 0;
        shader_deletes = 0;
        program_deletes = 0;
        compile_ok = true;
        link_ok = true;
        current_program = 17;
        framebuffer = 22;
        texture_views = 0;
        last_offset = 0;
        last_size = 0;
        last_lod = 0;
        var cache = Mock.cache();
        cache.limits.max_vertex_attrs = 16;
        const driver = &cache.driver;
        driver.genBuffers = gen;
        driver.deleteBuffers = delete;
        driver.bufferData = bufferData;
        driver.bufferSubData = bufferSubData;
        driver.genSamplers = gen;
        driver.deleteSamplers = delete;
        driver.samplerParameteri = samplerParameteri;
        driver.samplerParameterf = samplerParameterf;
        driver.samplerParameterfv = samplerParameterfv;
        driver.genTextures = gen;
        driver.deleteTextures = delete;
        driver.texStorage2D = textureStorage2D;
        driver.texSubImage2D = textureSubImage2D;
        driver.pixelStorei = pixelStorei;
        driver.createShader = createShader;
        driver.shaderSource = shaderSource;
        driver.compileShader = compileShader;
        driver.getShaderiv = getShaderiv;
        driver.deleteShader = deleteShader;
        driver.createProgram = createProgram;
        driver.attachShader = attachShader;
        driver.linkProgram = linkProgram;
        driver.getProgramiv = getProgramiv;
        driver.deleteProgram = deleteProgram;
        driver.getIntegerv = getIntegerv;
        driver.getUniformLocation = getUniformLocation;
        driver.getAttribLocation = getAttribLocation;
        driver.useProgram = useProgram;
        driver.uniform1i = uniform1i;
        driver.textureView = textureView;
        driver.genFramebuffers = gen;
        driver.deleteFramebuffers = delete;
        driver.bindFramebuffer = bindFramebuffer;
        driver.framebufferTexture2D = framebufferTexture2D;
        driver.checkFramebufferStatus = checkFramebufferStatus;
        driver.drawBuffers = drawBuffers;
        return .{ .allocator = std.testing.allocator, .cache = cache, .logger = .{}, .gles = false, .version = 430, .extensions = .{}, .format_info = caps.formats(false, true, .{}), .immutable_storage = true };
    }
};

test "GL native buffer operations preserve injected ownership and transient slot identities" {
    var backend = ResourceMock.backend();
    var buffer: ResourceMock.r.Buffer = .{};
    const desc: ResourceMock.t.BufferDesc = .{ .size = 16, .usage = .{ .vertex_buffer = true, .write_transient = true } };
    try std.testing.expect(backend.createBuffer(&buffer, desc));
    try std.testing.expect(buffer.ids[0] != 0 and buffer.ids[1] != 0 and buffer.ids[0] != buffer.ids[1]);
    const values = [_]u32{ 1, 2 };
    backend.writeBuffer(&buffer, desc.usage, 1, .{ .src = .{ .data = ResourceMock.t.Range.fromSlice(u32, &values) }, .dst = .{ .offset = 4 }, .size = 8 });
    try std.testing.expectEqual(@as(isize, 4), ResourceMock.last_offset);
    try std.testing.expectEqual(@as(isize, 8), ResourceMock.last_size);
    backend.discardBuffer(&buffer);
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.deleted);
    try std.testing.expect(backend.createBuffer(&buffer, .{ .size = 16, .usage = .{ .vertex_buffer = true }, .gl_buffer = 99 }));
    try std.testing.expectEqual(@as(u32, 99), buffer.ids[0]);
    backend.discardBuffer(&buffer);
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.deleted);
}

test "GL sampler limits LOD and leaves injected samplers owned by their caller" {
    const defaults = @import("../../defaults.zig");
    var backend = ResourceMock.backend();
    var sampler: ResourceMock.r.Sampler = .{};
    try std.testing.expect(backend.createSampler(&sampler, defaults.sampler(.{ .max_lod = 10000 })));
    try std.testing.expectEqual(@as(f32, 1000), ResourceMock.last_lod);
    backend.discardSampler(&sampler);
    try std.testing.expectEqual(@as(usize, 1), ResourceMock.deleted);
    try std.testing.expect(backend.createSampler(&sampler, .{ .gl_sampler = 88 }));
    backend.discardSampler(&sampler);
    try std.testing.expectEqual(@as(usize, 1), ResourceMock.deleted);
}

test "GL images allocate each transient texture and injected images are not deleted" {
    var backend = ResourceMock.backend();
    var image: ResourceMock.r.Image = .{};
    const desc: ResourceMock.t.ImageDesc = .{ .type = .@"2d", .width = 4, .height = 4, .num_slices = 1, .num_mipmaps = 1, .sample_count = 1, .pixel_format = .rgba8, .usage = .{ .write_transient = true } };
    try std.testing.expect(backend.createImage(&image, desc));
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.storage_calls);
    try std.testing.expect(image.ids[0] != image.ids[1]);
    const pixels: [64]u8 = @splat(1);
    backend.writeImage(&image, desc, 1, .{ .src = .{ .data = ResourceMock.t.Range.fromSlice(u8, &pixels), .bytes_per_row = 16, .bytes_per_slice = 64 }, .size = .{ .width = 4, .height = 4, .num_slices = 1 } });
    try std.testing.expectEqual(@as(usize, 1), ResourceMock.writes);
    backend.discardImage(&image);
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.deleted);
    var injected = desc;
    injected.usage = .{};
    injected.gl_texture = 66;
    try std.testing.expect(backend.createImage(&image, injected));
    backend.discardImage(&image);
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.deleted);
}

test "GL shader creation resolves names, deletes temporary shaders and restores the program" {
    var backend = ResourceMock.backend();
    var shader: ResourceMock.r.Shader = .{};
    var desc: ResourceMock.t.ShaderDesc = .{ .vertex_func = .{ .source = "vertex" }, .fragment_func = .{ .source = "fragment" } };
    desc.attrs[0].glsl_name = "position";
    desc.uniform_blocks[0] = .{ .stage = .vertex, .size = 16, .layout = .native };
    desc.uniform_blocks[0].glsl_uniforms[0] = .{ .type = .float4, .array_count = 1, .glsl_name = "color" };
    desc.texture_sampler_pairs[0] = .{ .stage = .fragment, .glsl_name = "texture" };
    try std.testing.expect(backend.createShader(&shader, desc));
    try std.testing.expect(shader.program != 0);
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.shader_deletes);
    try std.testing.expectEqual(@as(u32, 17), ResourceMock.current_program);
    try std.testing.expectEqual(@as(i32, 3), shader.uniform_blocks[0].uniforms[0].location);
    var pipeline: ResourceMock.r.Pipeline = .{};
    var pipeline_desc: ResourceMock.t.PipelineDesc = .{};
    pipeline_desc.layout.attrs[0] = .{ .format = .float3 };
    pipeline_desc.layout.buffers[0] = .{ .stride = 12, .step_func = .per_vertex };
    try std.testing.expect(backend.createPipeline(&pipeline, &shader, pipeline_desc));
    try std.testing.expectEqual(@as(i8, 0), pipeline.attrs[3].buffer_index);
    try std.testing.expect(pipeline.active_vertex_buffers[0]);
    backend.discardShader(&shader);
    try std.testing.expectEqual(@as(usize, 1), ResourceMock.program_deletes);
}

test "GL failed shader compilation and linking delete every created driver object" {
    var backend = ResourceMock.backend();
    var shader: ResourceMock.r.Shader = .{};
    const desc: ResourceMock.t.ShaderDesc = .{ .vertex_func = .{ .source = "vertex" }, .fragment_func = .{ .source = "fragment" } };
    ResourceMock.compile_ok = false;
    try std.testing.expect(!backend.createShader(&shader, desc));
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.shader_deletes);
    try std.testing.expectEqual(@as(usize, 1), ResourceMock.program_deletes);
    ResourceMock.compile_ok = true;
    ResourceMock.link_ok = false;
    try std.testing.expect(!backend.createShader(&shader, desc));
    try std.testing.expectEqual(@as(usize, 4), ResourceMock.shader_deletes);
    try std.testing.expectEqual(@as(usize, 2), ResourceMock.program_deletes);
}

test "GL texture views and resolve framebuffer preserve original framebuffer binding" {
    var backend = ResourceMock.backend();
    backend.cache.features.gl_texture_views = true;
    const image: ResourceMock.r.Image = .{ .target = c.texture_2d, .ids = .{ 9, 0 } };
    const desc: ResourceMock.t.ImageDesc = .{ .type = .@"2d", .width = 4, .height = 4, .pixel_format = .rgba8 };
    var view: ResourceMock.r.View = .{};
    try std.testing.expect(backend.createView(&view, .{ .texture = .{ .image = .{ .id = 1 }, .mip_levels = .{ .count = 1 }, .slices = .{ .count = 1 } } }, &image, desc));
    try std.testing.expectEqual(@as(usize, 1), ResourceMock.texture_views);
    backend.discardView(&view);
    try std.testing.expect(backend.createView(&view, .{ .resolve_attachment = .{ .image = .{ .id = 1 } } }, &image, desc));
    try std.testing.expectEqual(@as(u32, 22), ResourceMock.framebuffer);
    backend.discardView(&view);
}

const CommandMock = struct {
    var barrier_bits: u32 = 0;
    var barrier_calls: usize = 0;
    var draw_kind: u8 = 0;
    var uniforms: usize = 0;
    fn barrier(bits: u32) callconv(dispatch.call_conv) void {
        barrier_bits |= bits;
        barrier_calls += 1;
    }
    fn baseVertex(mode: u32, count: i32, kind: u32, pointer: ?*const anyopaque, base: i32) callconv(dispatch.call_conv) void {
        std.debug.assert(mode == c.triangles and count == 7 and kind == c.unsigned_short and @intFromPtr(pointer.?) == 10 and base == 2);
        draw_kind = 1;
    }
    fn baseInstance(mode: u32, count: i32, kind: u32, pointer: ?*const anyopaque, instances: i32, base: i32, first: u32) callconv(dispatch.call_conv) void {
        std.debug.assert(mode == c.triangles and count == 7 and kind == c.unsigned_short and @intFromPtr(pointer.?) == 10 and instances == 2 and base == 2 and first == 4);
        draw_kind = 2;
    }
    fn uniform4(location: i32, count: i32, values: ?[*]const f32) callconv(dispatch.call_conv) void {
        std.debug.assert(location == 3 and count == 1 and std.mem.eql(f32, values.?[0..4], &.{ 1, 2, 3, 4 }));
        uniforms += 1;
    }
};

test "GL barriers collect every alias before marking storage writers dirty again" {
    const t = ResourceMock.t;
    const r = ResourceMock.r;
    var backend = ResourceMock.backend();
    backend.cache.driver.memoryBarrier = CommandMock.barrier;
    CommandMock.barrier_bits = 0;
    CommandMock.barrier_calls = 0;
    var buffer: r.Buffer = .{ .gpu_dirty = r.Dirty.buffer_all };
    const buffer_desc: t.BufferDesc = .{ .size = 64 };
    const buffer_binding: r.BufferBinding = .{ .resource = &buffer, .desc = &buffer_desc, .active_slot = 0 };
    var view: r.View = .{};
    const view_desc: t.ViewDesc = .{ .storage_buffer = .{ .buffer = .{ .id = 1 } } };
    const view_binding: r.ViewBinding = .{ .resource = &view, .desc = &view_desc, .buffer = buffer_binding };
    var pipeline: r.Pipeline = .{};
    const pipeline_desc: t.PipelineDesc = .{ .compute = true };
    var shader: r.Shader = .{};
    var shader_desc: t.ShaderDesc = .{};
    shader_desc.views[0].storage_buffer = .{ .stage = .compute };
    shader_desc.views[1].storage_buffer = .{ .stage = .compute, .readonly = true };
    var bindings: r.Bindings = .{ .pipeline = .{ .resource = &pipeline, .desc = &pipeline_desc, .slot = .{} }, .shader = .{ .resource = &shader, .desc = &shader_desc } };
    bindings.views[0] = view_binding;
    bindings.views[1] = view_binding;
    backend.barriers(&bindings, null);
    try std.testing.expectEqual(@as(usize, 1), CommandMock.barrier_calls);
    try std.testing.expectEqual(c.shader_storage_barrier_bit, CommandMock.barrier_bits);
    try std.testing.expectEqual(r.Dirty.buffer_all, buffer.gpu_dirty);
    bindings.views = @splat(null);
    bindings.vertex_buffers[0] = buffer_binding;
    backend.barriers(&bindings, null);
    try std.testing.expectEqual(@as(usize, 2), CommandMock.barrier_calls);
    try std.testing.expectEqual(c.shader_storage_barrier_bit | c.vertex_attrib_array_barrier_bit, CommandMock.barrier_bits);
    try std.testing.expectEqual(r.Dirty.index | r.Dirty.storage_buffer, buffer.gpu_dirty);
    backend.cache.features.compute = false;
    backend.barriers(&bindings, null);
    try std.testing.expectEqual(@as(usize, 2), CommandMock.barrier_calls);
}

test "GL draw routes base vertex and instance offsets without truncating index offsets" {
    var backend = ResourceMock.backend();
    backend.cache.features.draw_base_vertex = true;
    backend.cache.features.draw_base_instance = true;
    backend.cache.index_type = c.unsigned_short;
    backend.cache.primitive_type = c.triangles;
    backend.cache.index_offset = 4;
    backend.cache.driver.drawElementsBaseVertex = CommandMock.baseVertex;
    backend.cache.driver.drawElementsInstancedBaseVertexBaseInstance = CommandMock.baseInstance;
    CommandMock.draw_kind = 0;
    backend.draw(false, 3, 7, 1, 2, 0);
    try std.testing.expectEqual(@as(u8, 1), CommandMock.draw_kind);
    backend.draw(true, 3, 7, 2, 2, 4);
    try std.testing.expectEqual(@as(u8, 2), CommandMock.draw_kind);
    backend.cache.features.draw_base_instance = false;
    CommandMock.draw_kind = 0;
    backend.draw(true, 3, 7, 2, 2, 4);
    try std.testing.expectEqual(@as(u8, 0), CommandMock.draw_kind);
}

test "GL uniforms honor layout offsets and skip optimized-out locations" {
    var backend = ResourceMock.backend();
    backend.cache.driver.uniform4fv = CommandMock.uniform4;
    var shader: ResourceMock.r.Shader = .{};
    shader.uniform_blocks[0].count = 2;
    shader.uniform_blocks[0].uniforms[0] = .{ .type = .float4, .count = 1, .location = 3, .offset = 16 };
    shader.uniform_blocks[0].uniforms[1] = .{ .type = .float4, .count = 1, .location = -1, .offset = 0 };
    const values = [_]f32{ 0, 0, 0, 0, 1, 2, 3, 4 };
    CommandMock.uniforms = 0;
    backend.applyUniforms(&shader, 0, ResourceMock.t.Range.fromSlice(f32, &values));
    try std.testing.expectEqual(@as(usize, 1), CommandMock.uniforms);
    try std.testing.expectEqual(@as(u32, 1), backend.cache.stats.num_uniform);
}

test "GL shader validation rejects missing names, padding mismatch and binding collisions" {
    const validation = @import("../../validation.zig");
    const defaults = @import("../../defaults.zig");
    var desc: ResourceMock.t.ShaderDesc = .{ .vertex_func = .{ .source = "vertex" }, .fragment_func = .{ .source = "fragment" } };
    desc.uniform_blocks[0] = .{ .stage = .vertex, .size = 16, .layout = .std140 };
    desc.uniform_blocks[0].glsl_uniforms[0] = .{ .type = .float3 };
    desc = defaults.shader(desc, .glcore);
    try std.testing.expect(!validation.glShader(desc, .{}));
    desc.uniform_blocks[0].glsl_uniforms[0].glsl_name = "value";
    try std.testing.expect(validation.glShader(desc, .{}));
    desc.uniform_blocks[0].size = 12;
    try std.testing.expect(!validation.glShader(desc, .{}));
    desc.uniform_blocks[0].size = 16;
    desc.views[0].storage_buffer = .{ .stage = .vertex, .readonly = true };
    desc.views[1].storage_buffer = .{ .stage = .fragment, .readonly = true };
    try std.testing.expect(!validation.glShader(desc, .{}));
    desc.views[1].storage_buffer.glsl_binding_n = 1;
    try std.testing.expect(validation.glShader(desc, .{}));
}
