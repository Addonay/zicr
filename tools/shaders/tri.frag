#version 450
// sokol SPIR-V convention: uniform blocks in descriptor set 0, textures, samplers
// and storage buffers in descriptor set 1.
layout(set = 0, binding = 0) uniform params {
    vec4 mul;
};
layout(set = 1, binding = 0) uniform texture2D tex;
layout(set = 1, binding = 1) uniform sampler smp;
layout(set = 1, binding = 2) readonly buffer values_sb {
    vec4 values[];
};
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(tex, smp), uv) * mul * values[0].x;
}
