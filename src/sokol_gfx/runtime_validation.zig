//! State-dependent command checks from sokol_gfx.h:25932-26182.
const t = @import("types.zig");
const e = @import("enums.zig");
const Check = @import("validation.zig").Check;

fn imageValid(s: anytype, view: anytype) ?@TypeOf(&s.images.entries[0]) {
    const image = s.images.lookup(view.dependency_id) orelse return null;
    return if (image.slot.uninit_count == view.dependency_uninit_count and image.slot.state == .valid) image else null;
}
fn bufferValid(s: anytype, view: anytype) ?@TypeOf(&s.buffers.entries[0]) {
    const buffer = s.buffers.lookup(view.dependency_id) orelse return null;
    return if (buffer.slot.uninit_count == view.dependency_uninit_count and buffer.slot.state == .valid) buffer else null;
}
fn kind(desc: t.ViewDesc) e.ViewType {
    if (desc.texture.image.id != 0) return .texture;
    if (desc.storage_buffer.buffer.id != 0) return .storagebuffer;
    if (desc.storage_image.image.id != 0) return .storageimage;
    if (desc.color_attachment.image.id != 0) return .colorattachment;
    if (desc.resolve_attachment.image.id != 0) return .resolveattachment;
    if (desc.depth_stencil_attachment.image.id != 0) return .depthstencilattachment;
    return .invalid;
}

