//! Native WebGPU verification. Creates a wgpu-native instance, adapter and device from the
//! library named by WGPU_NATIVE_LIB, runs sokol_gfx on that device and checks exact pixel and
//! buffer values read back with plain webgpu calls.
//!
//! The webgpu.h declarations below are generated from the pinned header (see the comments on
//! each block); every function is resolved at runtime through wgpuGetProcAddress.
//!
//! Run with: WGPU_NATIVE_LIB=/path/to/libwgpu_native.so zig build test-wgpu
const std = @import("std");
const gfx = @import("zicr").gpu.raw;

pub const ChainedStruct = extern struct {
    next: ?*const ChainedStruct = null,
    s_type: SType = @fromBackingInt(@intCast(0)),
};

pub const Adapter = *opaque {};
pub const BindGroupLayout = *opaque {};
pub const Buffer = *opaque {};
pub const CommandBuffer = *opaque {};
pub const CommandEncoder = *opaque {};
pub const Device = *opaque {};
pub const Instance = *opaque {};
pub const Queue = *opaque {};
pub const Sampler = *opaque {};
pub const ShaderModule = *opaque {};
pub const Surface = *opaque {};
pub const Texture = *opaque {};
pub const TextureView = *opaque {};
pub const BufferUsage = struct {
    pub const none: u64 = 0x0;
    pub const map_read: u64 = 0x1;
    pub const map_write: u64 = 0x2;
    pub const copy_src: u64 = 0x4;
    pub const copy_dst: u64 = 0x8;
    pub const index: u64 = 0x10;
    pub const vertex: u64 = 0x20;
    pub const uniform: u64 = 0x40;
    pub const storage: u64 = 0x80;
    pub const indirect: u64 = 0x100;
    pub const query_resolve: u64 = 0x200;
};

pub const MapMode = struct {
    pub const none: u64 = 0x0;
    pub const read: u64 = 0x1;
    pub const write: u64 = 0x2;
};

pub const ShaderStage = struct {
    pub const none: u64 = 0x0;
    pub const vertex: u64 = 0x1;
    pub const fragment: u64 = 0x2;
    pub const compute: u64 = 0x4;
};

pub const TextureUsage = struct {
    pub const none: u64 = 0x0;
    pub const copy_src: u64 = 0x1;
    pub const copy_dst: u64 = 0x2;
    pub const texture_binding: u64 = 0x4;
    pub const storage_binding: u64 = 0x8;
    pub const render_attachment: u64 = 0x10;
    pub const transient_attachment: u64 = 0x20;
};

pub const AdapterType = enum(u32) {
    discrete_gpu = 1,
    integrated_gpu = 2,
    cpu = 3,
    unknown = 4,
    _,
};

pub const AddressMode = enum(u32) {
    undefined = 0,
    clamp_to_edge = 1,
    repeat = 2,
    mirror_repeat = 3,
    _,
};

pub const BackendType = enum(u32) {
    undefined = 0,
    null = 1,
    web_gpu = 2,
    d3_d11 = 3,
    d3_d12 = 4,
    metal = 5,
    vulkan = 6,
    open_gl = 7,
    open_gles = 8,
    _,
};

pub const BufferBindingType = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    uniform = 2,
    storage = 3,
    read_only_storage = 4,
    _,
};

pub const CompareFunction = enum(u32) {
    undefined = 0,
    never = 1,
    less = 2,
    equal = 3,
    less_equal = 4,
    greater = 5,
    not_equal = 6,
    greater_equal = 7,
    always = 8,
    _,
};

pub const FeatureLevel = enum(u32) {
    undefined = 0,
    compatibility = 1,
    core = 2,
    _,
};

pub const FeatureName = enum(u32) {
    core_features_and_limits = 1,
    depth_clip_control = 2,
    depth32_float_stencil8 = 3,
    texture_compression_bc = 4,
    texture_compression_bc_sliced3_d = 5,
    texture_compression_etc2 = 6,
    texture_compression_astc = 7,
    texture_compression_astc_sliced3_d = 8,
    timestamp_query = 9,
    indirect_first_instance = 10,
    shader_f16 = 11,
    rg11_b10_ufloat_renderable = 12,
    bgra8_unorm_storage = 13,
    float32_filterable = 14,
    float32_blendable = 15,
    clip_distances = 16,
    dual_source_blending = 17,
    subgroups = 18,
    texture_formats_tier1 = 19,
    texture_formats_tier2 = 20,
    primitive_index = 21,
    texture_component_swizzle = 22,
    _,
};

pub const FilterMode = enum(u32) {
    undefined = 0,
    nearest = 1,
    linear = 2,
    _,
};

pub const InstanceFeatureName = enum(u32) {
    timed_wait_any = 1,
    shader_source_spirv = 2,
    multiple_devices_per_adapter = 3,
    _,
};

pub const MipmapFilterMode = enum(u32) {
    undefined = 0,
    nearest = 1,
    linear = 2,
    _,
};

pub const PowerPreference = enum(u32) {
    undefined = 0,
    low_power = 1,
    high_performance = 2,
    _,
};

pub const SType = enum(u32) {
    shader_source_spirv = 1,
    shader_source_wgsl = 2,
    render_pass_max_draw_count = 3,
    surface_source_metal_layer = 4,
    surface_source_windows_hwnd = 5,
    surface_source_xlib_window = 6,
    surface_source_wayland_surface = 7,
    surface_source_android_native_window = 8,
    surface_source_xcb_window = 9,
    surface_color_management = 10,
    request_adapter_web_xr_options = 11,
    texture_component_swizzle_descriptor = 12,
    external_texture_binding_layout = 13,
    external_texture_binding_entry = 14,
    compatibility_mode_limits = 15,
    texture_binding_view_dimension = 16,
    _,
};

pub const SamplerBindingType = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    filtering = 2,
    non_filtering = 3,
    comparison = 4,
    _,
};

pub const Status = enum(u32) {
    success = 1,
    @"error" = 2,
    _,
};

pub const StorageTextureAccess = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    write_only = 2,
    read_only = 3,
    read_write = 4,
    _,
};

pub const TextureAspect = enum(u32) {
    undefined = 0,
    all = 1,
    stencil_only = 2,
    depth_only = 3,
    _,
};

pub const TextureDimension = enum(u32) {
    undefined = 0,
    @"1_d" = 1,
    @"2_d" = 2,
    @"3_d" = 3,
    _,
};

pub const TextureFormat = enum(u32) {
    undefined = 0,
    r8_unorm = 1,
    r8_snorm = 2,
    r8_uint = 3,
    r8_sint = 4,
    r16_unorm = 5,
    r16_snorm = 6,
    r16_uint = 7,
    r16_sint = 8,
    r16_float = 9,
    rg8_unorm = 10,
    rg8_snorm = 11,
    rg8_uint = 12,
    rg8_sint = 13,
    r32_float = 14,
    r32_uint = 15,
    r32_sint = 16,
    rg16_unorm = 17,
    rg16_snorm = 18,
    rg16_uint = 19,
    rg16_sint = 20,
    rg16_float = 21,
    rgba8_unorm = 22,
    rgba8_unorm_srgb = 23,
    rgba8_snorm = 24,
    rgba8_uint = 25,
    rgba8_sint = 26,
    bgra8_unorm = 27,
    bgra8_unorm_srgb = 28,
    rgb10_a2_uint = 29,
    rgb10_a2_unorm = 30,
    rg11_b10_ufloat = 31,
    rgb9_e5_ufloat = 32,
    rg32_float = 33,
    rg32_uint = 34,
    rg32_sint = 35,
    rgba16_unorm = 36,
    rgba16_snorm = 37,
    rgba16_uint = 38,
    rgba16_sint = 39,
    rgba16_float = 40,
    rgba32_float = 41,
    rgba32_uint = 42,
    rgba32_sint = 43,
    stencil8 = 44,
    depth16_unorm = 45,
    depth24_plus = 46,
    depth24_plus_stencil8 = 47,
    depth32_float = 48,
    depth32_float_stencil8 = 49,
    bc1_rgba_unorm = 50,
    bc1_rgba_unorm_srgb = 51,
    bc2_rgba_unorm = 52,
    bc2_rgba_unorm_srgb = 53,
    bc3_rgba_unorm = 54,
    bc3_rgba_unorm_srgb = 55,
    bc4_r_unorm = 56,
    bc4_r_snorm = 57,
    bc5_rg_unorm = 58,
    bc5_rg_snorm = 59,
    bc6_hrgb_ufloat = 60,
    bc6_hrgb_float = 61,
    bc7_rgba_unorm = 62,
    bc7_rgba_unorm_srgb = 63,
    etc2_rgb8_unorm = 64,
    etc2_rgb8_unorm_srgb = 65,
    etc2_rgb8_a1_unorm = 66,
    etc2_rgb8_a1_unorm_srgb = 67,
    etc2_rgba8_unorm = 68,
    etc2_rgba8_unorm_srgb = 69,
    eacr11_unorm = 70,
    eacr11_snorm = 71,
    eacrg11_unorm = 72,
    eacrg11_snorm = 73,
    astc4x4_unorm = 74,
    astc4x4_unorm_srgb = 75,
    astc5x4_unorm = 76,
    astc5x4_unorm_srgb = 77,
    astc5x5_unorm = 78,
    astc5x5_unorm_srgb = 79,
    astc6x5_unorm = 80,
    astc6x5_unorm_srgb = 81,
    astc6x6_unorm = 82,
    astc6x6_unorm_srgb = 83,
    astc8x5_unorm = 84,
    astc8x5_unorm_srgb = 85,
    astc8x6_unorm = 86,
    astc8x6_unorm_srgb = 87,
    astc8x8_unorm = 88,
    astc8x8_unorm_srgb = 89,
    astc10x5_unorm = 90,
    astc10x5_unorm_srgb = 91,
    astc10x6_unorm = 92,
    astc10x6_unorm_srgb = 93,
    astc10x8_unorm = 94,
    astc10x8_unorm_srgb = 95,
    astc10x10_unorm = 96,
    astc10x10_unorm_srgb = 97,
    astc12x10_unorm = 98,
    astc12x10_unorm_srgb = 99,
    astc12x12_unorm = 100,
    astc12x12_unorm_srgb = 101,
    _,
};

pub const TextureSampleType = enum(u32) {
    binding_not_used = 0,
    undefined = 1,
    float = 2,
    unfilterable_float = 3,
    depth = 4,
    sint = 5,
    uint = 6,
    _,
};

