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

// MARK: - 银幕 optics, in scene light

// Display P3 luminance.
constant float3 p3Luma = float3(0.2290, 0.6917, 0.0793);

static float3 decodeTransfer(float3 v) {
    return select(pow((v + 0.055) / 1.055, 2.4), v / 12.92, v <= 0.04045);
}

static float3 encodeTransfer(float3 v) {
    return select(1.055 * pow(v, 1.0 / 2.4) - 0.055, v * 12.92, v <= 0.0031308);
}

// How close to white a pixel is: half luminance, half the lowest channel. Same norm as Tools/BakeScreenLUTs.py.
static float whiteness(float3 v) {
    return (dot(v, p3Luma) + min(v.r, min(v.g, v.b))) * 0.5;
}

// Display to scene light: inverse extended Reinhard on the norm, display white to `white`, 18% gray kept.
float4 screenExpand(sample_t color, float white, float grayScale) {
    float3 linear = decodeTransfer(clamp(color.rgb, 0.0, 1.0));
    float n = whiteness(linear);
    if (n <= 0.0) {
        return float4(0.0, 0.0, 0.0, color.a);
    }
    float m = min(n, 1.0);
    float w2 = white * white;
    float b = 1.0 - m;
    float s = (-b + sqrt(b * b + 4.0 * m / w2)) * w2 * 0.5;
    return float4(linear * (s * grayScale / n), color.a);
}

// A linear ProRAW development to the same scene light: `gain` puts middle gray at 0.18.
// The sensor clips about four stops over gray, where a negative keeps going, so past `knee`
// the norm climbs `slope` times faster and a clipped lamp lands near display white's 12.
float4 screenLinear(sample_t color, float gain, float knee, float slope) {
    float3 scene = decodeTransfer(max(color.rgb, 0.0)) * gain;
    float n = whiteness(scene);
    if (n > knee) {
        scene *= (n + (slope - 1.0) * (n - knee)) / n;
    }
    return float4(scene, color.a);
}

// Exact inverse of `screenExpand`. Light pushed past scene white clips to display white.
float4 screenCompress(sample_t color, float white, float grayScale) {
    float3 scene = max(color.rgb, 0.0);
    float n = whiteness(scene);
    if (n <= 0.0) {
        return float4(0.0, 0.0, 0.0, color.a);
    }
    float s = n / grayScale;
    float m = min(s * (1.0 + s / (white * white)) / (1.0 + s), 1.0);
    return float4(encodeTransfer(clamp(scene * (m / n), 0.0, 1.0)), color.a);
}

// A mist filter moves a share of every pixel's light into a near and a far halo. Energy is kept.
float4 screenMist(sample_t scene, sample_t near, sample_t far, float share) {
    float3 halo = (near.rgb + far.rgb) * 0.5;
    return float4(scene.rgb + share * (halo - scene.rgb), scene.a);
}

// Only light well above diffuse white reaches the film base and bounces back.
float4 screenBright(sample_t scene, float threshold) {
    return float4(max(scene.rgb - threshold, 0.0), 1.0);
}

// The bounce exposes the red layer first, so the glow is red-orange whatever color the source is.
float4 screenHalation(sample_t scene, sample_t near, sample_t far, float gain, float3 tint) {
    float glow = dot(near.rgb * 0.6 + far.rgb * 0.4, p3Luma);
    return float4(scene.rgb + gain * glow * tint, scene.a);
}

}
}
