#version 450

layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0) uniform sampler2D sceneColor;
layout(set = 0, binding = 1) uniform sampler2D depthBuffer;
layout(set = 0, binding = 2) uniform sampler2D motionVectors;
layout(set = 0, binding = 3) uniform sampler2D historyInput;
layout(set = 0, binding = 4, rgba16f) uniform writeonly image2D historyOutput;

layout(push_constant) uniform PushConstants {
    vec4 internalSize;   // xy = internal resolution, zw = 1/internal
    vec4 displaySize;    // xy = display resolution, zw = 1/display
    vec4 jitterOffset;   // xy = current jitter (NDC-space), zw = unused
    vec4 params;         // x = resetHistory (1=reset), y = sharpness, zw = unused
} pc;

vec3 rgbToYCoCg(vec3 rgb) {
    float y  = 0.25 * rgb.r + 0.5 * rgb.g + 0.25 * rgb.b;
    float co = 0.5  * rgb.r                - 0.5  * rgb.b;
    float cg = -0.25 * rgb.r + 0.5 * rgb.g - 0.25 * rgb.b;
    return vec3(y, co, cg);
}

vec3 yCoCgToRgb(vec3 ycocg) {
    float y  = ycocg.x;
    float co = ycocg.y;
    float cg = ycocg.z;
    return vec3(y + co - cg, y + cg, y - co - cg);
}

void main() {
    ivec2 outPixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 outSize = ivec2(pc.displaySize.xy);
    if (outPixel.x >= outSize.x || outPixel.y >= outSize.y) return;

    vec2 outUV = (vec2(outPixel) + 0.5) * pc.displaySize.zw;
    vec3 currentColor = texture(sceneColor, outUV).rgb;

    if (pc.params.x > 0.5) {
        imageStore(historyOutput, outPixel, vec4(currentColor, 1.0));
        return;
    }

    vec2 motion = texture(motionVectors, outUV).rg;
    vec2 historyUV = outUV + motion;

    float historyValid = (historyUV.x >= 0.0 && historyUV.x <= 1.0 &&
                          historyUV.y >= 0.0 && historyUV.y <= 1.0) ? 1.0 : 0.0;

    vec3 historyColor = texture(historyInput, historyUV).rgb;

    // Neighborhood clamping in YCoCg space
    vec2 texelSize = pc.internalSize.zw;
    vec3 s0 = rgbToYCoCg(currentColor);
    vec3 s1 = rgbToYCoCg(texture(sceneColor, outUV + vec2(-texelSize.x, 0.0)).rgb);
    vec3 s2 = rgbToYCoCg(texture(sceneColor, outUV + vec2( texelSize.x, 0.0)).rgb);
    vec3 s3 = rgbToYCoCg(texture(sceneColor, outUV + vec2(0.0, -texelSize.y)).rgb);
    vec3 s4 = rgbToYCoCg(texture(sceneColor, outUV + vec2(0.0,  texelSize.y)).rgb);
    vec3 s5 = rgbToYCoCg(texture(sceneColor, outUV + vec2(-texelSize.x, -texelSize.y)).rgb);
    vec3 s6 = rgbToYCoCg(texture(sceneColor, outUV + vec2( texelSize.x, -texelSize.y)).rgb);
    vec3 s7 = rgbToYCoCg(texture(sceneColor, outUV + vec2(-texelSize.x,  texelSize.y)).rgb);
    vec3 s8 = rgbToYCoCg(texture(sceneColor, outUV + vec2( texelSize.x,  texelSize.y)).rgb);

    vec3 m1 = s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7 + s8;
    vec3 m2 = s0*s0 + s1*s1 + s2*s2 + s3*s3 + s4*s4 + s5*s5 + s6*s6 + s7*s7 + s8*s8;
    vec3 mean = m1 / 9.0;
    vec3 variance = max(m2 / 9.0 - mean * mean, vec3(0.0));
    vec3 stddev = sqrt(variance);

    float gamma = 1.5;
    vec3 boxMin = mean - gamma * stddev;
    vec3 boxMax = mean + gamma * stddev;

    vec3 historyYCoCg = rgbToYCoCg(historyColor);
    vec3 clampedHistory = clamp(historyYCoCg, boxMin, boxMax);
    historyColor = yCoCgToRgb(clampedHistory);

    float clampDist = length(historyYCoCg - clampedHistory);
    float blendFactor = mix(0.05, 0.30, clamp(clampDist * 2.0, 0.0, 1.0));
    blendFactor = mix(blendFactor, 1.0, 1.0 - historyValid);

    vec3 result = mix(historyColor, currentColor, blendFactor);
    imageStore(historyOutput, outPixel, vec4(result, 1.0));
}