pub const TextureViewDimension = enum(u32) {
    undefined = 0,
    @"1_d" = 1,
    @"2_d" = 2,
    @"2_d_array" = 3,
    cube = 4,
    cube_array = 5,
    @"3_d" = 6,
    _,
};

pub const AdapterInfo = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    vendor: StringView = .{},
    architecture: StringView = .{},
    device: StringView = .{},
    description: StringView = .{},
    backend_type: BackendType = @fromBackingInt(@intCast(0)),
    adapter_type: AdapterType = @fromBackingInt(@intCast(0)),
    vendor_id: u32 = 0,
    device_id: u32 = 0,
    subgroup_min_size: u32 = 0,
    subgroup_max_size: u32 = 0,
};

pub const BindGroupLayoutDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    entry_count: usize = 0,
    entries: ?*const BindGroupLayoutEntry = null,
};

pub const BindGroupLayoutEntry = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    binding: u32 = 0,
    visibility: u64 = 0,
    binding_array_size: u32 = 0,
    buffer: BufferBindingLayout = .{},
    sampler: SamplerBindingLayout = .{},
    texture: TextureBindingLayout = .{},
    storage_texture: StorageTextureBindingLayout = .{},
};

pub const BufferBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    type: BufferBindingType = @fromBackingInt(@intCast(0)),
    has_dynamic_offset: u32 = 0,
    min_binding_size: u64 = 0,
};

pub const BufferDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    usage: u64 = 0,
    size: u64 = 0,
    mapped_at_creation: u32 = 0,
};

pub const Color = extern struct {
    r: f64 = 0,
    g: f64 = 0,
    b: f64 = 0,
    a: f64 = 0,
};

pub const CommandBufferDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const CommandEncoderDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const Extent3D = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    depth_or_array_layers: u32 = 0,
};

pub const Future = extern struct {
    id: u64 = 0,
};

pub const InstanceDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    required_feature_count: usize = 0,
    required_features: ?*const InstanceFeatureName = null,
    required_limits: ?*const InstanceLimits = null,
};

pub const InstanceLimits = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    timed_wait_any_max_count: usize = 0,
};

pub const Limits = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    max_texture_dimension1_d: u32 = 0,
    max_texture_dimension2_d: u32 = 0,
    max_texture_dimension3_d: u32 = 0,
    max_texture_array_layers: u32 = 0,
    max_bind_groups: u32 = 0,
    max_bind_groups_plus_vertex_buffers: u32 = 0,
    max_bindings_per_bind_group: u32 = 0,
    max_dynamic_uniform_buffers_per_pipeline_layout: u32 = 0,
    max_dynamic_storage_buffers_per_pipeline_layout: u32 = 0,
    max_sampled_textures_per_shader_stage: u32 = 0,
    max_samplers_per_shader_stage: u32 = 0,
    max_storage_buffers_per_shader_stage: u32 = 0,
    max_storage_textures_per_shader_stage: u32 = 0,
    max_uniform_buffers_per_shader_stage: u32 = 0,
    max_uniform_buffer_binding_size: u64 = 0,
    max_storage_buffer_binding_size: u64 = 0,
    min_uniform_buffer_offset_alignment: u32 = 0,
    min_storage_buffer_offset_alignment: u32 = 0,
    max_vertex_buffers: u32 = 0,
    max_buffer_size: u64 = 0,
    max_vertex_attributes: u32 = 0,
    max_vertex_buffer_array_stride: u32 = 0,
    max_inter_stage_shader_variables: u32 = 0,
    max_color_attachments: u32 = 0,
    max_color_attachment_bytes_per_sample: u32 = 0,
    max_compute_workgroup_storage_size: u32 = 0,
    max_compute_invocations_per_workgroup: u32 = 0,
    max_compute_workgroup_size_x: u32 = 0,
    max_compute_workgroup_size_y: u32 = 0,
    max_compute_workgroup_size_z: u32 = 0,
    max_compute_workgroups_per_dimension: u32 = 0,
    max_immediate_size: u32 = 0,
};

pub const Origin3D = extern struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

pub const QueueDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const RequestAdapterOptions = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    feature_level: FeatureLevel = @fromBackingInt(@intCast(0)),
    power_preference: PowerPreference = @fromBackingInt(@intCast(0)),
    force_fallback_adapter: u32 = 0,
    backend_type: BackendType = @fromBackingInt(@intCast(0)),
    compatible_surface: ?Surface = null,
};

pub const SamplerBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    type: SamplerBindingType = @fromBackingInt(@intCast(0)),
};

pub const SamplerDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    address_mode_u: AddressMode = @fromBackingInt(@intCast(0)),
    address_mode_v: AddressMode = @fromBackingInt(@intCast(0)),
    address_mode_w: AddressMode = @fromBackingInt(@intCast(0)),
    mag_filter: FilterMode = @fromBackingInt(@intCast(0)),
    min_filter: FilterMode = @fromBackingInt(@intCast(0)),
    mipmap_filter: MipmapFilterMode = @fromBackingInt(@intCast(0)),
    lod_min_clamp: f32 = 0,
    lod_max_clamp: f32 = 0,
    compare: CompareFunction = @fromBackingInt(@intCast(0)),
    max_anisotropy: u16 = 0,
};

pub const ShaderModuleDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
};

pub const ShaderSourceWGSL = extern struct {
    chain: ChainedStruct = .{},
    code: StringView = .{},
};

pub const StorageTextureBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    access: StorageTextureAccess = @fromBackingInt(@intCast(0)),
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    view_dimension: TextureViewDimension = @fromBackingInt(@intCast(0)),
};

pub const StringView = extern struct {
    data: ?[*]const u8 = null,
    length: usize = 0,
};

pub const TexelCopyBufferInfo = extern struct {
    layout: TexelCopyBufferLayout = .{},
    buffer: ?Buffer = null,
};

pub const TexelCopyBufferLayout = extern struct {
    offset: u64 = 0,
    bytes_per_row: u32 = 0,
    rows_per_image: u32 = 0,
};

pub const TexelCopyTextureInfo = extern struct {
    texture: ?Texture = null,
    mip_level: u32 = 0,
    origin: Origin3D = .{},
    aspect: TextureAspect = @fromBackingInt(@intCast(0)),
};

pub const TextureBindingLayout = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    sample_type: TextureSampleType = @fromBackingInt(@intCast(0)),
    view_dimension: TextureViewDimension = @fromBackingInt(@intCast(0)),
    multisampled: u32 = 0,
};

pub const TextureDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    usage: u64 = 0,
    dimension: TextureDimension = @fromBackingInt(@intCast(0)),
    size: Extent3D = .{},
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    mip_level_count: u32 = 0,
    sample_count: u32 = 0,
    view_format_count: usize = 0,
    view_formats: ?*const TextureFormat = null,
};

pub const TextureViewDescriptor = extern struct {
    next_in_chain: ?*ChainedStruct = null,
    label: StringView = .{},
    format: TextureFormat = @fromBackingInt(@intCast(0)),
    dimension: TextureViewDimension = @fromBackingInt(@intCast(0)),
    base_mip_level: u32 = 0,
    mip_level_count: u32 = 0,
    base_array_layer: u32 = 0,
    array_layer_count: u32 = 0,
    aspect: TextureAspect = @fromBackingInt(@intCast(0)),
    usage: u64 = 0,
};

pub const Procs = struct {
    wgpuAdapterGetInfo: *const fn (?Adapter, ?*AdapterInfo) callconv(.c) Status,
    wgpuAdapterRelease: *const fn (?Adapter) callconv(.c) void,
    wgpuAdapterRequestDevice: *const fn (?Adapter, ?*const DeviceDescriptor, RequestDeviceCallbackInfo) callconv(.c) Future,
    wgpuBindGroupLayoutRelease: *const fn (?BindGroupLayout) callconv(.c) void,
    wgpuBufferGetConstMappedRange: *const fn (?Buffer, usize, usize) callconv(.c) ?*anyopaque,
    wgpuBufferMapAsync: *const fn (?Buffer, u64, usize, usize, BufferMapCallbackInfo) callconv(.c) Future,
    wgpuBufferRelease: *const fn (?Buffer) callconv(.c) void,
    wgpuBufferUnmap: *const fn (?Buffer) callconv(.c) void,
    wgpuCommandBufferRelease: *const fn (?CommandBuffer) callconv(.c) void,
    wgpuCommandEncoderCopyBufferToBuffer: *const fn (?CommandEncoder, ?Buffer, u64, ?Buffer, u64, u64) callconv(.c) void,
    wgpuCommandEncoderCopyTextureToBuffer: *const fn (?CommandEncoder, ?*const TexelCopyTextureInfo, ?*const TexelCopyBufferInfo, ?*const Extent3D) callconv(.c) void,
    wgpuCommandEncoderFinish: *const fn (?CommandEncoder, ?*const CommandBufferDescriptor) callconv(.c) ?CommandBuffer,
    wgpuCommandEncoderRelease: *const fn (?CommandEncoder) callconv(.c) void,
    wgpuCreateInstance: *const fn (?*const InstanceDescriptor) callconv(.c) ?Instance,
    wgpuDeviceCreateBindGroupLayout: *const fn (?Device, ?*const BindGroupLayoutDescriptor) callconv(.c) ?BindGroupLayout,
    wgpuDeviceCreateBuffer: *const fn (?Device, ?*const BufferDescriptor) callconv(.c) ?Buffer,
    wgpuDeviceCreateCommandEncoder: *const fn (?Device, ?*const CommandEncoderDescriptor) callconv(.c) ?CommandEncoder,
    wgpuDeviceCreateSampler: *const fn (?Device, ?*const SamplerDescriptor) callconv(.c) ?Sampler,
    wgpuDeviceCreateShaderModule: *const fn (?Device, ?*const ShaderModuleDescriptor) callconv(.c) ?ShaderModule,
    wgpuDeviceCreateTexture: *const fn (?Device, ?*const TextureDescriptor) callconv(.c) ?Texture,
    wgpuDeviceGetQueue: *const fn (?Device) callconv(.c) ?Queue,
    wgpuDeviceRelease: *const fn (?Device) callconv(.c) void,
    wgpuInstanceProcessEvents: *const fn (?Instance) callconv(.c) void,
    wgpuInstanceRelease: *const fn (?Instance) callconv(.c) void,
    wgpuInstanceRequestAdapter: *const fn (?Instance, ?*const RequestAdapterOptions, RequestAdapterCallbackInfo) callconv(.c) Future,
    wgpuQueueRelease: *const fn (?Queue) callconv(.c) void,
    wgpuQueueSubmit: *const fn (?Queue, usize, ?*const ?CommandBuffer) callconv(.c) void,
    wgpuSamplerRelease: *const fn (?Sampler) callconv(.c) void,
    wgpuShaderModuleRelease: *const fn (?ShaderModule) callconv(.c) void,
    wgpuTextureAddRef: *const fn (?Texture) callconv(.c) void,
    wgpuTextureCreateView: *const fn (?Texture, ?*const TextureViewDescriptor) callconv(.c) ?TextureView,
    wgpuTextureRelease: *const fn (?Texture) callconv(.c) void,
    wgpuTextureViewRelease: *const fn (?TextureView) callconv(.c) void,
};

