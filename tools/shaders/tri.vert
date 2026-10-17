#version 450
// Full vertex layout of the smoke test: float2 position, float2 texcoord.
layout(location = 0) in vec2 position;
layout(location = 1) in vec2 texcoord0;
layout(location = 0) out vec2 uv;
void main() {
    gl_Position = vec4(position, 0.0, 1.0);
    uv = texcoord0;
}
