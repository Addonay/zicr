// Feature-specific shaders omit targets whose translators lack the feature.
@vs feature_vs
layout(location=0) in vec2 position;
void main() { gl_Position = vec4(position, 0.0, 1.0); }
@end
@fs dual_source_fs
layout(location=0, index=0) out vec4 primary_color;
layout(location=0, index=1) out vec4 secondary_color;
void main() {
    primary_color = vec4(1.0);
    secondary_color = vec4(0.25, 0.5, 0.75, 1.0);
}
@end
@program dual_source feature_vs dual_source_fs

@fs multisample_fs
layout(binding=0) uniform texture2DMS sampled_msaa;
layout(binding=0) uniform sampler msaa_sampler;
out vec4 frag_color;
void main() {
    // Average all four actual samples, without resolving to a single-sample
    // image first. This exercises the multisampled shader/view declaration.
    ivec2 pixel = ivec2(0, 0);
    frag_color = (texelFetch(sampler2DMS(sampled_msaa, msaa_sampler), pixel, 0) +
                  texelFetch(sampler2DMS(sampled_msaa, msaa_sampler), pixel, 1) +
                  texelFetch(sampler2DMS(sampled_msaa, msaa_sampler), pixel, 2) +
                  texelFetch(sampler2DMS(sampled_msaa, msaa_sampler), pixel, 3)) * 0.25;
}
@end
@program multisample feature_vs multisample_fs
