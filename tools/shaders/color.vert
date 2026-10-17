#version 450
// float3 position and float4 color, stride 28.
layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color0;
layout(location = 0) out vec4 vcolor;
void main() {
    gl_Position = vec4(position, 1.0);
    vcolor = color0;
}
