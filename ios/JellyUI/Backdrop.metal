#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The web's backdrop: the cover, shrunk to 6x6 soft colour fields, bent by five layered waves and a slow swirl.
// The cover arrives as 36 colours per picture (a float array: r, g, b per cell), so nothing is sampled from a texture.

static float3 cell(constant float *a, int x, int y) {
    x = clamp(x, 0, 5);
    y = clamp(y, 0, 5);
    int o = (y * 6 + x) * 3;
    return float3(a[o], a[o + 1], a[o + 2]);
}

// quintic-smoothed bilinear lookup at q in 0..1, the web's tx()
static float3 tx(constant float *a, float2 q) {
    float2 st = q * 6.0 - 0.5; // cell centres sit at (i + .5) / 6
    float2 i = floor(st);
    float2 f = st - i;
    f = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    int ix = int(i.x);
    int iy = int(i.y);
    float3 c00 = cell(a, ix, iy);
    float3 c10 = cell(a, ix + 1, iy);
    float3 c01 = cell(a, ix, iy + 1);
    float3 c11 = cell(a, ix + 1, iy + 1);
    return mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y) * 0.35;
}

[[ stitchable ]] half4 fluid(float2 position, half4 color, float2 size, float time, float mixAB, constant float *a, int na, constant float *b, int nb) {
    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
    float2 p = (uv - 0.5) * float2(size.x / size.y, 1.0) * 1.9;
    float t = time * 0.5;
    for (int i = 0; i < 5; i++) {
        float f = float(i);
        float w = f * 1.9 + t * (0.08 + f * 0.021);
        float2 d = float2(cos(w), sin(w));
        float2 n = float2(-d.y, d.x);
        float ph = dot(p, d) * (0.95 + f * 0.55) + t * (0.27 + f * 0.083) + f * 1.7;
        p += 1.05 / (1.0 + f * 0.45) * (n * sin(ph) + d * 0.6 * cos(ph * 0.7 + f));
    }
    float r = length(p);
    float ang = 2.4 * sin(t * 0.045) + 1.5 * r * cos(t * 0.031 + 1.0);
    p = float2(cos(ang) * p.x - sin(ang) * p.y, sin(ang) * p.x + cos(ang) * p.y);
    float2 q = 0.5 + 0.5 * sin(p * 0.85);

    bool two = mixAB > 0.001;
    float3 ca = tx(a, q) * 3.0;
    float3 cb = ca;
    if (two) cb = tx(b, q) * 3.0;
    for (int i = 0; i < 4; i++) {
        float g = float(i) * 1.5708 + 0.39;
        float2 d = float2(cos(g), sin(g));
        float2 o1 = d * 0.22;
        float2 o2 = d * 0.46;
        ca += tx(a, q + o1) * 1.5 + tx(a, q + o2);
        if (two) cb += tx(b, q + o1) * 1.5 + tx(b, q + o2);
    }
    ca /= 3.0 + 4.0 * 2.5;
    cb /= 3.0 + 4.0 * 2.5;
    float3 ma = (tx(a, float2(0.25, 0.25)) + tx(a, float2(0.75, 0.25)) + tx(a, float2(0.25, 0.75)) + tx(a, float2(0.75, 0.75))) * 0.25;
    float3 mb = ma;
    if (two) mb = (tx(b, float2(0.25, 0.25)) + tx(b, float2(0.75, 0.25)) + tx(b, float2(0.25, 0.75)) + tx(b, float2(0.75, 0.75))) * 0.25;
    ca = mix(ca, ma, 0.75);
    cb = mix(cb, mb, 0.75);
    if (!two) cb = ca;
    // lifts the darkened picture to about 60 %, and holds a pale cover down so light lyrics stand out
    float3 c = min(mix(ca, cb, mixAB) * 1.75, float3(1.0));
    float L = dot(c, float3(0.299, 0.587, 0.114));
    c /= 1.0 + max(L - 0.36, 0.0) * 1.9;
    return half4(half3(c), 1.0h);
}