/// Resolves every function of `Procs` by its webgpu.h name.
pub fn loadProcs(get_proc_address: *const fn (name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque, user_data: ?*anyopaque) error{WgpuInitFailed}!Procs {
    var procs: Procs = undefined;
    inline for (@typeInfo(Procs).@"struct".field_names) |name| {
        const address = get_proc_address(name, user_data) orelse return error.WgpuInitFailed;
        @field(procs, name) = @ptrCast(address);
    }
    return procs;
}

// ---- hand-written declarations: callback types cannot be generated (layouts follow webgpu.h)

pub const UncapturedErrorCallback = *const fn (device: ?*const anyopaque, error_type: u32, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
pub const DeviceLostCallback = *const fn (device: ?*const anyopaque, reason: u32, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
pub const RequestAdapterCallback = *const fn (status: u32, adapter: ?Adapter, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
pub const RequestDeviceCallback = *const fn (status: u32, device: ?Device, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;
pub const BufferMapCallback = *const fn (status: u32, message: StringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void;

pub const UncapturedErrorCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    callback: ?UncapturedErrorCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
pub const DeviceLostCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?DeviceLostCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
pub const DeviceDescriptor = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    label: StringView = .{},
    required_feature_count: usize = 0,
    required_features: ?[*]const FeatureName = null,
    required_limits: ?*const Limits = null,
    default_queue: QueueDescriptor = .{},
    device_lost_callback_info: DeviceLostCallbackInfo = .{},
    uncaptured_error_callback_info: UncapturedErrorCallbackInfo = .{},
};
pub const RequestAdapterCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?RequestAdapterCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
pub const RequestDeviceCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?RequestDeviceCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};
pub const BufferMapCallbackInfo = extern struct {
    next_in_chain: ?*const ChainedStruct = null,
    mode: u32 = 0,
    callback: ?BufferMapCallback = null,
    userdata1: ?*anyopaque = null,
    userdata2: ?*anyopaque = null,
};

const callback_mode_allow_process_events: u32 = 2;
const map_mode_read: u64 = 1;
const max_spins: usize = 1 << 28;

/// Resolves webgpu.h names with dlsym on the loaded library. wgpu-native v29.0.1.1 exports
/// wgpuGetProcAddress only as a stub that aborts, so it cannot be used as the loader.
const Resolver = struct {
    library: *std.DynLib,

    fn resolve(name: [:0]const u8, user_data: ?*anyopaque) ?*const anyopaque {
        const self: *Resolver = @ptrCast(@alignCast(user_data.?));
        return self.library.lookup(*const anyopaque, name);
    }
};

var logged_errors: usize = 0;
var uncaptured_errors: usize = 0;

fn messageText(message: StringView) []const u8 {
    const data = message.data orelse return "";
    return data[0..message.length];
}

fn onUncapturedError(_: ?*const anyopaque, error_type: u32, message: StringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    uncaptured_errors += 1;
    std.debug.print("wgpu validation error type={d}: {s}\n", .{ error_type, messageText(message) });
}

fn onDeviceLost(_: ?*const anyopaque, reason: u32, message: StringView, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    uncaptured_errors += 1;
    std.debug.print("wgpu device lost reason={d}: {s}\n", .{ reason, messageText(message) });
}

fn logger(_: ?[*:0]const u8, level: u32, item: u32, message: ?[*:0]const u8, _: u32, _: ?[*:0]const u8, _: ?*anyopaque) void {
    if (level <= 1) logged_errors += 1;
    std.debug.print("sokol log level={d} item={d}: {s}\n", .{ level, item, if (message) |text| std.mem.span(text) else "" });
}

const Waiter = struct {
    done: bool = false,
    status: u32 = 0,
    adapter: ?Adapter = null,
    device: ?Device = null,
    mapped: bool = false,
};

fn onAdapter(status: u32, adapter: ?Adapter, _: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const waiter: *Waiter = @ptrCast(@alignCast(userdata1.?));
    waiter.status = status;
    waiter.adapter = adapter;
    waiter.done = true;
}

fn onDevice(status: u32, device: ?Device, _: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const waiter: *Waiter = @ptrCast(@alignCast(userdata1.?));
    waiter.status = status;
    waiter.device = device;
    waiter.done = true;
}

fn onMap(status: u32, _: StringView, userdata1: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    const waiter: *Waiter = @ptrCast(@alignCast(userdata1.?));
    waiter.status = status;
    waiter.mapped = status == 1;
    waiter.done = true;
}

/// Pumps the instance until the callback of `waiter` has run.
fn pumpUntil(instance: Instance, procs: *const Procs, waiter: *const Waiter) !void {
    var spins: usize = 0;
    while (!waiter.done) : (spins += 1) {
        if (spins > max_spins) return error.WgpuTimeout;
        procs.wgpuInstanceProcessEvents(instance);
    }
}

const Ctx = struct {
    procs: Procs,
    instance: Instance,
    device: Device,
    queue: Queue,

    fn waitFor(self: *const Ctx, waiter: *const Waiter) !void {
        try pumpUntil(self.instance, &self.procs, waiter);
    }

    /// Copies a texture into a mappable buffer with plain webgpu calls and returns the bytes.
    fn readTexture(self: *const Ctx, tex: Texture, out: []u8) !void {
        const readback = self.readbackBuffer(out.len);
        defer self.procs.wgpuBufferRelease(readback);
        const enc = self.procs.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return error.EncoderFailed;
        defer self.procs.wgpuCommandEncoderRelease(enc);
        const src: TexelCopyTextureInfo = .{ .texture = tex, .aspect = .all };
        const dst: TexelCopyBufferInfo = .{ .layout = .{ .bytes_per_row = 256, .rows_per_image = 64 }, .buffer = readback };
        const extent: Extent3D = .{ .width = 64, .height = 64, .depth_or_array_layers = 1 };
        self.procs.wgpuCommandEncoderCopyTextureToBuffer(enc, &src, &dst, &extent);
        try self.submit(enc);
        try self.mapInto(readback, out);
    }

    /// Copies the first out.len bytes of a buffer into a mappable buffer and returns them.
    fn readBuffer(self: *const Ctx, src: Buffer, out: []u8) !void {
        const readback = self.readbackBuffer(out.len);
        defer self.procs.wgpuBufferRelease(readback);
        const enc = self.procs.wgpuDeviceCreateCommandEncoder(self.device, null) orelse return error.EncoderFailed;
        defer self.procs.wgpuCommandEncoderRelease(enc);
        self.procs.wgpuCommandEncoderCopyBufferToBuffer(enc, src, 0, readback, 0, out.len);
        try self.submit(enc);
        try self.mapInto(readback, out);
    }

    fn readbackBuffer(self: *const Ctx, size: usize) Buffer {
        return self.procs.wgpuDeviceCreateBuffer(self.device, &BufferDescriptor{
            .usage = BufferUsage.map_read | BufferUsage.copy_dst,
            .size = size,
        }) orelse @panic("readback buffer creation failed");
    }

    fn submit(self: *const Ctx, enc: CommandEncoder) !void {
        const cmd = self.procs.wgpuCommandEncoderFinish(enc, null) orelse return error.EncoderFailed;
        defer self.procs.wgpuCommandBufferRelease(cmd);
        const cmds = [_]?CommandBuffer{cmd};
        self.procs.wgpuQueueSubmit(self.queue, 1, &cmds[0]);
    }

    fn mapInto(self: *const Ctx, buf: Buffer, out: []u8) !void {
        var waiter: Waiter = .{};
        _ = self.procs.wgpuBufferMapAsync(buf, map_mode_read, 0, out.len, .{
            .mode = callback_mode_allow_process_events,
            .callback = onMap,
            .userdata1 = &waiter,
        });
        try self.waitFor(&waiter);
        if (!waiter.mapped) return error.MapFailed;
        const mapped: [*]const u8 = @ptrCast(self.procs.wgpuBufferGetConstMappedRange(buf, 0, out.len) orelse return error.MapFailed);
        @memcpy(out, mapped[0..out.len]);
        self.procs.wgpuBufferUnmap(buf);
    }
};

/// Uniform block of the test shaders (32 bytes, see UNIFORM_WGSL).
const Params = extern struct {
    z: f32 = 0.5,
    scale: f32 = 1,
    pad: [2]f32 = .{ 0, 0 },
    color: [4]f32 = .{ 0, 0, 0, 1 },
};

// ---- WGSL sources

/// Vertex-stage uniform (z, scale, color), so that the block belongs to one stage.
const uniform_wgsl =
    \\struct P { z: f32, scale: f32, pad: vec2f, color: vec4f };
    \\@group(0) @binding(0) var<uniform> p: P;
    \\struct VsOut { @builtin(position) pos: vec4f, @location(0) col: vec4f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> VsOut {
    \\    var q = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    \\    var out: VsOut;
    \\    out.pos = vec4f(q[i] * p.scale, p.z, 1.0);
    \\    out.col = p.color;
    \\    return out;
    \\}
    \\@fragment fn fs(in: VsOut) -> @location(0) vec4f { return in.col; }
;

const vertex_buffer_wgsl =
    \\@vertex fn vs(@location(0) pos: vec2f) -> @builtin(position) vec4f { return vec4f(pos, 0.0, 1.0); }
    \\@fragment fn fs() -> @location(0) vec4f { return vec4f(1.0, 1.0, 1.0, 1.0); }
;

const texture_wgsl =
    \\@group(1) @binding(0) var tex: texture_2d<f32>;
    \\@group(1) @binding(1) var smp: sampler;
    \\struct VsOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> VsOut {
    \\    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    \\    var out: VsOut;
    \\    out.pos = vec4f(p[i], 0.0, 1.0);
    \\    out.uv = vec2f(p[i].x * 0.5 + 0.5, 0.5 - p[i].y * 0.5);
    \\    return out;
    \\}
    \\@fragment fn fs(in: VsOut) -> @location(0) vec4f { return textureSample(tex, smp, in.uv); }
;

const cube_wgsl =
    \\@group(1) @binding(0) var tex: texture_cube<f32>;
    \\@group(1) @binding(1) var smp: sampler;
    \\struct VsOut { @builtin(position) pos: vec4f, @location(0) dir: vec3f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> VsOut {
    \\    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    \\    var out: VsOut;
    \\    out.pos = vec4f(p[i], 0.0, 1.0);
    \\    out.dir = vec3f(p[i], 1.0);
    \\    return out;
    \\}
    \\@fragment fn fs(in: VsOut) -> @location(0) vec4f { return textureSample(tex, smp, in.dir); }
;

const array_wgsl =
    \\@group(1) @binding(0) var tex: texture_2d_array<f32>;
    \\@group(1) @binding(1) var smp: sampler;
    \\struct VsOut { @builtin(position) pos: vec4f, @location(0) uv: vec2f };
    \\@vertex fn vs(@builtin(vertex_index) i: u32) -> VsOut {
    \\    var p = array<vec2f, 3>(vec2f(-1.0, -1.0), vec2f(3.0, -1.0), vec2f(-1.0, 3.0));
    \\    var out: VsOut;
    \\    out.pos = vec4f(p[i], 0.0, 1.0);
    \\    out.uv = vec2f(p[i].x * 0.5 + 0.5, 0.5 - p[i].y * 0.5);
    \\    return out;
    \\}
    \\@fragment fn fs(in: VsOut) -> @location(0) vec4f { return textureSample(tex, smp, in.uv, 1); }
;

const storage_image_compute_wgsl =
    \\@group(1) @binding(0) var dst: texture_storage_2d<rgba8unorm, write>;
    \\@compute @workgroup_size(8, 8) fn cs(@builtin(global_invocation_id) id: vec3u) {
    \\    textureStore(dst, vec2i(id.xy), vec4f(f32(id.x) / 63.0, f32(id.y) / 63.0, 0.0, 1.0));
    \\}
;

const storage_buffer_compute_wgsl =
    \\@group(1) @binding(0) var<storage, read_write> dst: array<u32>;
    \\@compute @workgroup_size(64) fn cs(@builtin(global_invocation_id) id: vec3u) {
    \\    dst[id.x] = id.x * 3u + 1u;
    \\}
;

// ---- helpers

const Target = struct {
    tex: Texture,
    img: gfx.Image,
    view: gfx.View,
};

/// A 64x64 rgba8 render target whose wgpu texture is injected, so that it can be read back.
fn makeTarget(ctx: *const Ctx) !Target {
    const tex = ctx.procs.wgpuDeviceCreateTexture(ctx.device, &TextureDescriptor{
        .usage = TextureUsage.render_attachment | TextureUsage.copy_src | TextureUsage.texture_binding,
        .dimension = .@"2_d",
        .size = .{ .width = 64, .height = 64, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .mip_level_count = 1,
        .sample_count = 1,
    }) orelse return error.TextureFailed;
    const img = gfx.makeImage(.{
        .type = .@"2d",
        .width = 64,
        .height = 64,
        .pixel_format = .rgba8,
        .usage = .{ .color_attachment = true, .resolve_attachment = true },
        .wgpu_texture = @ptrCast(tex),
    });
    try expectState(gfx.queryImageState(img));
    const view = gfx.makeView(.{ .color_attachment = .{ .image = img } });
    try expectState(gfx.queryViewState(view));
    return .{ .tex = tex, .img = img, .view = view };
}

fn destroyTarget(ctx: *const Ctx, target: Target) void {
    gfx.destroyView(target.view);
    gfx.destroyImage(target.img);
    // sokol holds its own reference to the injected texture, released by destroyImage
    ctx.procs.wgpuTextureRelease(target.tex);
}

fn expectUnsealed(state: anytype) !void {
    if (state != .unsealed) {
        std.debug.print("resource state {s}, expected unsealed\n", .{@tagName(state)});
        return error.ResourceCreationFailed;
    }
}

fn expectState(state: anytype) !void {
    if (state != .valid) {
        std.debug.print("resource state {s}, expected valid\n", .{@tagName(state)});
        return error.ResourceCreationFailed;
    }
}

fn beginTarget(view: gfx.View, clear: [4]f32) void {
    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = view;
    pass.action.colors[0] = .{ .load_action = .clear, .clear_value = .{ .r = clear[0], .g = clear[1], .b = clear[2], .a = clear[3] } };
    gfx.beginPass(pass);
}

fn pixelAt(pixels: []const u8, x: usize, y: usize) [4]u8 {
    const offset = (y * 64 + x) * 4;
    return pixels[offset..][0..4].*;
}

fn expectPixelTol(pixels: []const u8, x: usize, y: usize, expected: [4]i32, tolerance: i32) !void {
    const got = pixelAt(pixels, x, y);
    for (got, expected) |value, want| {
        if (@abs(@as(i32, value) - want) > tolerance) {
            std.debug.print("pixel ({d},{d}) is {any}, expected {any}\n", .{ x, y, got, expected });
            return error.PixelMismatch;
        }
    }
}

fn expectPixel(pixels: []const u8, x: usize, y: usize, expected: [4]i32) !void {
    try expectPixelTol(pixels, x, y, expected, 1);
}

fn checkNoWgpuErrors() !void {
    if (uncaptured_errors != 0) return error.WgpuValidationError;
}

fn uniformShader() gfx.Shader {
    var desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .source = uniform_wgsl, .entry = "vs" },
        .fragment_func = .{ .source = uniform_wgsl, .entry = "fs" },
    };
    desc.uniform_blocks[0] = .{ .stage = .vertex, .size = @sizeOf(Params), .wgsl_group0_binding_n = 0 };
    return gfx.makeShader(desc);
}

fn texturedShader(wgsl: [:0]const u8, image_type: gfx.ImageType) gfx.Shader {
    var desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .source = wgsl, .entry = "vs" },
        .fragment_func = .{ .source = wgsl, .entry = "fs" },
    };
    desc.views[0].texture = .{ .stage = .fragment, .image_type = image_type, .sample_type = .float, .wgsl_group1_binding_n = 0 };
    desc.samplers[0] = .{ .stage = .fragment, .sampler_type = .filtering, .wgsl_group1_binding_n = 1 };
    desc.texture_sampler_pairs[0] = .{ .stage = .fragment, .view_slot = 0, .sampler_slot = 0 };
    return gfx.makeShader(desc);
}

fn colorPipeline(shd: gfx.Shader) gfx.Pipeline {
    return gfx.makePipeline(.{ .shader = shd, .depth = .{ .pixel_format = .none }, .colors = .{ .{ .pixel_format = .rgba8 }, .{}, .{}, .{}, .{}, .{}, .{}, .{} } });
}

fn drawFullscreen(pip: gfx.Pipeline, params: Params) void {
    gfx.applyPipeline(pip);
    gfx.applyUniforms(0, gfx.Range.fromValue(Params, &params));
    gfx.draw(0, 3, 1);
}

fn samplerLinearClamp() gfx.Sampler {
    return gfx.makeSampler(.{ .min_filter = .nearest, .mag_filter = .nearest, .wrap_u = .clamp_to_edge, .wrap_v = .clamp_to_edge });
}

/// Samples `view` over the whole target (nearest filtering, so texel (x,y) lands on pixel (x,y)).
fn sampleInto(pip: gfx.Pipeline, view: gfx.View, smp: gfx.Sampler, target: gfx.View) void {
    beginTarget(target, .{ 0, 0, 0, 1 });
    gfx.applyPipeline(pip);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = view;
    bindings.samplers[0] = smp;
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 1);
    gfx.endPass();
}

fn vertexPipeline(shd: gfx.Shader, stride: i32) gfx.Pipeline {
    var desc: gfx.PipelineDesc = .{ .shader = shd, .depth = .{ .pixel_format = .none } };
    desc.colors[0].pixel_format = .rgba8;
    desc.layout.buffers[0].stride = stride;
    desc.layout.attrs[0] = .{ .format = .float2 };
    return gfx.makePipeline(desc);
}

// ---- scenarios

/// (1) writeBufferTransient vertex data, changing every frame.
fn testWriteBufferTransient(ctx: *const Ctx) !void {
    const vbuf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_transient = true }, .size = 3 * 8 });
    try expectState(gfx.queryBufferState(vbuf));
    var shd_desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .source = vertex_buffer_wgsl, .entry = "vs" },
        .fragment_func = .{ .source = vertex_buffer_wgsl, .entry = "fs" },
    };
    shd_desc.attrs[0] = .{ .base_type = .float };
    const pip = vertexPipeline(gfx.makeShader(shd_desc), 8);
    const target = try makeTarget(ctx);
    for (0..4) |frame| {
        const cx: f32 = -0.5 + 0.25 * @as(f32, @floatFromInt(frame));
        const verts = [3][2]f32{ .{ cx - 0.4, -0.4 }, .{ cx + 0.4, -0.4 }, .{ cx, 0.4 } };
        gfx.writeBufferTransient(.{
            .dst = .{ .buffer = vbuf },
            .src = .{ .data = gfx.Range.fromSlice([2]f32, &verts) },
            .size = @sizeOf([3][2]f32),
        });
        beginTarget(target.view, .{ 0, 0, 0, 1 });
        gfx.applyPipeline(pip);
        var bindings: gfx.Bindings = .{};
        bindings.vertex_buffers[0] = vbuf;
        gfx.applyBindings(bindings);
        gfx.draw(0, 3, 1);
        gfx.endPass();
        gfx.commit();
        var pixels: [64 * 64 * 4]u8 = undefined;
        try ctx.readTexture(target.tex, &pixels);
        try checkNoWgpuErrors();
        const px: usize = @intFromFloat(@floor((cx + 1) * 32));
        try expectPixel(&pixels, px, 32, .{ 255, 255, 255, 255 });
        try expectPixel(&pixels, px, 4, .{ 0, 0, 0, 255 });
    }
    destroyTarget(ctx, target);
}

