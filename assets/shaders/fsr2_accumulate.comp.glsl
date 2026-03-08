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

vec3 tonemap(vec3 c) {
    float luma = max(dot(c, vec3(0.299, 0.587, 0.114)), 0.0);
    return c / (1.0 + luma);
}

vec3 inverseTonemap(vec3 c) {
    float luma = max(dot(c, vec3(0.299, 0.587, 0.114)), 0.0);
    return c / max(1.0 - luma, 1e-4);
}

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

// Catmull-Rom bicubic (9 bilinear taps) with anti-ringing clamp.
vec3 sampleBicubic(sampler2D tex, vec2 uv, vec2 texSize) {
    vec2 invTexSize = 1.0 / texSize;
    vec2 iTc = uv * texSize;
    vec2 tc = floor(iTc - 0.5) + 0.5;
    vec2 f = iTc - tc;

    vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    vec2 w3 = f * f * (-0.5 + 0.5 * f);

    vec2 s12 = w1 + w2;
    vec2 offset12 = w2 / s12;

    vec2 tc0  = (tc - 1.0) * invTexSize;
    vec2 tc3  = (tc + 2.0) * invTexSize;
    vec2 tc12 = (tc + offset12) * invTexSize;

    vec3 result =
        (texture(tex, vec2(tc0.x,  tc0.y)).rgb  * w0.x +
         texture(tex, vec2(tc12.x, tc0.y)).rgb  * s12.x +
         texture(tex, vec2(tc3.x,  tc0.y)).rgb  * w3.x) * w0.y +
        (texture(tex, vec2(tc0.x,  tc12.y)).rgb * w0.x +
         texture(tex, vec2(tc12.x, tc12.y)).rgb * s12.x +
         texture(tex, vec2(tc3.x,  tc12.y)).rgb * w3.x) * s12.y +
        (texture(tex, vec2(tc0.x,  tc3.y)).rgb  * w0.x +
         texture(tex, vec2(tc12.x, tc3.y)).rgb  * s12.x +
         texture(tex, vec2(tc3.x,  tc3.y)).rgb  * w3.x) * w3.y;

    // Anti-ringing: clamp to range of the 4 nearest texels
    vec2 tcNear = tc * invTexSize;
    vec3 t00 = texture(tex, tcNear).rgb;
    vec3 t10 = texture(tex, tcNear + vec2(invTexSize.x, 0.0)).rgb;
    vec3 t01 = texture(tex, tcNear + vec2(0.0, invTexSize.y)).rgb;
    vec3 t11 = texture(tex, tcNear + invTexSize).rgb;
    vec3 minC = min(min(t00, t10), min(t01, t11));
    vec3 maxC = max(max(t00, t10), max(t01, t11));
    return clamp(result, minC, maxC);
}

