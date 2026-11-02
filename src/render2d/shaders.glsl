// Straight-alpha sampled images, linear-light color, premultiplied output.
@vs quad_vs
in vec2 position;
in vec2 texcoord0;
in vec4 color0;
in float premultiplied;
out vec2 uv;
out vec4 tint;
out float alpha_mode;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = texcoord0;
    tint = color0;
    alpha_mode = premultiplied;
}
@end
@fs quad_fs
layout(binding=0) uniform texture2D tex;
layout(binding=0) uniform sampler smp;
in vec2 uv;
in vec4 tint;
in float alpha_mode;
out vec4 frag_color;
void main() {
    vec4 sample_color = texture(sampler2D(tex, smp), uv);
    frag_color = vec4(sample_color.rgb * mix(sample_color.a, 1.0, alpha_mode), sample_color.a) * tint;
}
@end
@program quad quad_vs quad_fs
