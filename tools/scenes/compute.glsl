// Compute shaders of the cross-backend scene suite (sokol-shdc syntax).

// values[i] = base + i * step
@cs fill_buffer_cs
layout(binding=0) uniform fill_params { ivec4 base_step; };
struct item { uint value; };
layout(binding=0) buffer values_buf { item values[]; };
layout(local_size_x=64) in;
void main() {
    uint i = gl_GlobalInvocationID.x;
    values[i].value = uint(base_step.x) + i * uint(base_step.y);
}
@end
@program fill_buffer fill_buffer_cs

// a gradient: (x * 16, y * 16, 128, 255)
@cs fill_image_cs
layout(binding=0, rgba8) uniform writeonly image2D dst_image;
layout(local_size_x=8, local_size_y=4) in;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    imageStore(dst_image, p, vec4(float(p.x * 16) / 255.0, float(p.y * 16) / 255.0, 128.0 / 255.0, 1.0));
}
@end
@program fill_image fill_image_cs

// writes the vertices of a quad covering the given NDC rectangle, with a color
@cs gen_quad_cs
layout(binding=0) uniform gen_params { vec4 rect; vec4 color; };
struct vertex { vec4 pos; vec4 color; };
layout(binding=0) buffer vertices_buf { vertex vertices[]; };
layout(local_size_x=32) in;
void main() {
    uint i = gl_GlobalInvocationID.x;
    if (i >= 6u) { return; }
    vec2 corners[6] = vec2[6](vec2(0,0), vec2(1,0), vec2(1,1), vec2(0,0), vec2(1,1), vec2(0,1));
    vertices[i].pos = vec4(rect.xy + corners[i] * rect.zw, 0.0, 1.0);
    vertices[i].color = color;
}
@end
@program gen_quad gen_quad_cs

@cs fill_r32ui_cs
layout(binding=0, r32ui) uniform writeonly uimage2D dst_uint_image;
layout(local_size_x=8, local_size_y=4) in;
void main() {
    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    imageStore(dst_uint_image, p, uvec4(uint(p.x + p.y * 8 + 11), 0u, 0u, 0u));
}
@end
@program fill_r32ui fill_r32ui_cs

@cs fill_rgba16f_cs
layout(binding=0, rgba16f) uniform writeonly image2D dst_half_image;
layout(local_size_x=8, local_size_y=4) in;
void main() { imageStore(dst_half_image, ivec2(gl_GlobalInvocationID.xy), vec4(0.25, 0.5, 0.75, 1.0)); }
@end
@program fill_rgba16f fill_rgba16f_cs

@cs fill_rgba32f_cs
layout(binding=0, rgba32f) uniform writeonly image2D dst_float_image;
layout(local_size_x=8, local_size_y=4) in;
void main() { imageStore(dst_float_image, ivec2(gl_GlobalInvocationID.xy), vec4(0.25, 0.5, 0.75, 1.0)); }
@end
@program fill_rgba32f fill_rgba32f_cs
