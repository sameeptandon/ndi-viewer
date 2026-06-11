#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 texCoords;
};

// Simple vertex shader generating a full screen quad from vertex ID
vertex VertexOutput vertexShader(uint vertexId [[vertex_id]]) {
    VertexOutput out;
    
    // Texture coordinates mapped to [0.0, 1.0]
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    // Position mapped to clip space [-1.0, 1.0]
    float4 positions[4] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0)
    };
    
    out.position = positions[vertexId];
    out.texCoords = texCoords[vertexId];
    return out;
}

// Fragment shader sampling from the NDI BGRA texture
fragment float4 fragmentShader(VertexOutput in [[stage_in]],
                               texture2d<float> colorTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return colorTexture.sample(textureSampler, in.texCoords);
}
