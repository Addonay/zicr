//! Native D3D12 resource payloads. Placeholder until the backend is implemented.
const t = @import("../../types.zig");

pub const Buffer = struct {};
pub const Image = struct {};
pub const Sampler = struct {};
pub const Shader = struct {};
pub const Pipeline = struct {};
pub const View = struct {};

pub fn Resource(comptime Desc: type) type {
    if (Desc == t.BufferDesc) return Buffer;
    if (Desc == t.ImageDesc) return Image;
    if (Desc == t.SamplerDesc) return Sampler;
    if (Desc == t.ShaderDesc) return Shader;
    if (Desc == t.PipelineDesc) return Pipeline;
    if (Desc == t.ViewDesc) return View;
    @compileError("unknown resource descriptor");
}