/// (2) writeImageTransient, a new 2x2 texture every frame, sampled into the target.
fn testWriteImageTransient(ctx: *const Ctx) !void {
    const timg = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .write_transient = true } });
    try expectState(gfx.queryImageState(timg));
    const tview = gfx.makeView(.{ .texture = .{ .image = timg } });
    const pip = colorPipeline(texturedShader(texture_wgsl, .@"2d"));
    const smp = samplerLinearClamp();
    const colors = [4][4]u8{ .{ 255, 0, 0, 255 }, .{ 0, 255, 0, 255 }, .{ 0, 0, 255, 255 }, .{ 255, 255, 0, 255 } };
    const target = try makeTarget(ctx);
    for (colors) |color| {
        var texels: [16]u8 = undefined;
        for (0..4) |i| @memcpy(texels[i * 4 ..][0..4], &color);
        gfx.writeImageTransient(.{
            .src = .{ .data = gfx.Range.fromSlice(u8, &texels), .offset = 0, .bytes_per_row = 8, .bytes_per_slice = 16 },
            .dst = .{ .image = timg, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
            .size = .{ .width = 2, .height = 2, .num_slices = 1 },
        });
        sampleInto(pip, tview, smp, target.view);
        gfx.commit();
        var pixels: [64 * 64 * 4]u8 = undefined;
        try ctx.readTexture(target.tex, &pixels);
        try checkNoWgpuErrors();
        const expected: [4]i32 = .{ color[0], color[1], color[2], color[3] };
        try expectPixel(&pixels, 16, 16, expected);
        try expectPixel(&pixels, 48, 48, expected);
    }
    destroyTarget(ctx, target);
}

