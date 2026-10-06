// Metal shaders, compiled from source at startup (the offline `metal` compiler ships
// only with full Xcode). Struct layouts must match Renderer.swift.
let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProj;
    float4 params;      // viewport.xy (pixels), fadeNear, fadeFar
};

// Distance dimming, the vector-display stand-in for fog.
static float depthFade(constant FrameUniforms &u, float w) {
    return mix(0.12, 1.0, 1.0 - smoothstep(u.params.z, u.params.w, w));
}

// ---------------------------------------------------------------- lines

struct LineInstance {
    float4 a;       // xyz, w = width in pixels
    float4 b;       // xyz, w = intensity at b relative to a (fades along the line)
    float4 color;   // rgb (HDR), a = intensity
};

struct LineOut {
    float4 position [[position]];
    float3 color;
    float2 local [[center_no_perspective]];   // pixels: x along segment from a, y across
    float length [[flat]];
    float halfWidth [[flat]];
};

// Each segment is a screen-aligned quad around the projected endpoints.
vertex LineOut line_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           const device LineInstance *lines [[buffer(0)]],
                           constant FrameUniforms &u [[buffer(1)]]) {
    LineInstance L = lines[iid];
    float4 ca = u.viewProj * float4(L.a.xyz, 1);
    float4 cb = u.viewProj * float4(L.b.xyz, 1);
    LineOut o;

    const float nearW = 0.05;
    if (ca.w < nearW && cb.w < nearW) {
        o.position = float4(-2, -2, -2, 1);
        return o;
    }
    if (ca.w < nearW) ca = mix(ca, cb, (nearW - ca.w) / (cb.w - ca.w));
    else if (cb.w < nearW) cb = mix(cb, ca, (nearW - cb.w) / (ca.w - cb.w));

    float2 half_vp = 0.5 * u.params.xy;
    float2 sa = ca.xy / ca.w * half_vp;
    float2 sb = cb.xy / cb.w * half_vp;
    float2 d = sb - sa;
    float len = length(d);
    float2 dir = len > 1e-4 ? d / len : float2(1, 0);
    float2 nrm = float2(-dir.y, dir.x);
    float hw = L.a.w * 0.5;
    float ext = hw + 1.5;

    const float2 corners[6] = { {0, -1}, {1, -1}, {0, 1}, {0, 1}, {1, -1}, {1, 1} };
    float2 c = corners[vid];
    bool atB = c.x > 0.5;
    float along = atB ? ext : -ext;
    float2 p = (atB ? sb : sa) + dir * along + nrm * c.y * ext;
    float4 clip = atB ? cb : ca;

    o.position = float4(p / half_vp * clip.w, clip.z, clip.w);
    o.local = float2((atB ? len : 0.0) + along, c.y * ext);
    o.length = len;
    o.halfWidth = hw;
    o.color = L.color.rgb * L.color.a * (atB ? L.b.w : 1.0) * depthFade(u, clip.w);
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    float dx = max(max(-in.local.x, in.local.x - in.length), 0.0);
    float d = length(float2(dx, in.local.y));
    float core = 1.0 - smoothstep(in.halfWidth - 0.5, in.halfWidth + 1.0, d);
    return float4(in.color * core, core);
}

// ---------------------------------------------------------------- SDF text

struct GlyphInstance {
    float4 origin;  // xyz: world position of the quad's bottom-left
    float4 right;   // xyz: full quad width vector
    float4 up;      // xyz: full quad height vector
    float4 uvRect;  // atlas x, y, w, h (y from top)
    float4 color;   // rgb, a = intensity
};

struct GlyphOut {
    float4 position [[position]];
    float2 uv;
    float3 color;
};

vertex GlyphOut glyph_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device GlyphInstance *glyphs [[buffer(0)]],
                             constant FrameUniforms &u [[buffer(1)]]) {
    const float2 corners[6] = { {0, 0}, {1, 0}, {0, 1}, {0, 1}, {1, 0}, {1, 1} };
    float2 c = corners[vid];
    GlyphInstance G = glyphs[iid];
    float3 p = G.origin.xyz + G.right.xyz * c.x + G.up.xyz * c.y;
    GlyphOut o;
    o.position = u.viewProj * float4(p, 1);
    o.uv = float2(G.uvRect.x + c.x * G.uvRect.z, G.uvRect.y + (1.0 - c.y) * G.uvRect.w);
    o.color = G.color.rgb * G.color.a * depthFade(u, o.position.w);
    return o;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]],
                               texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float sd = atlas.sample(s, in.uv).r;          // 0.5 is the edge, larger is inside
    float w = max(fwidth(sd), 1e-4) * 0.7;
    float fill = smoothstep(0.5 - w, 0.5 + w, sd);
    float halo = smoothstep(0.3, 0.5, sd) * 0.12;
    return float4(in.color * (fill + halo), 1);
}

