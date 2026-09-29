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

// Colorimetric scene light is plainer than the phone's own rendering, which the preview is expanded from.
// Scaling chroma around luminance by `amount` brings the print's colorfulness back to the preview's.
static float3 saturated(float3 scene, float amount) {
    float y = dot(scene, p3Luma);
    return max(y + amount * (scene - y), 0.0);
}

// A linear ProRAW development to the same scene light: `gain` puts middle gray at 0.18.
// The sensor clips about four stops over gray, where a negative keeps going, so past `knee`
// the norm climbs `slope` times faster and a clipped lamp lands near display white's 12.
// The input is extended: values over 1 are highlights, not errors.
float4 screenLinear(sample_t color, float gain, float saturation, float knee, float slope) {
    float3 scene = saturated(decodeTransfer(max(color.rgb, 0.0)) * gain, saturation);
    float n = whiteness(scene);
    if (n > knee) {
        scene *= (n + (slope - 1.0) * (n - knee)) / n;
    }
    return float4(scene, color.a);
}

// Apple Log Profile White Paper, 2023. Same constants as Tools/ImportStormCamLUTs.swift.
static float appleLogDecode(float p) {
    const float r0 = -0.05641088;
    const float rt = 0.01;
    const float c = 47.28711236;
    const float beta = 0.00964052;
    const float gamma = 0.08550479;
    const float delta = 0.69336945;
    if (p >= c * (rt - r0) * (rt - r0)) {
        return exp2((p - delta) / gamma) - beta;
    }
    return p > 0.0 ? sqrt(p / c) + r0 : r0;
}