/// (3) write_unsealed buffer and image, sealed and then used.
fn testWriteUnsealed(ctx: *const Ctx) !void {
    const ubuf = gfx.makeBuffer(.{ .usage = .{ .vertex_buffer = true, .write_unsealed = true }, .size = 3 * 8 });
    try expectUnsealed(gfx.queryBufferState(ubuf));
    const tri = [3][2]f32{ .{ -0.5, -0.5 }, .{ 0.5, -0.5 }, .{ 0, 0.5 } };
    gfx.writeBufferUnsealed(.{ .dst = .{ .buffer = ubuf }, .src = .{ .data = gfx.Range.fromSlice([2]f32, &tri) }, .size = @sizeOf([3][2]f32) });
    gfx.sealBuffer(ubuf);
    var shd_desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .source = vertex_buffer_wgsl, .entry = "vs" },
        .fragment_func = .{ .source = vertex_buffer_wgsl, .entry = "fs" },
    };
    shd_desc.attrs[0] = .{ .base_type = .float };
    const pip = vertexPipeline(gfx.makeShader(shd_desc), 8);
    const target = try makeTarget(ctx);
    beginTarget(target.view, .{ 0, 0, 0, 1 });
    gfx.applyPipeline(pip);
    var bindings: gfx.Bindings = .{};
    bindings.vertex_buffers[0] = ubuf;
    gfx.applyBindings(bindings);
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.commit();
    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 255, 255, 255, 255 });
    try expectPixel(&pixels, 2, 2, .{ 0, 0, 0, 255 });

    // an image written with write_unsealed, sealed, then sampled
    const uimg = gfx.makeImage(.{ .width = 2, .height = 2, .pixel_format = .rgba8, .usage = .{ .write_unsealed = true } });
    try expectUnsealed(gfx.queryImageState(uimg));
    const green = [16]u8{ 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255, 0, 255 };
    gfx.writeImageUnsealed(.{
        .src = .{ .data = gfx.Range.fromSlice(u8, &green), .offset = 0, .bytes_per_row = 8, .bytes_per_slice = 16 },
        .dst = .{ .image = uimg, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
        .size = .{ .width = 2, .height = 2, .num_slices = 1 },
    });
    gfx.sealImage(uimg);
    sampleInto(colorPipeline(texturedShader(texture_wgsl, .@"2d")), gfx.makeView(.{ .texture = .{ .image = uimg } }), samplerLinearClamp(), target.view);
    gfx.commit();
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 16, 16, .{ 0, 255, 0, 255 });
    try expectPixel(&pixels, 48, 48, .{ 0, 255, 0, 255 });
    destroyTarget(ctx, target);
}

fn fillPattern(comptime f: fn (x: usize, y: usize) [4]u8, out: []u8) void {
    for (0..64) |y| {
        for (0..64) |x| {
            @memcpy(out[(y * 64 + x) * 4 ..][0..4], &f(x, y));
        }
    }
}

fn patternA(x: usize, y: usize) [4]u8 {
    return .{ @intCast(x), @intCast(y), @intCast((x + y) & 255), 255 };
}

fn patternB(x: usize, y: usize) [4]u8 {
    return .{ @intCast(255 - x), @intCast(y), 7, 255 };
}

/// (4) copyBufferToBuffer from a staging buffer and a GPU buffer, copyBufferToImage from both, then sampled.
fn testCopies(ctx: *const Ctx) !void {
    var pattern_a: [64 * 64 * 4]u8 = undefined;
    fillPattern(patternA, &pattern_a);
    var pattern_b: [64 * 64 * 4]u8 = undefined;
    fillPattern(patternB, &pattern_b);

    // staging source: written with write_transient, read by copies
    const staging = gfx.makeBuffer(.{ .usage = .{ .staging_buffer = true, .write_transient = true, .copy_src = true }, .size = 64 * 64 * 4 });
    try expectState(gfx.queryBufferState(staging));
    gfx.writeBufferTransient(.{ .dst = .{ .buffer = staging }, .src = .{ .data = gfx.Range.fromSlice(u8, &pattern_a) }, .size = pattern_a.len });

    // GPU source: written with write_unsealed, sealed
    const gpu_src = gfx.makeBuffer(.{ .usage = .{ .write_unsealed = true, .copy_src = true }, .size = 64 * 64 * 4 });
    try expectUnsealed(gfx.queryBufferState(gpu_src));
    gfx.writeBufferUnsealed(.{ .dst = .{ .buffer = gpu_src }, .src = .{ .data = gfx.Range.fromSlice(u8, &pattern_b) }, .size = pattern_b.len });
    gfx.sealBuffer(gpu_src);

    // buffer-to-buffer copies: staging to GPU buffer, and GPU buffer to GPU buffer
    const gpu_dst = gfx.makeBuffer(.{ .usage = .{ .copy_dst = true, .copy_src = true }, .size = 256 });
    const gpu_dst2 = gfx.makeBuffer(.{ .usage = .{ .copy_dst = true, .copy_src = true }, .size = 256 });
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = staging }, .dst = .{ .buffer = gpu_dst }, .size = 256 });
    gfx.copyBufferToBuffer(.{ .src = .{ .buffer = gpu_src }, .dst = .{ .buffer = gpu_dst2 }, .size = 256 });

    // buffer-to-image copies: from staging and from the GPU buffer, 256-byte rows
    const img_a = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .rgba8, .usage = .{ .copy_dst = true } });
    const img_b = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .rgba8, .usage = .{ .copy_dst = true } });
    try expectState(gfx.queryImageState(img_a));
    try expectState(gfx.queryImageState(img_b));
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = staging, .offset = 0, .bytes_per_row = 256, .bytes_per_slice = 256 * 64 },
        .dst = .{ .image = img_a, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
        .size = .{ .width = 64, .height = 64, .num_slices = 1 },
    });
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = gpu_src, .offset = 0, .bytes_per_row = 256, .bytes_per_slice = 256 * 64 },
        .dst = .{ .image = img_b, .mip_level = 0, .x = 0, .y = 0, .slice = 0 },
        .size = .{ .width = 64, .height = 64, .num_slices = 1 },
    });

    // sample the copied images into the target, one per pass
    const target = try makeTarget(ctx);
    const pip = colorPipeline(texturedShader(texture_wgsl, .@"2d"));
    const smp = samplerLinearClamp();
    sampleInto(pip, gfx.makeView(.{ .texture = .{ .image = img_a } }), smp, target.view);
    gfx.commit();
    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    for ([_][2]usize{ .{ 5, 7 }, .{ 20, 40 }, .{ 63, 63 } }) |p| {
        try expectPixel(&pixels, p[0], p[1], .{ @intCast(p[0]), @intCast(p[1]), @intCast((p[0] + p[1]) & 255), 255 });
    }
    sampleInto(pip, gfx.makeView(.{ .texture = .{ .image = img_b } }), smp, target.view);
    gfx.commit();
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    for ([_][2]usize{ .{ 5, 7 }, .{ 40, 20 }, .{ 63, 0 } }) |p| {
        try expectPixel(&pixels, p[0], p[1], .{ @intCast(255 - p[0]), @intCast(p[1]), 7, 255 });
    }

    // read back the buffer copies (the copies were recorded in the frame above)
    var out: [256]u8 = undefined;
    try ctx.readBuffer(asBuffer(gfx.wgpuQueryBufferInfo(gpu_dst).buf), &out);
    try checkNoWgpuErrors();
    try expectEqualBytes(pattern_a[0..256], &out);
    try ctx.readBuffer(asBuffer(gfx.wgpuQueryBufferInfo(gpu_dst2).buf), &out);
    try checkNoWgpuErrors();
    try expectEqualBytes(pattern_b[0..256], &out);
    destroyTarget(ctx, target);
}

fn expectEqualBytes(want: []const u8, got: []const u8) !void {
    for (want, got, 0..) |w, g, i| {
        if (w != g) {
            std.debug.print("byte {d} is {d}, expected {d}\n", .{ i, g, w });
            return error.ByteMismatch;
        }
    }
}

fn asBuffer(ptr: ?*const anyopaque) Buffer {
    return @ptrCast(@constCast(ptr orelse @panic("missing wgpu buffer")));
}

