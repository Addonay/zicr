// Render shaders of the cross-backend scene suite (sokol-shdc syntax).
// NDC is y-up on every backend, texture coordinate (0,0) is the first texel row.

// vertex colors, transformed by offset (xy) and scale (zw), tinted
@vs color_vs
layout(binding=0) uniform color_vs_params { vec4 offset_scale; };
in vec3 position;
in vec4 color0;
out vec4 color;
void main() {
    gl_Position = vec4(position.xy * offset_scale.zw + offset_scale.xy, position.z, 1.0);
    color = color0;
}
@end
@fs color_fs
layout(binding=1) uniform color_fs_params { vec4 tint; };
in vec4 color;
out vec4 frag_color;
void main() { frag_color = color * tint; }
@end
@program color color_vs color_fs

// per-instance offset and color
@vs instanced_vs
in vec2 position;
in vec4 inst_offset;
in vec4 inst_color;
out vec4 color;
void main() {
    gl_Position = vec4(position + inst_offset.xy, 0.0, 1.0);
    color = inst_color;
}
@end
@program instanced instanced_vs color_fs

// textured quads; lod_layer = (lod, array layer or 3d depth, cube face, unused)
@vs tex_vs
in vec2 position;
in vec2 texcoord0;
out vec2 uv;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = texcoord0;
}
@end
@fs tex_fs
layout(binding=0) uniform tex_fs_params { vec4 lod_layer; };
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 uv;
out vec4 frag_color;
void main() { frag_color = textureLod(sampler2D(tex, smp), uv, lod_layer.x); }
@end
@program textured tex_vs tex_fs

@fs tex_array_fs
layout(binding=0) uniform tex_fs_params { vec4 lod_layer; };
layout(binding=0) uniform texture2DArray tex_array;
layout(binding=0) uniform sampler smp;
in vec2 uv;
out vec4 frag_color;
void main() { frag_color = textureLod(sampler2DArray(tex_array, smp), vec3(uv, lod_layer.y), lod_layer.x); }
@end
@program textured_array tex_vs tex_array_fs

@fs tex_3d_fs
layout(binding=0) uniform tex_fs_params { vec4 lod_layer; };
layout(binding=0) uniform texture3D tex_3d;
layout(binding=0) uniform sampler smp;
in vec2 uv;
out vec4 frag_color;
void main() { frag_color = textureLod(sampler3D(tex_3d, smp), vec3(uv, lod_layer.y), 0.0); }
@end
@program textured_3d tex_vs tex_3d_fs

// samples the center of a cube face: lod_layer.z is the face index (+X, -X, +Y, -Y, +Z, -Z)
@fs tex_cube_fs
layout(binding=0) uniform tex_fs_params { vec4 lod_layer; };
layout(binding=0) uniform textureCube tex_cube;
layout(binding=0) uniform sampler smp;
in vec2 uv;
out vec4 frag_color;
void main() {
    int face = int(lod_layer.z);
    vec3 dirs[6] = vec3[6](vec3(1,0,0), vec3(-1,0,0), vec3(0,1,0), vec3(0,-1,0), vec3(0,0,1), vec3(0,0,-1));
    frag_color = textureLod(samplerCube(tex_cube, smp), dirs[face], 0.0);
}
@end
@program textured_cube tex_vs tex_cube_fs

// two color attachments
@vs mrt_vs
in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
@end
@fs mrt_fs
layout(binding=0) uniform mrt_fs_params { vec4 color_a; vec4 color_b; };
layout(location=0) out vec4 frag_a;
layout(location=1) out vec4 frag_b;
void main() { frag_a = color_a; frag_b = color_b; }
@end
@program mrt mrt_vs mrt_fs
