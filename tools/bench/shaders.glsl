@vs vs
layout(location=0) in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
@end
@fs fs
layout(binding=0) uniform fs_params { vec4 tint; };
layout(location=0) out vec4 frag_color;
void main() { frag_color = tint; }
@end
@program bench vs fs