/// (5) depth and stencil: a small near triangle writes depth and stencil, a full-screen far
/// triangle is only drawn where the stencil says so and fails the depth test over the small one.
fn testDepthStencil(ctx: *const Ctx) !void {
    const target = try makeTarget(ctx);
    const dimg = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .depth_stencil, .usage = .{ .depth_stencil_attachment = true } });
    try expectState(gfx.queryImageState(dimg));
    const dview = gfx.makeView(.{ .depth_stencil_attachment = .{ .image = dimg } });
    try expectState(gfx.queryViewState(dview));
    const shd = uniformShader();
    try expectState(gfx.queryShaderState(shd));
    const write_stencil: gfx.StencilFaceState = .{ .compare = .always, .fail_op = .keep, .depth_fail_op = .keep, .pass_op = .replace };
    const pip_near = gfx.makePipeline(.{
        .shader = shd,
        .depth = .{ .pixel_format = .depth_stencil, .compare = .less, .write_enabled = true },
        .stencil = .{ .enabled = true, .front = write_stencil, .back = write_stencil, .read_mask = 0xff, .write_mask = 0xff, .ref = 1 },
        .colors = .{ .{ .pixel_format = .rgba8 }, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    });
    const test_stencil: gfx.StencilFaceState = .{ .compare = .equal, .fail_op = .keep, .depth_fail_op = .keep, .pass_op = .keep };
    const pip_far = gfx.makePipeline(.{
        .shader = shd,
        .depth = .{ .pixel_format = .depth_stencil, .compare = .less, .write_enabled = false },
        .stencil = .{ .enabled = true, .front = test_stencil, .back = test_stencil, .read_mask = 0xff, .write_mask = 0, .ref = 1 },
        .colors = .{ .{ .pixel_format = .rgba8 }, .{}, .{}, .{}, .{}, .{}, .{}, .{} },
    });
    try expectState(gfx.queryPipelineState(pip_near));
    try expectState(gfx.queryPipelineState(pip_far));

    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = target.view;
    pass.attachments.depth_stencil = dview;
    pass.action.colors[0] = .{ .load_action = .clear, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
    pass.action.depth = .{ .load_action = .clear, .clear_value = 1.0 };
    pass.action.stencil = .{ .load_action = .clear, .clear_value = 0 };
    gfx.beginPass(pass);
    // small triangle covering the center, depth 0.25, red
    gfx.applyPipeline(pip_near);
    gfx.applyUniforms(0, gfx.Range.fromValue(Params, &Params{ .z = 0.25, .scale = 0.5, .color = .{ 1, 0, 0, 1 } }));
    gfx.draw(0, 3, 1);
    // full-screen triangle at depth 0.75, blue: only drawn where the stencil is 1, and fails depth over the small one
    gfx.applyPipeline(pip_far);
    gfx.applyUniforms(0, gfx.Range.fromValue(Params, &Params{ .z = 0.75, .scale = 1, .color = .{ 0, 0, 1, 1 } }));
    gfx.draw(0, 3, 1);
    gfx.endPass();
    gfx.commit();

    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 255, 0, 0, 255 });
    try expectPixel(&pixels, 2, 2, .{ 0, 0, 0, 255 });
    try expectPixel(&pixels, 60, 60, .{ 0, 0, 0, 255 });
    destroyTarget(ctx, target);
}

/// (6) 4x MSAA color target resolved into a single-sample texture.
fn testMsaaResolve(ctx: *const Ctx) !void {
    const target = try makeTarget(ctx);
    const msaa = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .rgba8, .sample_count = 4, .usage = .{ .color_attachment = true } });
    try expectState(gfx.queryImageState(msaa));
    const msaa_view = gfx.makeView(.{ .color_attachment = .{ .image = msaa } });
    const resolve_view = gfx.makeView(.{ .resolve_attachment = .{ .image = target.img } });
    try expectState(gfx.queryViewState(resolve_view));
    var pip_desc: gfx.PipelineDesc = .{ .shader = uniformShader(), .depth = .{ .pixel_format = .none }, .sample_count = 4 };
    pip_desc.colors[0].pixel_format = .rgba8;
    const pip = gfx.makePipeline(pip_desc);
    try expectState(gfx.queryPipelineState(pip));

    var pass: gfx.Pass = .{};
    pass.attachments.colors[0] = msaa_view;
    pass.attachments.resolves[0] = resolve_view;
    pass.action.colors[0] = .{ .load_action = .clear, .clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 } };
    gfx.beginPass(pass);
    drawFullscreen(pip, .{ .z = 0.5, .scale = 0.5, .color = .{ 1, 0, 0, 1 } });
    gfx.endPass();
    gfx.commit();

    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 255, 0, 0, 255 });
    try expectPixel(&pixels, 2, 2, .{ 0, 0, 0, 255 });
    destroyTarget(ctx, target);
}

/// (7) render to a texture in one pass, then sample it in a second pass.
fn testRenderToTexture(ctx: *const Ctx) !void {
    const a = try makeTarget(ctx);
    const b = try makeTarget(ctx);
    const a_view = gfx.makeView(.{ .texture = .{ .image = a.img } });
    try expectState(gfx.queryViewState(a_view));
    const pip_solid = gfx.makePipeline(blk: {
        var desc: gfx.PipelineDesc = .{ .shader = uniformShader(), .depth = .{ .pixel_format = .none } };
        desc.colors[0].pixel_format = .rgba8;
        break :blk desc;
    });
    try expectState(gfx.queryPipelineState(pip_solid));

    beginTarget(a.view, .{ 0, 0, 0, 1 });
    drawFullscreen(pip_solid, .{ .z = 0.5, .scale = 0.5, .color = .{ 0, 0, 1, 1 } });
    gfx.endPass();
    sampleInto(colorPipeline(texturedShader(texture_wgsl, .@"2d")), a_view, samplerLinearClamp(), b.view);
    gfx.commit();

    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(b.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 0, 0, 255, 255 });
    try expectPixel(&pixels, 2, 2, .{ 0, 0, 0, 255 });
    destroyTarget(ctx, b);
    destroyTarget(ctx, a);
}

/// (8) a compute shader writes a storage image, which is then sampled.
fn testComputeStorageImage(ctx: *const Ctx) !void {
    const simg = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .rgba8, .usage = .{ .storage_image = true } });
    try expectState(gfx.queryImageState(simg));
    const sview = gfx.makeView(.{ .storage_image = .{ .image = simg } });
    try expectState(gfx.queryViewState(sview));
    var shd_desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = storage_image_compute_wgsl, .entry = "cs" } };
    shd_desc.views[0].storage_image = .{ .stage = .compute, .image_type = .@"2d", .access_format = .rgba8, .writeonly = true, .wgsl_group1_binding_n = 0 };
    const cpip = gfx.makePipeline(.{ .shader = gfx.makeShader(shd_desc), .compute = true });
    try expectState(gfx.queryPipelineState(cpip));

    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(cpip);
    var cbind: gfx.Bindings = .{};
    cbind.views[0] = sview;
    gfx.applyBindings(cbind);
    gfx.dispatch(8, 8, 1);
    gfx.endPass();

    const target = try makeTarget(ctx);
    const tview = gfx.makeView(.{ .texture = .{ .image = simg } });
    sampleInto(colorPipeline(texturedShader(texture_wgsl, .@"2d")), tview, samplerLinearClamp(), target.view);
    gfx.commit();

    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    for ([_][2]usize{ .{ 0, 0 }, .{ 20, 40 }, .{ 63, 63 }, .{ 7, 58 } }) |p| {
        const r: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(p[0])) / 63.0 * 255.0));
        const g: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(p[1])) / 63.0 * 255.0));
        try expectPixel(&pixels, p[0], p[1], .{ r, g, 0, 255 });
    }
    destroyTarget(ctx, target);
}

/// (9) destroy and recreate resources between frames, with 200 uniform updates per frame
/// (dynamic offsets up to 51200 bytes, within uniform_buffer_size) and scissored strips.
fn testFramesAndUniformRing(ctx: *const Ctx) !void {
    var shd = uniformShader();
    var pip = gfx.makePipeline(blk: {
        var desc: gfx.PipelineDesc = .{ .shader = shd, .depth = .{ .pixel_format = .none } };
        desc.colors[0].pixel_format = .rgba8;
        break :blk desc;
    });
    for (0..10) |frame| {
        if (frame == 5) {
            // recreate the shader and pipeline in the middle of the sequence
            gfx.destroyPipeline(pip);
            gfx.destroyShader(shd);
            shd = uniformShader();
            pip = gfx.makePipeline(blk: {
                var desc: gfx.PipelineDesc = .{ .shader = shd, .depth = .{ .pixel_format = .none } };
                desc.colors[0].pixel_format = .rgba8;
                break :blk desc;
            });
            try expectState(gfx.queryPipelineState(pip));
        }
        const target = try makeTarget(ctx);
        beginTarget(target.view, .{ 0, 0, 0, 1 });
        gfx.applyPipeline(pip);
        // 136 updates that are not drawn, so that the drawn updates start at a large offset
        for (0..136) |_| gfx.applyUniforms(0, gfx.Range.fromValue(Params, &Params{ .color = .{ 1, 1, 1, 1 } }));
        for (0..64) |col| {
            const params: Params = .{
                .z = 0.5,
                .scale = 1,
                .color = .{ @as(f32, @floatFromInt(col)) / 63.0, @as(f32, @floatFromInt(frame)) / 9.0, 0.5, 1 },
            };
            gfx.applyUniforms(0, gfx.Range.fromValue(Params, &params));
            gfx.applyScissorRect(@intCast(col), 0, 1, 64, true);
            gfx.draw(0, 3, 1);
        }
        gfx.endPass();
        gfx.commit();

        var pixels: [64 * 64 * 4]u8 = undefined;
        try ctx.readTexture(target.tex, &pixels);
        try checkNoWgpuErrors();
        for (0..64) |col| {
            const expected = [4]i32{
                @intFromFloat(@round(@as(f32, @floatFromInt(col)) / 63.0 * 255.0)),
                @intFromFloat(@round(@as(f32, @floatFromInt(frame)) / 9.0 * 255.0)),
                128,
                255,
            };
            try expectPixelTol(&pixels, col, 32, expected, 1);
        }
        destroyTarget(ctx, target);
    }
    gfx.destroyPipeline(pip);
    gfx.destroyShader(shd);
}

/// (10a) alpha blending with a scissor rectangle over a green clear color.
fn testBlendScissor(ctx: *const Ctx) !void {
    const target = try makeTarget(ctx);
    var desc: gfx.PipelineDesc = .{ .shader = uniformShader(), .depth = .{ .pixel_format = .none } };
    desc.colors[0] = .{ .pixel_format = .rgba8, .blend = .{
        .enabled = true,
        .src_factor_rgb = .src_alpha,
        .dst_factor_rgb = .one_minus_src_alpha,
        .op_rgb = .add,
        .src_factor_alpha = .one,
        .dst_factor_alpha = .zero,
        .op_alpha = .add,
    } };
    const pip = gfx.makePipeline(desc);
    try expectState(gfx.queryPipelineState(pip));
    beginTarget(target.view, .{ 0, 1, 0, 1 });
    gfx.applyScissorRect(0, 0, 32, 64, true);
    drawFullscreen(pip, .{ .z = 0.5, .scale = 1, .color = .{ 1, 0, 0, 0.5 } });
    gfx.endPass();
    gfx.commit();
    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 10, 32, .{ 128, 128, 0, 128 });
    try expectPixel(&pixels, 50, 32, .{ 0, 255, 0, 255 });
    destroyTarget(ctx, target);
}

