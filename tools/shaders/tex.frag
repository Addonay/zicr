#version 450
// texture and sampler in descriptor set 1, sokol SPIR-V convention.
layout(set = 1, binding = 0) uniform texture2D tex;
layout(set = 1, binding = 1) uniform sampler smp;
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 frag_color;
void main() {
    frag_color = texture(sampler2D(tex, smp), uv);
}