pub fn bindings(s: anytype, value: t.Bindings, active: [8]bool, query_format: anytype) bool {
    var check: Check = .{ .logger = s.desc.logger };
    s.write_buffer_transient_missing = false;
    s.write_image_transient_missing = false;
    check.require(s.current_pass != null, .validate_abnd_pass_expected);
    var any = value.index_buffer.id != 0;
    for (value.vertex_buffers) |buffer| any = any or buffer.id != 0;
    for (value.views) |view| any = any or view.id != 0;
    for (value.samplers) |sampler| any = any or sampler.id != 0;
    check.require(any, .validate_abnd_empty_bindings);
    check.require(s.current_pipeline.id != 0, .validate_abnd_no_pipeline);
    const maybe_pipeline = s.pipelines.lookup(s.current_pipeline.id);
    const alive = if (maybe_pipeline) |pipeline| pipeline.slot.uninit_count == s.pipeline_uninit_count else false;
    check.require(alive, .validate_abnd_pipeline_alive);
    if (!alive) return false;
    const pipeline = maybe_pipeline.?;
    check.require(pipeline.slot.state == .valid, .validate_abnd_pipeline_valid);
    const maybe_shader = s.shaders.lookup(pipeline.dependency_id);
    const shader_alive = if (maybe_shader) |shader| shader.slot.uninit_count == pipeline.dependency_uninit_count else false;
    check.require(shader_alive, .validate_abnd_pipeline_shader_alive);
    if (!shader_alive) return false;
    const shader = maybe_shader.?;
    check.require(shader.slot.state == .valid, .validate_abnd_pipeline_shader_valid);
    const pass = s.current_pass orelse return false;
    if (pass.compute) {
        for (value.vertex_buffers) |buffer| check.require(buffer.id == 0, .validate_abnd_compute_expected_no_vbufs);
        check.require(value.index_buffer.id == 0, .validate_abnd_compute_expected_no_ibuf);
    } else {
        for (active, value.vertex_buffers) |used, handle| {
            if (!used) continue;
            check.require(handle.id != 0, .validate_abnd_expected_vbuf);
            if (handle.id == 0) continue;
            const maybe_buffer = s.buffers.lookup(handle.id);
            check.require(maybe_buffer != null, .validate_abnd_vbuf_alive);
            if (maybe_buffer) |buffer| {
                if (buffer.slot.state != .valid) continue;
                buffer.bind_frame = s.frame_index;
                buffer.read_pass = s.pass_index;
                check.require(buffer.descriptor.usage.vertex_buffer, .validate_abnd_vbuf_usage);
                check.require(buffer.write_pass != s.pass_index, .validate_abnd_vbuf_vs_sbview_readwrite);
                if (buffer.descriptor.usage.write_transient) s.write_buffer_transient_missing = s.write_buffer_transient_missing or buffer.write_frame != s.frame_index;
            }
        }
        check.require(if (pipeline.descriptor.index_type == .none) value.index_buffer.id == 0 else value.index_buffer.id != 0, if (pipeline.descriptor.index_type == .none) .validate_abnd_expected_no_ibuf else .validate_abnd_expected_ibuf);
        if (value.index_buffer.id != 0) {
            const maybe_buffer = s.buffers.lookup(value.index_buffer.id);
            check.require(maybe_buffer != null, .validate_abnd_ibuf_alive);
            if (maybe_buffer) |buffer| {
                if (buffer.slot.state == .valid) {
                    buffer.bind_frame = s.frame_index;
                    buffer.read_pass = s.pass_index;
                    check.require(buffer.descriptor.usage.index_buffer, .validate_abnd_ibuf_usage);
                    check.require(buffer.write_pass != s.pass_index, .validate_abnd_ibuf_vs_sbview_readwrite);
                    if (buffer.descriptor.usage.write_transient) s.write_buffer_transient_missing = s.write_buffer_transient_missing or buffer.write_frame != s.frame_index;
                }
            }
        }
    }
    for (shader.descriptor.views, value.views) |required, handle| {
        const expected: e.ViewType = if (required.texture.stage != .none) .texture else if (required.storage_buffer.stage != .none) .storagebuffer else if (required.storage_image.stage != .none) .storageimage else .invalid;
        if (expected == .invalid) continue;
        check.require(handle.id != 0, .validate_abnd_expected_view_binding);
        if (handle.id == 0) continue;
        const maybe_view = s.views.lookup(handle.id);
        check.require(maybe_view != null, .validate_abnd_view_alive);
        const view = maybe_view orelse continue;
        // Failed/unsealed referenced resources are allowed and skip the draw
        // in the resolver. Do not turn asynchronous setup into validation errors.
        if (view.slot.state != .valid) continue;
        check.require(kind(view.descriptor) == expected, switch (expected) {
            .texture => .validate_abnd_expect_texview,
            .storagebuffer => .validate_abnd_expect_sbview,
            .storageimage => .validate_abnd_expect_simgview,
            else => unreachable,
        });
        if (kind(view.descriptor) != expected) continue;
        if (expected == .storagebuffer) {
            const buffer = bufferValid(s, view) orelse continue;
            buffer.bind_frame = s.frame_index;
            if (required.storage_buffer.readonly) {
                buffer.read_pass = s.pass_index;
                check.require(pass.compute or buffer.write_pass != s.pass_index, .validate_abnd_sbview_readonly_vs_readwrite);
            } else {
                buffer.write_pass = s.pass_index;
                check.require(pass.compute or buffer.read_pass != s.pass_index, .validate_abnd_sbview_readwrite_vs_read);
                check.require(!buffer.descriptor.usage.write_transient, .validate_abnd_sbview_readwrite_vs_writetransient);
            }
            if (buffer.descriptor.usage.write_transient) s.write_buffer_transient_missing = s.write_buffer_transient_missing or buffer.write_frame != s.frame_index;
        } else {
            const image = imageValid(s, view) orelse continue;
            image.bind_frame = s.frame_index;
            const desc = image.descriptor;
            if (expected == .texture) {
                check.require(desc.type == required.texture.image_type, .validate_abnd_texview_imagetype_mismatch);
                check.require(if (required.texture.multisampled) desc.sample_count > 1 else desc.sample_count == 1, if (required.texture.multisampled) .validate_abnd_texview_expected_multisampled_image else .validate_abnd_texview_expected_non_multisampled_image);
                const info = query_format(desc.pixel_format);
                if (required.texture.sample_type == .float) check.require(info.filter, .validate_abnd_texview_expected_filterable_image);
                if (required.texture.sample_type == .depth) check.require(info.depth, .validate_abnd_texview_expected_depth_image);
            } else {
                check.require(pass.compute, .validate_abnd_simgview_compute_pass_expected);
                check.require(desc.type == required.storage_image.image_type, .validate_abnd_simgview_imagetype_mismatch);
                check.require(desc.pixel_format == required.storage_image.access_format, .validate_abnd_simgview_accessformat);
            }
            if (desc.usage.write_transient) s.write_image_transient_missing = s.write_image_transient_missing or image.write_frame != s.frame_index;
        }
    }
    for (shader.descriptor.samplers, value.samplers) |required, handle| {
        if (required.stage == .none) continue;
        check.require(handle.id != 0, .validate_abnd_expected_sampler_binding);
        if (handle.id == 0) continue;
        const maybe_sampler = s.samplers.lookup(handle.id);
        check.require(maybe_sampler != null, .validate_abnd_sampler_alive);
        if (maybe_sampler) |sampler| {
            check.require(sampler.slot.state == .valid, .validate_abnd_sampler_valid);
            check.require(if (required.sampler_type == .comparison) sampler.descriptor.compare != .never else sampler.descriptor.compare == .never, if (required.sampler_type == .comparison) .validate_abnd_unexpected_sampler_compare_never else .validate_abnd_expected_sampler_compare_never);
            if (required.sampler_type == .nonfiltering) check.require(sampler.descriptor.min_filter != .linear and sampler.descriptor.mag_filter != .linear and sampler.descriptor.mipmap_filter != .linear, .validate_abnd_expected_nonfiltering_sampler);
        }
    }
    for (shader.descriptor.views, value.views) |required, handle| {
        if (required.texture.stage == .none or handle.id == 0) continue;
        const view = s.views.lookup(handle.id) orelse continue;
        const id = view.dependency_id;
        if (!@import("defaults.zig").attachmentsEmpty(pass.attachments)) {
            if (s.views.lookup(pass.attachments.depth_stencil.id)) |attachment| check.require(id != attachment.dependency_id, .validate_abnd_texture_binding_vs_depthstencil_attachment);
            for (pass.attachments.colors, pass.attachments.resolves) |color, resolved| {
                if (s.views.lookup(color.id)) |attachment| check.require(id != attachment.dependency_id, .validate_abnd_texture_binding_vs_color_attachment);
                if (s.views.lookup(resolved.id)) |attachment| check.require(id != attachment.dependency_id, .validate_abnd_texture_binding_vs_resolve_attachment);
            }
        }
        for (shader.descriptor.views, value.views) |other, other_handle| {
            if (other.storage_image.stage == .none or other_handle.id == 0) continue;
            if (s.views.lookup(other_handle.id)) |storage_view| check.require(id != storage_view.dependency_id, .validate_abnd_texture_vs_storageimage_binding);
        }
    }
    return check.valid;
}