/// (10b) a triangle strip quad drawn with 16-bit indices.
fn testStripIndexed(ctx: *const Ctx) !void {
    const target = try makeTarget(ctx);
    const quad = [4][2]f32{ .{ -0.5, -0.5 }, .{ 0.5, -0.5 }, .{ -0.5, 0.5 }, .{ 0.5, 0.5 } };
    const indices = [4]u16{ 0, 1, 2, 3 };
    const vb = gfx.makeBuffer(.{ .data = gfx.Range.fromSlice([2]f32, &quad) });
    const ib = gfx.makeBuffer(.{ .usage = .{ .index_buffer = true }, .data = gfx.Range.fromSlice(u16, &indices) });
    try expectState(gfx.queryBufferState(vb));
    try expectState(gfx.queryBufferState(ib));
    var shd_desc: gfx.ShaderDesc = .{
        .vertex_func = .{ .source = vertex_buffer_wgsl, .entry = "vs" },
        .fragment_func = .{ .source = vertex_buffer_wgsl, .entry = "fs" },
    };
    shd_desc.attrs[0] = .{ .base_type = .float };
    var desc: gfx.PipelineDesc = .{ .shader = gfx.makeShader(shd_desc), .depth = .{ .pixel_format = .none }, .primitive_type = .triangle_strip, .index_type = .uint16 };
    desc.colors[0].pixel_format = .rgba8;
    desc.layout.buffers[0].stride = 8;
    desc.layout.attrs[0] = .{ .format = .float2 };
    const pip = gfx.makePipeline(desc);
    try expectState(gfx.queryPipelineState(pip));
    beginTarget(target.view, .{ 0, 0, 0, 1 });
    gfx.applyPipeline(pip);
    var bindings: gfx.Bindings = .{ .index_buffer = ib };
    bindings.vertex_buffers[0] = vb;
    gfx.applyBindings(bindings);
    gfx.draw(0, 4, 1);
    gfx.endPass();
    gfx.commit();
    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 255, 255, 255, 255 });
    try expectPixel(&pixels, 20, 20, .{ 255, 255, 255, 255 });
    try expectPixel(&pixels, 12, 12, .{ 0, 0, 0, 255 });
    destroyTarget(ctx, target);
}

/// (10c) a cube texture: the +Z face (layer 4) is magenta, all other faces black.
fn testCubeTexture(ctx: *const Ctx) !void {
    var cube: [6 * 2 * 2 * 4]u8 = @splat(0);
    for (0..6 * 2 * 2) |texel| {
        const face = texel / 4;
        if (face == 4) {
            cube[texel * 4 ..][0..4].* = .{ 255, 0, 255, 255 };
        } else {
            cube[texel * 4 + 3] = 255;
        }
    }
    var img_desc: gfx.ImageDesc = .{ .type = .cube, .width = 2, .height = 2, .num_slices = 6, .pixel_format = .rgba8 };
    img_desc.data.mip_levels[0] = gfx.Range.fromSlice(u8, &cube);
    const cimg = gfx.makeImage(img_desc);
    try expectState(gfx.queryImageState(cimg));
    const cview = gfx.makeView(.{ .texture = .{ .image = cimg } });
    try expectState(gfx.queryViewState(cview));
    const target = try makeTarget(ctx);
    sampleInto(colorPipeline(texturedShader(cube_wgsl, .cube)), cview, samplerLinearClamp(), target.view);
    gfx.commit();
    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 255, 0, 255, 255 });
    try expectPixel(&pixels, 2, 2, .{ 255, 0, 255, 255 });
    destroyTarget(ctx, target);
}

/// (10d) an array texture with two layers, layer 1 sampled.
fn testArrayTexture(ctx: *const Ctx) !void {
    const red = [4]u8{ 255, 0, 0, 255 };
    const blue = [4]u8{ 0, 0, 255, 255 };
    var layers: [2 * 2 * 2 * 4]u8 = undefined;
    for (0..8) |texel| {
        const layer_color = if (texel < 4) red else blue;
        @memcpy(layers[texel * 4 ..][0..4], &layer_color);
    }
    var img_desc: gfx.ImageDesc = .{ .type = .array, .width = 2, .height = 2, .num_slices = 2, .pixel_format = .rgba8 };
    img_desc.data.mip_levels[0] = gfx.Range.fromSlice(u8, &layers);
    const aimg = gfx.makeImage(img_desc);
    try expectState(gfx.queryImageState(aimg));
    const aview = gfx.makeView(.{ .texture = .{ .image = aimg } });
    try expectState(gfx.queryViewState(aview));
    const target = try makeTarget(ctx);
    sampleInto(colorPipeline(texturedShader(array_wgsl, .array)), aview, samplerLinearClamp(), target.view);
    gfx.commit();
    var pixels: [64 * 64 * 4]u8 = undefined;
    try ctx.readTexture(target.tex, &pixels);
    try checkNoWgpuErrors();
    try expectPixel(&pixels, 32, 32, .{ 0, 0, 255, 255 });
    try expectPixel(&pixels, 2, 60, .{ 0, 0, 255, 255 });
    destroyTarget(ctx, target);
}

/// (8b) compute writes a storage buffer, read back with copies.
fn testComputeStorageBuffer(ctx: *const Ctx) !void {
    const sbuf = gfx.makeBuffer(.{ .usage = .{ .storage_buffer = true, .copy_src = true }, .size = 256 });
    try expectState(gfx.queryBufferState(sbuf));
    const sview = gfx.makeView(.{ .storage_buffer = .{ .buffer = sbuf } });
    try expectState(gfx.queryViewState(sview));
    var shd_desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = storage_buffer_compute_wgsl, .entry = "cs" } };
    shd_desc.views[0].storage_buffer = .{ .stage = .compute, .readonly = false, .wgsl_group1_binding_n = 0 };
    const pip = gfx.makePipeline(.{ .shader = gfx.makeShader(shd_desc), .compute = true });
    try expectState(gfx.queryPipelineState(pip));
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(pip);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = sview;
    gfx.applyBindings(bindings);
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
    gfx.commit();
    var bytes: [256]u8 = undefined;
    try ctx.readBuffer(asBuffer(gfx.wgpuQueryBufferInfo(sbuf).buf), &bytes);
    try checkNoWgpuErrors();
    for (0..64) |i| {
        const value = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        if (value != i * 3 + 1) {
            std.debug.print("storage element {d} is {d}\n", .{ i, value });
            return error.ComputeMismatch;
        }
    }
}

// ---- readback (zicr raw API: gfx.readImage / gfx.readBuffer)

fn expectRead(ok: bool) !void {
    if (!ok) return error.ReadFailed;
    try checkNoWgpuErrors();
}

/// Every pixel of a solid-color full-screen draw, read with gfx.readImage (tight rows).
fn testReadRenderedImage(ctx: *const Ctx) !void {
    _ = ctx;
    const img = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .rgba8, .usage = .{ .color_attachment = true, .copy_src = true } });
    try expectState(gfx.queryImageState(img));
    const view = gfx.makeView(.{ .color_attachment = .{ .image = img } });
    const pip = colorPipeline(uniformShader());
    beginTarget(view, .{ 0, 0, 0, 1 });
    drawFullscreen(pip, .{ .z = 0.5, .scale = 1, .color = .{ 0.25, 0.5, 0.75, 1 } });
    gfx.endPass();
    gfx.commit();
    var out: [64 * 64 * 4]u8 = undefined;
    try expectRead(gfx.readImage(.{ .image = img }, &out));
    for (0..64) |y| {
        for (0..64) |x| try expectPixel(&out, x, y, .{ 64, 128, 191, 255 });
    }
}

/// Storage buffer written by compute, read at an unaligned offset and size.
fn testReadStorageBuffer(ctx: *const Ctx) !void {
    _ = ctx;
    const sbuf = gfx.makeBuffer(.{ .usage = .{ .storage_buffer = true, .copy_src = true }, .size = 256 });
    try expectState(gfx.queryBufferState(sbuf));
    const sview = gfx.makeView(.{ .storage_buffer = .{ .buffer = sbuf } });
    var shd_desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = storage_buffer_compute_wgsl, .entry = "cs" } };
    shd_desc.views[0].storage_buffer = .{ .stage = .compute, .readonly = false, .wgsl_group1_binding_n = 0 };
    const pip = gfx.makePipeline(.{ .shader = gfx.makeShader(shd_desc), .compute = true });
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(pip);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = sview;
    gfx.applyBindings(bindings);
    gfx.dispatch(1, 1, 1);
    gfx.endPass();
    gfx.commit();

    var all: [256]u8 = undefined;
    try expectRead(gfx.readBuffer(sbuf, 0, &all));
    for (0..64) |i| {
        if (std.mem.readInt(u32, all[i * 4 ..][0..4], .little) != i * 3 + 1) return error.ComputeMismatch;
    }
    // offset 5 and size 7 are not multiples of 4
    var part: [7]u8 = undefined;
    try expectRead(gfx.readBuffer(sbuf, 5, &part));
    try expectEqualBytes(all[5..12], &part);
    var tail: [3]u8 = undefined;
    try expectRead(gfx.readBuffer(sbuf, 253, &tail));
    try expectEqualBytes(all[253..256], &tail);
}