// ---------------------------------------------------------------- post

struct FSOut {
    float4 position [[position]];
    float2 uv;
};

vertex FSOut fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    FSOut o;
    o.position = float4(p * 2.0 - 1.0, 0, 1);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// Phosphor persistence: the screen keeps the brighter of now and a decayed past.
fragment float4 persist_fragment(FSOut in [[stage_in]],
                                 texture2d<float> scene [[texture(0)]],
                                 texture2d<float> previous [[texture(1)]],
                                 constant float &decay [[buffer(0)]]) {
    constexpr sampler s(filter::nearest, address::clamp_to_edge);
    float3 now = scene.sample(s, in.uv).rgb;
    float3 old = previous.sample(s, in.uv).rgb * decay;
    return float4(max(now, old), 1);
}

// Dual-filter (Kawase) bloom. params: source texel size xy, threshold, apply threshold
fragment float4 bloom_down_fragment(FSOut in [[stage_in]],
                                    texture2d<float> src [[texture(0)]],
                                    constant float4 &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 t = params.xy;
    float3 c = src.sample(s, in.uv).rgb * 4.0;
    c += src.sample(s, in.uv + t * float2(-1, -1)).rgb;
    c += src.sample(s, in.uv + t * float2( 1, -1)).rgb;
    c += src.sample(s, in.uv + t * float2(-1,  1)).rgb;
    c += src.sample(s, in.uv + t * float2( 1,  1)).rgb;
    c /= 8.0;
    if (params.w > 0.5) {
        float brightness = max(c.r, max(c.g, c.b));
        c *= max(brightness - params.z, 0.0) / max(brightness, 1e-4);
    }
    return float4(c, 1);
}

fragment float4 bloom_up_fragment(FSOut in [[stage_in]],
                                  texture2d<float> src [[texture(0)]],
                                  constant float4 &params [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 t = params.xy;
    float3 c = 0;
    c += src.sample(s, in.uv + float2(-2 * t.x, 0)).rgb;
    c += src.sample(s, in.uv + float2( 2 * t.x, 0)).rgb;
    c += src.sample(s, in.uv + float2(0, -2 * t.y)).rgb;
    c += src.sample(s, in.uv + float2(0,  2 * t.y)).rgb;
    c += src.sample(s, in.uv + float2(-t.x, -t.y)).rgb * 2.0;
    c += src.sample(s, in.uv + float2( t.x, -t.y)).rgb * 2.0;
    c += src.sample(s, in.uv + float2(-t.x,  t.y)).rgb * 2.0;
    c += src.sample(s, in.uv + float2( t.x,  t.y)).rgb * 2.0;
    return float4(c / 12.0, 1);
}

struct PostUniforms {
    float resX, resY, time, curvature;
    float scanlines, aberration, bloom, vignette;
    float grain, exposure, pad0, pad1;
};

static float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fragment float4 composite_fragment(FSOut in [[stage_in]],
                                   texture2d<float> image [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   constant PostUniforms &p [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_zero);

    // Barrel distortion: the curved glass.
    float2 cc = in.uv * 2.0 - 1.0;
    cc *= 1.0 + p.curvature * dot(cc, cc);
    float2 uv = cc * 0.5 + 0.5;
    if (any(uv < 0.0) || any(uv > 1.0)) return float4(0, 0, 0, 1);

    // Chromatic aberration grows toward the edges.
    float2 off = cc * p.aberration / float2(p.resX, p.resY);
    float3 col;
    col.r = image.sample(s, uv + off).r + bloom.sample(s, uv + off).r * p.bloom;
    col.g = image.sample(s, uv).g       + bloom.sample(s, uv).g * p.bloom;
    col.b = image.sample(s, uv - off).b + bloom.sample(s, uv - off).b * p.bloom;

    // Scanlines, every 3 device pixels.
    float scan = 0.5 + 0.5 * sin(uv.y * p.resY * M_PI_F / 1.5);
    col *= mix(1.0, 0.72 + 0.28 * scan, p.scanlines);

    // Vignette plus a soft rounded edge to the tube.
    col *= 1.0 - p.vignette * dot(cc, cc) * 0.35;
    float2 edge = smoothstep(0.0, 0.012, uv) * smoothstep(0.0, 0.012, 1.0 - uv);
    col *= edge.x * edge.y;

    col = 1.0 - exp(-col * p.exposure);
    col += (hash12(in.position.xy + fract(p.time) * 917.0) - 0.5) * p.grain;
    return float4(max(col, 0.0), 1);
}
"""
