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

// MARK: - The player card's Liquid Glass (our own)
// Following Apple's description of the material: it blurs what is behind it (done in SwiftUI before this runs), bends
// that picture like the thick rim of a glass slab, picks up the light around it, and answers the pointer: the light
// sits where the mouse is, so the highlight and the bright edge move as you move over the card.

// Distance from a point to the edge of a rounded box centred at the origin: negative inside.
static float roundedBox(float2 p, float2 halfSize, float r) {
    float2 q = abs(p) - halfSize + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

[[ stitchable ]] half4 glassLens(float2 position, SwiftUI::Layer layer, float2 size, float radius, float2 light, float t) {
    float2 half_ = size * 0.5;
    float2 p = position - half_;
    float d = roundedBox(p, half_, radius);
    if (d > 0.75) return half4(0);
    float inside = -d;

    // which way the edge faces (outward), from the distance field
    float e = 1.0;
    float2 n = float2(roundedBox(p + float2(e, 0), half_, radius) - roundedBox(p - float2(e, 0), half_, radius),
                      roundedBox(p + float2(0, e), half_, radius) - roundedBox(p - float2(0, e), half_, radius));
    n = n / max(length(n), 1e-4);

    // the rim: the picture is drawn in from further inside, more strongly toward the edge, so it magnifies and bends
    float band = 34.0;
    float k = clamp(1.0 - inside / band, 0.0, 1.0);
    float bend = k * k * k * 34.0;
    float2 source = position - n * bend;
    float split = k * k * 1.8;  // colours part slightly where it bends most
    half3 col = half3(layer.sample(source - n * split).r, layer.sample(source).g, layer.sample(source + n * split).b);
    col *= 0.80;  // a little darker than what's behind, so white text reads

    // light from the pointer (or the upper left until the pointer comes by)
    float2 lightAt = light * size;
    float2 toLight = lightAt - position;
    float near = exp(-dot(toLight, toLight) / (size.x * size.x * 0.10));
    float facing = dot(n, normalize(toLight + 1e-4));  // edges turned toward the light catch it
    float rim = smoothstep(2.4, 0.0, inside) * (0.30 + 0.70 * max(facing, 0.0));
    float glow = smoothstep(12.0, 0.0, inside) * 0.07;
    // a faint sheen that drifts across now and then, as light moves over real glass
    float sweep = pow(max(0.0, 1.0 - abs(fract((p.x + p.y * 0.5) / size.x * 0.7 - t * 0.04) * 2.0 - 1.0) * 6.0), 2.0) * 0.05;
    col += half3(rim * 0.85 + glow + near * 0.12 + sweep);

    float alpha = smoothstep(0.75, -0.75, d);
    return half4(col * alpha, alpha);
}
