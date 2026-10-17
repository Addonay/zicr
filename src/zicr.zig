//! zicr: a rendering library for Zig.
//!
//! `gpu` is the low-level layer: a portable, validated abstraction over Vulkan,
//! D3D12, Metal, WebGPU and OpenGL/GLES/WebGL2, derived from sokol_gfx.

pub const gpu = @import("gpu/gpu.zig");