/// Sub-region of a compute-written storage image with a row pitch larger than the row.
fn testReadImageRegion(ctx: *const Ctx) !void {
    _ = ctx;
    const simg = gfx.makeImage(.{ .width = 64, .height = 64, .pixel_format = .rgba8, .usage = .{ .storage_image = true, .copy_src = true } });
    try expectState(gfx.queryImageState(simg));
    const sview = gfx.makeView(.{ .storage_image = .{ .image = simg } });
    var shd_desc: gfx.ShaderDesc = .{ .compute_func = .{ .source = storage_image_compute_wgsl, .entry = "cs" } };
    shd_desc.views[0].storage_image = .{ .stage = .compute, .image_type = .@"2d", .access_format = .rgba8, .writeonly = true, .wgsl_group1_binding_n = 0 };
    const pip = gfx.makePipeline(.{ .shader = gfx.makeShader(shd_desc), .compute = true });
    gfx.beginPass(.{ .compute = true });
    gfx.applyPipeline(pip);
    var bindings: gfx.Bindings = .{};
    bindings.views[0] = sview;
    gfx.applyBindings(bindings);
    gfx.dispatch(8, 8, 1);
    gfx.endPass();
    gfx.commit();

    // 10x4 texels at (5,7), 64 bytes per row (40 used), 256 bytes per slice
    var out: [256]u8 = @splat(0);
    try expectRead(gfx.readImage(.{ .image = simg, .x = 5, .y = 7, .width = 10, .height = 4, .bytes_per_row = 64, .bytes_per_slice = 256 }, &out));
    for (0..4) |j| {
        for (0..10) |i| {
            const x = 5 + i;
            const y = 7 + j;
            const r: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(x)) / 63.0 * 255.0));
            const g: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(y)) / 63.0 * 255.0));
            const pixel = out[j * 64 + i * 4 ..][0..4];
            if (@abs(@as(i32, pixel[0]) - r) > 1 or @abs(@as(i32, pixel[1]) - g) > 1 or pixel[2] != 0 or pixel[3] != 255) {
                std.debug.print("region texel ({d},{d}) is {any}\n", .{ x, y, pixel });
                return error.PixelMismatch;
            }
        }
        // the row padding is not written
        for (40..64) |pad| if (out[j * 64 + pad] != 0) return error.RowPaddingWritten;
    }
}

/// A non-zero array layer at mip level 1, written by copyBufferToImage from a GPU buffer.
fn testReadArrayLayerMip(ctx: *const Ctx) !void {
    _ = ctx;
    const aimg = gfx.makeImage(.{ .type = .array, .width = 4, .height = 4, .num_slices = 2, .num_mipmaps = 2, .pixel_format = .rgba8, .usage = .{ .copy_dst = true, .copy_src = true } });
    try expectState(gfx.queryImageState(aimg));
    const src = gfx.makeBuffer(.{ .usage = .{ .write_unsealed = true, .copy_src = true }, .size = 512 });
    try expectUnsealed(gfx.queryBufferState(src));
    // two rows of 8 bytes, 256 bytes apart (copies from GPU buffers need 256-byte rows)
    var data: [512]u8 = @splat(0);
    for (0..8) |i| data[i] = @intCast(i + 1);
    for (0..8) |i| data[256 + i] = @intCast(i + 9);
    gfx.writeBufferUnsealed(.{ .dst = .{ .buffer = src }, .src = .{ .data = gfx.Range.fromSlice(u8, &data) }, .size = data.len });
    gfx.sealBuffer(src);
    gfx.copyBufferToImage(.{
        .src = .{ .buffer = src, .offset = 0, .bytes_per_row = 256, .bytes_per_slice = 512 },
        .dst = .{ .image = aimg, .mip_level = 1, .x = 0, .y = 0, .slice = 1 },
        .size = .{ .width = 2, .height = 2, .num_slices = 1 },
    });
    gfx.commit();

    var out: [16]u8 = undefined;
    try expectRead(gfx.readImage(.{ .image = aimg, .mip_level = 1, .slice = 1 }, &out));
    for (0..16) |i| {
        if (out[i] != i + 1) {
            std.debug.print("mip 1 layer 1 byte {d} is {d}\n", .{ i, out[i] });
            return error.PixelMismatch;
        }
    }
    // mip 0 of layer 0 was never written
    var zeros: [64]u8 = @splat(0);
    try expectRead(gfx.readImage(.{ .image = aimg, .mip_level = 0, .slice = 0, .num_slices = 1 }, &zeros));
    for (zeros) |value| if (value != 0) return error.PixelMismatch;
}

/// A staging buffer written with write_transient, read at an unaligned offset.
fn testReadStagingBuffer(ctx: *const Ctx) !void {
    _ = ctx;
    const staging = gfx.makeBuffer(.{ .usage = .{ .staging_buffer = true, .write_transient = true, .copy_src = true }, .size = 16 });
    var data: [16]u8 = undefined;
    for (0..16) |i| data[i] = @intCast(100 + i);
    gfx.writeBufferTransient(.{ .dst = .{ .buffer = staging }, .src = .{ .data = gfx.Range.fromSlice(u8, &data) }, .size = 16 });
    gfx.commit();
    var out: [7]u8 = undefined;
    try expectRead(gfx.readBuffer(staging, 2, &out));
    try expectEqualBytes(data[2..9], &out);
}

const Scenario = struct { []const u8, *const fn (*const Ctx) anyerror!void };
const scenarios = [_]Scenario{
    .{ "1 writeBufferTransient over frames", testWriteBufferTransient },
    .{ "2 writeImageTransient over frames", testWriteImageTransient },
    .{ "3 write_unsealed buffer and image, sealed", testWriteUnsealed },
    .{ "4 copyBufferToBuffer and copyBufferToImage, sampled", testCopies },
    .{ "5 depth and stencil", testDepthStencil },
    .{ "6 4x MSAA with resolve", testMsaaResolve },
    .{ "7 render to texture, sampled in a second pass", testRenderToTexture },
    .{ "8 compute storage image, sampled", testComputeStorageImage },
    .{ "8b compute storage buffer", testComputeStorageBuffer },
    .{ "9 destroy/recreate over frames with uniform ring", testFramesAndUniformRing },
    .{ "10a blending and scissor", testBlendScissor },
    .{ "10b triangle strip with 16-bit indices", testStripIndexed },
    .{ "10c cube texture", testCubeTexture },
    .{ "10d array texture", testArrayTexture },
    .{ "R1 readImage of a rendered image", testReadRenderedImage },
    .{ "R2 readBuffer of storage buffer, unaligned", testReadStorageBuffer },
    .{ "R3 readImage sub-region, non-tight pitch", testReadImageRegion },
    .{ "R4 readImage array layer at mip 1", testReadArrayLayerMip },
    .{ "R5 readBuffer of staging buffer, unaligned", testReadStagingBuffer },
};

fn runSokolChecks(ctx: *const Ctx, resolver: *Resolver, device: Device, disable_cache: bool) !void {
    try gfx.setup(std.heap.page_allocator, .wgpu, .{
        .environment = .{
            .defaults = .{ .color_format = .rgba8, .depth_format = .none },
            .wgpu = .{
                .device = @ptrCast(device),
                .get_proc_address = Resolver.resolve,
                .user_data = resolver,
            },
        },
        .wgpu = .{ .disable_bindgroups_cache = disable_cache },
        .uniform_buffer_size = 1 << 16,
        .logger = .{ .func = logger },
    });
    defer gfx.shutdown();
    if (gfx.queryBackend() != .wgpu) return error.WrongBackend;
    std.debug.print("bindgroups cache {s}\n", .{if (disable_cache) "disabled" else "enabled"});
    for (scenarios) |scenario| {
        try scenario[1](ctx);
        if (logged_errors != 0) {
            std.debug.print("{d} sokol errors were logged\n", .{logged_errors});
            return error.SokolErrorsLogged;
        }
        std.debug.print("ok: {s}\n", .{scenario[0]});
    }
}

pub fn main() !void {
    const path = std.mem.span(std.c.getenv("WGPU_NATIVE_LIB") orelse {
        std.debug.print("set WGPU_NATIVE_LIB to the path of the wgpu-native shared library\n", .{});
        return error.MissingWgpuNativeLibrary;
    });
    var lib = try std.DynLib.open(path);
    defer lib.close();
    var resolver: Resolver = .{ .library = &lib };
    const procs = try loadProcs(Resolver.resolve, &resolver);

    const instance = procs.wgpuCreateInstance(null) orelse return error.InstanceFailed;
    var adapter_waiter: Waiter = .{};
    _ = procs.wgpuInstanceRequestAdapter(instance, null, .{
        .mode = callback_mode_allow_process_events,
        .callback = onAdapter,
        .userdata1 = &adapter_waiter,
    });
    try pumpUntil(instance, &procs, &adapter_waiter);
    if (adapter_waiter.status != 1) return error.AdapterFailed;
    const adapter = adapter_waiter.adapter orelse return error.AdapterFailed;

    var info: AdapterInfo = .{};
    if (procs.wgpuAdapterGetInfo(adapter, &info) != .success) return error.AdapterInfoFailed;
    const description = if (info.description.data) |data| data[0..info.description.length] else "";
    std.debug.print("adapter: {s} (backend type 0x{x}, adapter type 0x{x})\n", .{ description, @backingInt(info.backend_type), @backingInt(info.adapter_type) });
    std.debug.print("adapter vendor: {s}, device: {s}, architecture: {s}\n", .{ if (info.vendor.data) |d| d[0..info.vendor.length] else "", if (info.device.data) |d| d[0..info.device.length] else "", if (info.architecture.data) |d| d[0..info.architecture.length] else "" });

    // the device reports every WebGPU error through the uncaptured error callback
    // depth32float-stencil8 is advertised by the C backend's format table, and WebGPU requires the feature
    const required_features = [_]FeatureName{.depth32_float_stencil8};
    var device_desc: DeviceDescriptor = .{
        .required_feature_count = required_features.len,
        .required_features = &required_features,
        .uncaptured_error_callback_info = .{ .callback = onUncapturedError },
        .device_lost_callback_info = .{ .mode = callback_mode_allow_process_events, .callback = onDeviceLost },
    };
    var device_waiter: Waiter = .{};
    _ = procs.wgpuAdapterRequestDevice(adapter, &device_desc, .{
        .mode = callback_mode_allow_process_events,
        .callback = onDevice,
        .userdata1 = &device_waiter,
    });
    try pumpUntil(instance, &procs, &device_waiter);
    if (device_waiter.status != 1) return error.DeviceFailed;
    const device = device_waiter.device orelse return error.DeviceFailed;
    const queue = procs.wgpuDeviceGetQueue(device) orelse return error.QueueFailed;
    const ctx: Ctx = .{ .procs = procs, .instance = instance, .device = device, .queue = queue };

    // once with the bindgroups cache, once with a bindgroup created for every draw
    for ([_]bool{ false, true }) |disable_cache| {
        logged_errors = 0;
        try runSokolChecks(&ctx, &resolver, device, disable_cache);
    }
    try checkNoWgpuErrors();
    std.debug.print("wgpu-native smoke test passed\n", .{});
}