// Apple Log video frames, read with no color management, to scene light in linear Display P3.
// Apple Log already is scene light with 18% gray at 0.18; code value 1 is about 12, the same white the expansion uses.
float4 screenAppleLog(sample_t color, float gain, float saturation) {
    float3 wide = float3(appleLogDecode(color.r), appleLogDecode(color.g), appleLogDecode(color.b));
    float3 p3 = float3(dot(float3(1.343578, -0.282180, -0.061399), wide),
                       dot(float3(-0.065297, 1.075788, -0.010490), wide),
                       dot(float3(0.002822, -0.019598, 1.016777), wide));
    return float4(saturated(max(p3, 0.0) * gain, saturation), color.a);
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

// MARK: - 美颜, on gamma-encoded Display P3

// A face as an ellipse: center and radii in pixels, turned by `roll`. 1 over the inner 60%, then fading to 0.
static float faceEllipse(float2 p, float4 face, float roll) {
    if (face.z <= 0.0) {
        return 0.0;
    }
    float2 d = p - face.xy;
    float c = cos(roll);
    float s = sin(roll);
    float2 q = float2(c * d.x + s * d.y, c * d.y - s * d.x) / face.zw;
    return 1.0 - smoothstep(0.6, 1.0, length(q));
}

// Where the retouch acts, in R: inside a face, on colors bright enough and not blue enough to rule out skin.
// Hair, brows, and a blue background fall out; skin under a cool light stays in. `blurred` is the source
// blurred to a few percent of the face, so the mask has no texture of its own.
float4 skinMask(sample_t blurred, float4 face0, float4 face1, float4 face2, float4 face3, float4 rolls, destination dest) {
    float2 p = dest.coord();
    float inside = max(max(faceEllipse(p, face0, rolls.x), faceEllipse(p, face1, rolls.y)),
                       max(faceEllipse(p, face2, rolls.z), faceEllipse(p, face3, rolls.w)));
    float3 c = blurred.rgb;
    float y = dot(c, p3Luma);
    float skin = smoothstep(-0.12, -0.02, c.r - c.b) * smoothstep(0.08, 0.2, y);
    float m = inside * skin;
    return float4(m, m, m, 1.0);
}

// Small swings of a band go, large ones stay: spots and blotches are shallow, an eyelid or a nostril is not.
static float cored(float band, float threshold, float amount) {
    float t = band / threshold;
    return band * amount * exp(-t * t);
}

// Skin luma from four blurs of the frame, finest to widest. Detail finer than `fine` is left alone, so pores stay.
// The spot band (fine to mid) and the blotch band (mid to wide) lose their shallow swings; the shading band
// (wide to widest) is flattened by `fill`, as a fill light would. Every channel shifts by the same amount.
float4 skinSmooth(sample_t color, sample_t fine, sample_t mid, sample_t wide, sample_t widest, sample_t mask,
                  float spotThreshold, float blotchThreshold, float spots, float blotches, float fill) {
    float g1 = dot(fine.rgb, p3Luma);
    float g2 = dot(mid.rgb, p3Luma);
    float g3 = dot(wide.rgb, p3Luma);
    float g4 = dot(widest.rgb, p3Luma);
    float delta = cored(g1 - g2, spotThreshold, spots) + cored(g2 - g3, blotchThreshold, blotches) + (g3 - g4) * fill;
    return float4(color.rgb - delta * mask.r, color.a);
}

// Light scaled by what the smoothing did to the display pixel, through the same expansion as `screenExpand`,
// for a 银幕 print that starts from scene light.
static float expandedNorm(float n, float white) {
    float m = clamp(n, 0.0, 1.0);
    float w2 = white * white;
    float b = 1.0 - m;
    return (-b + sqrt(b * b + 4.0 * m / w2)) * w2 * 0.5;
}

float4 skinRelight(sample_t scene, sample_t display, sample_t smoothed, float white) {
    float before = expandedNorm(whiteness(decodeTransfer(clamp(display.rgb, 0.0, 1.0))), white);
    float after = expandedNorm(whiteness(decodeTransfer(clamp(smoothed.rgb, 0.0, 1.0))), white);
    float gain = before > 0.00001 ? after / before : 1.0;
    return float4(scene.rgb * gain, scene.a);
}

// Chroma as red and blue less luma, weighted by the mask, with the mask itself, so a blur of it
// averages skin's color and nothing around it.
float4 skinChromaPack(sample_t color, sample_t mask) {
    float y = dot(color.rgb, p3Luma);
    float m = mask.r;
    return float4((color.r - y) * m, (color.b - y) * m, m, 1.0);
}

// After the look: skin's color moves toward the face's average by `evenness`, which closes the gap between
// a lit cheek and a shaded one. Colors far from the average, lips and eyes, keep theirs. Then skin lifts
// toward white by `glow`, which brightens it and softens its contrast a little, as a screen would.
float4 skinFinish(sample_t color, sample_t average, sample_t mask, float evenness, float reach, float glow) {
    float3 c = color.rgb;
    float y = dot(c, p3Luma);
    float m = mask.r;
    float2 chroma = float2(c.r - y, c.b - y);
    float2 target = average.rg / max(average.b, 0.001);
    float2 gap = chroma - target;
    float pull = m * evenness * exp(-dot(gap, gap) / (reach * reach)) * smoothstep(0.02, 0.1, average.b);
    chroma -= gap * pull;
    float r = y + chroma.x;
    float b = y + chroma.y;
    float3 even = float3(r, (y - p3Luma.r * r - p3Luma.b * b) / p3Luma.g, b);
    return float4(even + (1.0 - clamp(even, 0.0, 1.0)) * m * glow, color.a);
}

// 运镜 zoom blur: the picture as if the zoom moved while the shutter was open. Zooming in by `spread` during the
// exposure moves every point outward, so each pixel averages what lay between it and 1 − spread of the way from the
// center; a negative spread is zooming out and reaches outward instead.
float4 zoomBlur(sampler image, float2 center, float spread, float samples, destination dest) {
    float2 p = dest.coord();
    float2 d = p - center;
    int count = max(int(samples), 2);
    float4 sum = float4(0.0);
    for (int i = 0; i < count; i++) {
        float scale = 1.0 - spread * float(i) / float(count - 1);
        sum += image.sample(image.transform(center + d * scale));
    }
    return sum / float(count);
}

}
}