void main() {
    ivec2 outPixel = ivec2(gl_GlobalInvocationID.xy);
    ivec2 outSize = ivec2(pc.displaySize.xy);
    if (outPixel.x >= outSize.x || outPixel.y >= outSize.y) return;

    vec2 outUV = (vec2(outPixel) + 0.5) * pc.displaySize.zw;

    vec3 currentColor = sampleBicubic(sceneColor, outUV, pc.internalSize.xy);

    if (pc.params.x > 0.5) {
        imageStore(historyOutput, outPixel, vec4(currentColor, 1.0));
        return;
    }

    // Depth-dilated motion vector (3x3 nearest-to-camera)
    vec2 texelSize = pc.internalSize.zw;
    float closestDepth = texture(depthBuffer, outUV).r;
    vec2 closestOffset = vec2(0.0);
    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 off = vec2(float(x), float(y)) * texelSize;
            float d = texture(depthBuffer, outUV + off).r;
            if (d < closestDepth) {
                closestDepth = d;
                closestOffset = off;
            }
        }
    }
    vec2 motion = texture(motionVectors, outUV + closestOffset).rg;
    float motionMag = length(motion * pc.displaySize.xy);

    vec2 historyUV = outUV + motion;
    float historyValid = (historyUV.x >= 0.0 && historyUV.x <= 1.0 &&
                          historyUV.y >= 0.0 && historyUV.y <= 1.0) ? 1.0 : 0.0;
    vec3 historyColor = texture(historyInput, historyUV).rgb;

    // === Tonemapped accumulation ===
    vec3 tmCurrent = tonemap(currentColor);
    vec3 tmHistory = tonemap(historyColor);

    // Neighborhood in tonemapped YCoCg
    vec3 s0 = rgbToYCoCg(tmCurrent);
    vec3 s1 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2(-texelSize.x, 0.0)).rgb));
    vec3 s2 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2( texelSize.x, 0.0)).rgb));
    vec3 s3 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2(0.0, -texelSize.y)).rgb));
    vec3 s4 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2(0.0,  texelSize.y)).rgb));
    vec3 s5 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2(-texelSize.x, -texelSize.y)).rgb));
    vec3 s6 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2( texelSize.x, -texelSize.y)).rgb));
    vec3 s7 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2(-texelSize.x,  texelSize.y)).rgb));
    vec3 s8 = rgbToYCoCg(tonemap(texture(sceneColor, outUV + vec2( texelSize.x,  texelSize.y)).rgb));

    vec3 m1 = s0 + s1 + s2 + s3 + s4 + s5 + s6 + s7 + s8;
    vec3 m2 = s0*s0 + s1*s1 + s2*s2 + s3*s3 + s4*s4 + s5*s5 + s6*s6 + s7*s7 + s8*s8;
    vec3 mean = m1 / 9.0;
    vec3 variance = max(m2 / 9.0 - mean * mean, vec3(0.0));
    vec3 stddev = sqrt(variance);

    float gamma = 1.5;
    vec3 boxMin = mean - gamma * stddev;
    vec3 boxMax = mean + gamma * stddev;

    // Compute clamped history and measure how far it was from the box
    vec3 tmHistYCoCg = rgbToYCoCg(tmHistory);
    vec3 clampedYCoCg = clamp(tmHistYCoCg, boxMin, boxMax);
    float clampDist = length(tmHistYCoCg - clampedYCoCg);

    // SELECTIVE CLAMP: only modify history when there's motion or disocclusion.
    // For static pixels, history is already well-accumulated — clamping it
    // each frame causes the clamp box (which shifts with jitter) to drag
    // the history around, creating visible shimmer. By leaving static history
    // untouched, accumulated anti-aliasing and detail is preserved.
    float needsClamp = max(
        clamp(motionMag * 2.0, 0.0, 1.0),      // motion → full clamp
        clamp(clampDist * 3.0, 0.0, 1.0)        // disocclusion → full clamp
    );
    tmHistory = yCoCgToRgb(mix(tmHistYCoCg, clampedYCoCg, needsClamp));

    // Blend: higher for good jitter samples, lower for poor ones.
    // Jitter-aware weighting: current frame's sample quality depends on
    // how close the jittered sample fell to this output pixel.
    vec2 jitterPx = pc.jitterOffset.xy * 0.5 * pc.internalSize.xy;
    vec2 internalPos = outUV * pc.internalSize.xy;
    vec2 subPixelOffset = fract(internalPos) - 0.5;
    vec2 sampleDelta = subPixelOffset - jitterPx;
    float dist2 = dot(sampleDelta, sampleDelta);
    float sampleQuality = exp(-dist2 * 3.0);
    float blendFactor = mix(0.03, 0.20, sampleQuality);

    // Disocclusion: aggressively replace stale history
    blendFactor = mix(blendFactor, 0.80, clamp(clampDist * 5.0, 0.0, 1.0));

    // Velocity: strong response during camera/object motion
    blendFactor = max(blendFactor, clamp(motionMag * 0.30, 0.0, 0.50));

    // Full current frame when history is out of bounds
    blendFactor = mix(blendFactor, 1.0, 1.0 - historyValid);

    // Blend in tonemapped space, inverse-tonemap back to linear
    vec3 tmResult = mix(tmHistory, tmCurrent, blendFactor);
    vec3 result = inverseTonemap(tmResult);

    imageStore(historyOutput, outPixel, vec4(result, 1.0));
}
