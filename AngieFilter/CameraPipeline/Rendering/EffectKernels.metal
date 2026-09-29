#include <CoreImage/CoreImage.h>
using namespace metal;

// Core Image kernels for the 实验室 looks. Built with -fcikernel into default.metallib.
// Working values are gamma-encoded Display P3, the same domain the source apps' shaders run in.

extern "C" {
namespace coreimage {

// Dazz `fishEye`: each output pixel reads c + normalize(d) * 0.6r / (1 - r²/factor²).
float2 dazzFisheye(float2 center, float factor, destination dest) {
    float2 d = dest.coord() - center;
    float r = length(d);
    if (r < 0.0001) {
        return center;
    }
    float denominator = max(1.0 - r * r / (factor * factor), 0.001);
    return center + d / r * (0.6 * r / denominator);
}

// Dazz `Aberration`: R, G, B step outward at 1, 1.5 and 2 times `blur`, scaled by the distance
// from the center, averaged over `samples` steps. Alpha is 1.
float4 dazzAberration(sampler image, float2 center, float halfDiagonal, float blur, float samples, destination dest) {
    float2 p = dest.coord();
    float2 d = p - center;
    float r = length(d);
    float2 direction = r > 0.0001 ? d / r : float2(0.0);
    float reach = blur * min(r / halfDiagonal, 1.0);
    int count = max(int(samples), 1);
    float3 sum = float3(0.0);
    for (int i = 0; i < count; i++) {
        float2 step = direction * reach * float(i) / float(count);
        sum.r += image.sample(image.transform(p - step)).r;
        sum.g += image.sample(image.transform(p - step * 1.5)).g;
        sum.b += image.sample(image.transform(p - step * 2.0)).b;
    }
    return float4(sum / float(count), 1.0);
}

// KAPI `fragSoftLight`, per channel, then mixed by alpha.
float4 kapiSoftLight(sample_t base, sample_t layer, float alpha) {
    float3 b = clamp(base.rgb, 0.0, 1.0);
    float3 t = layer.rgb;
    float3 low = 2.0 * b * t + b * b * (1.0 - 2.0 * t);
    float3 high = sqrt(b) * (2.0 * t - 1.0) + 2.0 * b * (1.0 - t);
    float3 blended = select(high, low, t < 0.5);
    return float4(mix(base.rgb, blended, alpha), base.a);
}

// KAPI multiply layer: (1 - alpha) b + alpha b t.
float4 kapiMultiply(sample_t base, sample_t layer, float alpha) {
    return float4(mix(base.rgb, base.rgb * layer.rgb, alpha), base.a);
}

// Highlights between two luma thresholds, scaled by exposure. KAPI's `Highlight.frag` body is not in
// the report; only its parameters are.
float4 brightPass(sample_t color, float low, float high, float exposure) {
    float luma = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    return float4(color.rgb * smoothstep(low, high, luma) * exposure, 1.0);
}

// What is left above a threshold, rescaled to 0...1. Halide's `halation_trim` cuts at 1 in linear HDR;
// SDR photos never reach that, so the threshold here is lower.
float4 halationTrim(sample_t color, float threshold) {
    float3 over = max(color.rgb - threshold, 0.0) / max(1.0 - threshold, 0.001);
    return float4(over, 1.0);
}

// Adds color and keeps the base alpha. CIAdditionCompositing adds alpha too.
float4 addColor(sample_t base, sample_t glow) {
    return float4(base.rgb + glow.rgb, base.a);
}

float4 subtractImage(sample_t a, sample_t b) {
    return float4(a.rgb - b.rgb, a.a);
}

// Halide MTF: low + 2 * smoothed residual. The 2 is hard-coded in Halide.
float4 mtfCombine(sample_t low, sample_t smoothed) {
    return float4(low.rgb + 2.0 * smoothed.rgb, low.a);
}

}
}
