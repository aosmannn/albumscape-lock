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

    float e = 1.0;
    float2 n = float2(roundedBox(p + float2(e, 0), half_, radius) - roundedBox(p - float2(e, 0), half_, radius),
                      roundedBox(p + float2(0, e), half_, radius) - roundedBox(p - float2(0, e), half_, radius));
    n = n / max(length(n), 1e-4);  // the edge's outward direction

    // A thick slab: the whole picture is magnified a little toward the middle, and much more at the rim, where it
    // bends like the curved edge of a lens.
    float band = 40.0;
    float k = clamp(1.0 - inside / band, 0.0, 1.0);
    float bend = pow(k, 2.4) * 46.0;
    float2 source = half_ + p * 0.96 - n * bend;
    float split = k * k * 2.2;
    half3 col = half3(layer.sample(source - n * split).r, layer.sample(source).g, layer.sample(source + n * split).b);
    col = col * 0.9 + 0.04;

    // light: a thin bright edge on the upper left and a fainter one on the lower right (light passing through the
    // glass and leaving by the far side), a narrow shade just inside the rim for thickness, and a soft lift at the top.
    float2 lightDir = normalize(float2(-0.55, -0.85));
    float facing = dot(n, lightDir);
    float edgeLine = smoothstep(1.8, 0.0, inside);
    float rim = edgeLine * (max(facing, 0.0) * 0.95 + max(-facing, 0.0) * 0.45 + 0.12);
    float shade = smoothstep(14.0, 3.0, inside) * smoothstep(1.0, 3.0, inside) * 0.16;
    float top = smoothstep(size.y * 0.55, 0.0, position.y) * 0.06;
    col = col * half(1.0 - shade) + half3(rim + top);

    float alpha = smoothstep(0.75, -0.75, d);
    return half4(col * alpha, alpha);
}

// MARK: - The clock's glass (still)
// The layer is the album art behind the clock, cut to the shape of the digits. Each digit is drawn as a piece of the
// same glass as the player card: the art bent inward at the edges, lifted a little, with a bright edge where it faces
// the light (upper left) and a soft shade where it faces away. Nothing moves.
[[ stitchable ]] half4 textGlass(float2 position, SwiftUI::Layer layer) {
    float a = layer.sample(position).a;
    if (a < 0.01) return half4(0);
    float e = 2.5;
    float2 g = float2(layer.sample(position + float2(e, 0)).a - layer.sample(position - float2(e, 0)).a,
                      layer.sample(position + float2(0, e)).a - layer.sample(position - float2(0, e)).a);
    float edge = clamp(length(g) * 1.2, 0.0, 1.0);
    float2 outward = -g / max(length(g), 1e-4);  // alpha grows inward, so the edge faces the other way

    float2 source = position - outward * edge * 7.0;  // bend: the art is drawn in from further inside the stroke
    float split = edge * 1.4;
    half4 c = half4(layer.sample(source - outward * split).r, layer.sample(source).g, layer.sample(source + outward * split).b, 1);
    half3 col = c.rgb / max(layer.sample(source).a, half(0.001));  // the art's own colour (the layer is premultiplied)
    col = col * 0.82 + 0.16;  // glass lifts what's behind it

    float2 light = normalize(float2(-0.45, -0.9));  // upper left (y grows downward)
    float facing = dot(outward, light);
    col += half3(edge * max(facing, 0.0) * 0.75);
    col *= half(1.0 - edge * max(-facing, 0.0) * 0.35);
    return half4(col * a, a);
}
