// The clock's liquid: digits like water over whatever is behind them. Used by LockClock (LockView.swift) through
// SwiftUI's shader effects; build-app.sh compiles this into the app's default.metallib.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The digits' outline ripples slowly, like a surface of water.
[[ stitchable ]] float2 liquidWave(float2 position, float t) {
    float2 w = float2(sin(position.y * 0.050 + t * 2.1) + 0.5 * sin(position.y * 0.11 - t * 1.3),
                      cos(position.x * 0.045 + t * 1.7) + 0.5 * cos(position.x * 0.09 + t * 1.1));
    return position + w * 1.8;
}

// Edge strength and which way the edge faces, from the digits' own shape.
static float2 edgeGradient(float2 p, SwiftUI::Layer layer) {
    float e = 2.0;
    return float2(layer.sample(p + float2(e, 0)).a - layer.sample(p - float2(e, 0)).a,
                  layer.sample(p + float2(0, e)).a - layer.sample(p - float2(0, e)).a);
}

// Light added on top of the picture behind (drawn with "plus lighter"): almost clear in the body with moving
// caustics, like light through water, and bright where an edge faces the light.
[[ stitchable ]] half4 liquidShine(float2 position, SwiftUI::Layer layer, float t) {
    float a = layer.sample(position).a;
    if (a < 0.01) return half4(0);
    float2 g = edgeGradient(position, layer);
    float edge = clamp(length(g) * 1.3, 0.0, 1.0);
    float facing = clamp(dot(normalize(g + 1e-5), normalize(float2(0.45, 0.9))), 0.0, 1.0);  // y grows downward
    float2 q = position * 0.032;
    float c = sin(q.x * 1.7 + t * 1.2 + sin(q.y * 2.3 - t * 0.8) * 1.6) * sin(q.y * 1.9 - t * 1.0 + sin(q.x * 1.4 + t * 0.6) * 1.3);
    float caustic = pow(0.5 + 0.5 * c, 3.0);
    float light = 0.10 + caustic * 0.32 + edge * (0.28 + 0.6 * facing);
    return half4(half3(light), half(light)) * half(a);
}

// A little shade on the edges that face away from the light, so the water has depth (drawn normally, under the shine).
[[ stitchable ]] half4 liquidShade(float2 position, SwiftUI::Layer layer, float t) {
    float a = layer.sample(position).a;
    if (a < 0.01) return half4(0);
    float2 g = edgeGradient(position, layer);
    float edge = clamp(length(g) * 1.3, 0.0, 1.0);
    float away = clamp(dot(normalize(g + 1e-5), normalize(float2(-0.45, -0.9))), 0.0, 1.0);
    float shade = edge * away * 0.35 + 0.04;
    return half4(0, 0, 0, half(shade)) * half(a);
}
