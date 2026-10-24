#include <metal_stdlib>
#include <CoreImage/CoreImage.h>
using namespace metal;

// Hash without sine (Dave Hoskins).
inline float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

inline float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + float2(1.0, 0.0));
    float c = hash12(i + float2(0.0, 1.0));
    float d = hash12(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Two octaves so grain clumps irregularly instead of sitting on a grid. Zero mean.
inline float grainNoise(float2 p) {
    return valueNoise(p) * 0.7 + valueNoise(p * 2.03 + 17.17) * 0.3 - 0.5;
}

extern "C" {
namespace coreimage {

// Scene-linear light to the encoding the film LUT is indexed by: stops around 18% gray.
float4 shaper(sample_t s, float gain, float floorStops, float range) {
    float3 stops = log2(max(s.rgb * gain, 1e-6) / 0.18);
    return float4(clamp((stops + floorStops) / range, 0.0, 1.0), 1.0);
}

// Light above a threshold: the part that scatters back through the base as halation.
float4 highlights(sample_t s, float threshold) {
    float y = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float h = max(y - threshold, 0.0);
    return float4(h, h, h, 1.0);
}

float4 addGlow(sample_t s, sample_t glow, float3 tint) {
    return float4(s.rgb + glow.rgb * tint, s.a);
}

// Adds one aligned RAW frame to a running merge kept in premultiplied form:
// rgb = Σ w·color, a = Σ w (weights normalized to sum to at most 1), so unpremultiplying gives the mean.
// A frame counts less where it's clipped, and where it disagrees with the reference (motion, misalignment).
// Agreement is judged on blurred copies, so sensor noise itself isn't mistaken for motion.
float4 accumulateFrame(sample_t acc, sample_t frame, sample_t ref, sample_t frameLow, sample_t refLow,
                       float gain, float weight, float clip, float tolerance) {
    float3 color = frame.a > 0.0 ? frame.rgb / frame.a : float3(0.0);
    float3 matched = color * gain;
    float3 matchedLow = (frameLow.a > 0.0 ? frameLow.rgb / frameLow.a : float3(0.0)) * gain;
    // Developed RAW rolls off well before it clips, and the roll-off isn't linear, so stop trusting early.
    float peak = max(color.r, max(color.g, color.b));
    float unclipped = 1.0 - smoothstep(0.65 * clip, clip, peak);
    float refPeak = max(ref.r, max(ref.g, ref.b));
    float refUsable = 1.0 - smoothstep(0.65 * clip, clip, refPeak);
    float difference = length(matchedLow - refLow.rgb) / (length(refLow.rgb) + 0.01);
    float agreement = mix(1.0, exp(-(difference * difference) / (tolerance * tolerance)), refUsable);
    float w = weight * unclipped * agreement * step(0.5, frame.a);
    return float4(acc.rgb + matched * w, acc.a + w);
}

// Where almost nothing could be trusted (everything clipped), fall back to the reference
// smoothly instead of dividing tiny half-float numbers.
float4 resolveMerge(sample_t acc, sample_t ref) {
    float3 mean = acc.rgb / max(acc.a, 1e-4);
    return float4(mix(ref.rgb, mean, smoothstep(0.0, 0.05, acc.a)), 1.0);
}

// Grain is added before the film curve, like density on the negative,
// so the curve itself decides how much of it survives in shadows and highlights.
float4 grain(sample_t s, float amount, float size, float chroma, float2 seed, destination dest) {
    float2 p = (dest.coord() + seed) / size;
    float luma = grainNoise(p);
    float3 dye = float3(grainNoise(p + 101.3), luma, grainNoise(p + 211.7));
    float3 g = mix(float3(luma), dye, chroma);
    return float4(clamp(s.rgb + g * amount, 0.0, 1.0), s.a);
}

// Catmull-Rom resampling onto a finer grid, for super-resolution: output pixel p reads the source at
// m · p + offset, an affine that carries the zoom and the frame's alignment. Sharper than bilinear, without
// Lanczos's ringing.
float4 resample(sampler src, float4 m, float2 offset, destination dest) {
    float2 c = dest.coord();
    float2 q = float2(m.x * c.x + m.y * c.y, m.z * c.x + m.w * c.y) + offset - 0.5;
    float2 base = floor(q);
    float2 t = q - base;
    float2 t2 = t * t;
    float2 t3 = t2 * t;
    float2 w0 = 0.5 * (-t3 + 2.0 * t2 - t);
    float2 w1 = 0.5 * (3.0 * t3 - 5.0 * t2 + 2.0);
    float2 w2 = 0.5 * (-3.0 * t3 + 4.0 * t2 + t);
    float2 w3 = 0.5 * (t3 - t2);
    float wx[4] = { w0.x, w1.x, w2.x, w3.x };
    float wy[4] = { w0.y, w1.y, w2.y, w3.y };
    float4 sum = float4(0.0);
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float2 p = base + float2(float(i) - 1.0, float(j) - 1.0) + 0.5;
            sum += src.sample(src.transform(p)) * (wx[i] * wy[j]);
        }
    }
    return float4(sum.rgb, 1.0);
}

// Unsharp mask in square-root space, so bright edges don't get dark halos.
float4 sharpenRoot(sample_t s, sample_t blurredRoot, float amount) {
    float3 root = sign(s.rgb) * sqrt(abs(s.rgb));
    float3 r = root + amount * (root - blurredRoot.rgb);
    return float4(sign(r) * r * r, s.a);
}

// MARK: Raw development (RGGB mosaic, rows counted from the top of the sensor)

// Black level, white balance and clip, per photosite. Flare is a neutral veil, so it comes off after white
// balance, equally in every channel. Clipping everything at green's ceiling keeps blown highlights white
// instead of pink. Values below black stay negative so stacked noise averages out unbiased.
float4 bayerPrep(sample_t s, float black, float range, float3 gains, float flare, float height, destination dest) {
    float2 c = dest.coord();
    int col = int(c.x);
    int row = int(height - c.y);
    float gain = (row & 1) == 0 ? ((col & 1) == 0 ? gains.r : gains.g) : ((col & 1) == 0 ? gains.g : gains.b);
    float v = min((s.r * 65535.0 - black) / range * gain, 1.0) - flare;
    return float4(v, v, v, 1.0);
}

// Malvar-He-Cutler demosaic: bilinear interpolation corrected by the local gradient of the channel
// that was measured, 5×5 and linear, sharp without zippering.
float4 demosaic(sampler m, float height, destination dest) {
    float2 c = dest.coord();
    int col = int(c.x);
    int row = int(height - c.y);
    #define P(dx, dy) m.sample(m.transform(c + float2(dx, dy))).r
    float center = P(0, 0);
    float h1 = P(-1, 0) + P(1, 0);
    float v1 = P(0, -1) + P(0, 1);
    float h2 = P(-2, 0) + P(2, 0);
    float v2 = P(0, -2) + P(0, 2);
    float diagonals = P(-1, -1) + P(1, -1) + P(-1, 1) + P(1, 1);
    #undef P
    float greenAtRedBlue = (4.0 * center + 2.0 * (h1 + v1) - (h2 + v2)) / 8.0;
    float opposite = (6.0 * center + 2.0 * diagonals - 1.5 * (h2 + v2)) / 8.0;
    float fromRow = (5.0 * center + 4.0 * h1 - h2 - diagonals + 0.5 * v2) / 8.0;
    float fromColumn = (5.0 * center + 4.0 * v1 - v2 - diagonals + 0.5 * h2) / 8.0;
    bool evenRow = (row & 1) == 0;
    bool evenCol = (col & 1) == 0;
    float3 rgb;
    if (evenRow && evenCol) {
        rgb = float3(center, greenAtRedBlue, opposite);
    } else if (!evenRow && !evenCol) {
        rgb = float3(opposite, greenAtRedBlue, center);
    } else if (evenRow) {
        // Green on a red row: red left and right, blue above and below.
        rgb = float3(fromRow, center, fromColumn);
    } else {
        rgb = float3(fromColumn, center, fromRow);
    }
    return float4(rgb, 1.0);
}

// Camera color to linear sRGB, lens vignetting taken out, exposure normalized.
float4 rawColor(sample_t s, float3 r0, float3 r1, float3 r2, float exposure, float4 k, float k4,
                float2 center, float2 size, destination dest) {
    float3 rgb = float3(dot(r0, s.rgb), dot(r1, s.rgb), dot(r2, s.rgb));
    float2 d = dest.coord() - center * size;
    float2 corner = max(center, 1.0 - center) * size;
    float rr = dot(d, d) / dot(corner, corner);
    float gain = 1.0 + rr * (k.x + rr * (k.y + rr * (k.z + rr * (k.w + rr * k4))));
    return float4(rgb * gain * exposure, 1.0);
}

// Chroma noise reduction in square-root space, where sensor noise is about even from shadow to highlight:
// lightness from the sharp image, color from a blurred copy. What's left looks like grain, not confetti.
float4 rootRGB(sample_t s) {
    return float4(sign(s.rgb) * sqrt(abs(s.rgb)), s.a);
}

float4 chromaMerge(sample_t sharp, sample_t blurredRoot) {
    float3 w = float3(0.2126, 0.7152, 0.0722);
    float3 root = sign(sharp.rgb) * sqrt(abs(sharp.rgb));
    float3 g = dot(root, w) + (blurredRoot.rgb - dot(blurredRoot.rgb, w));
    return float4(sign(g) * g * g, sharp.a);
}

float4 addFrames(sample_t a, sample_t b) {
    return float4(a.rgb + b.rgb, 1.0);
}

float4 diffuse(sample_t s, sample_t tight, sample_t wide, float strength) {
    return float4(mix(s.rgb, 0.55 * tight.rgb + 0.45 * wide.rgb, strength), s.a);
}

// Zebras: moving diagonal stripes over whatever is about to clip, as on a cinema monitor.
float4 zebra(sample_t s, float threshold, float phase, destination dest) {
    float2 c = dest.coord();
    float luma = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float stripe = step(0.5, fract((c.x + c.y + phase) / 14.0));
    float on = step(threshold, luma) * stripe;
    return float4(mix(s.rgb, float3(0.0), on * 0.6), s.a);
}

// Focus peaking: paints edges of the (scene) image that are sharp enough over the film rendering.
float4 peaking(sampler film, sampler scene, float threshold, destination dest) {
    float2 c = dest.coord();
    float3 w = float3(0.2126, 0.7152, 0.0722);
    #define L(dx, dy) sqrt(max(dot(scene.sample(scene.transform(c + float2(dx, dy))).rgb, w), 0.0))
    float tl = L(-1, 1), t = L(0, 1), tr = L(1, 1);
    float l = L(-1, 0), r = L(1, 0);
    float bl = L(-1, -1), b = L(0, -1), br = L(1, -1);
    #undef L
    float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
    float gy = (tl + 2.0 * t + tr) - (bl + 2.0 * b + br);
    float edge = smoothstep(threshold, threshold * 1.5, length(float2(gx, gy)) * 0.25);
    float4 f = film.sample(film.transform(c));
    return float4(mix(f.rgb, float3(1.0, 0.2, 0.06), edge), f.a);
}

}
}
