extension ShaderSource {
    // Things that face the camera: bubbles and flags (textures drawn with Core Text), glows, fireflies.
    static let overlay = #"""
// three.js Sprite: a quad in view space round a point, `center` saying which point of it sits there.
struct Sprite {
    float4 at;        // xyz world position, w opacity
    float4 size;      // width, height (world units), center x, center y (0…1)
    float4 tint;      // rgb multiplier (or glow colour), a: 1 to fog it
    float4 uv;        // texture rectangle u0, v0, u1, v1; for glows x is the kind
};
struct SpriteOut { float4 position [[position]]; float2 uv; float2 at; float opacity; float3 tint; float fog; float kind; };
SpriteOut spriteCommon(uint vid, Sprite s, constant Frame& F) {
    float2 corner = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
    float4 mv = F.view * float4(s.at.xyz, 1);
    mv.xy += (corner - s.size.zw) * s.size.xy;
    SpriteOut o;
    o.position = F.proj * mv;
    o.uv = mix(s.uv.xy, s.uv.zw, float2(corner.x, 1.0 - corner.y));
    o.at = corner * 2.0 - 1.0;
    o.opacity = s.at.w;
    o.tint = s.tint.rgb;
    o.fog = s.tint.a > 0.5 ? smoothstep(F.fog.x, F.fog.y, -mv.z) : 0.0;
    o.kind = s.uv.x;
    return o;
}
vertex SpriteOut spriteVertex(uint vid [[vertex_id]], uint iid [[instance_id]], device const Sprite* sprites [[buffer(1)]], constant Frame& F [[buffer(0)]]) {
    return spriteCommon(vid, sprites[iid], F);
}
// Textures hold premultiplied colour; blending is (one, one − source alpha).
fragment float4 spriteFragment(SpriteOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant Frame& F [[buffer(0)]]) {
    constexpr sampler linearSampler(filter::linear, mip_filter::linear, address::clamp_to_edge, max_anisotropy(4));
    float4 c = tex.sample(linearSampler, in.uv);
    float3 rgb = mix(c.rgb * in.tint, F.horizon.rgb * c.a, in.fog);
    return float4(rgb, c.a) * in.opacity;
}

// Glows, added onto whatever is behind: kind 0 is the hamper lantern's (Village.ts lampGlow gradient),
// kind 1 a soft halo in the sprite's own colour.
fragment float4 glowFragment(SpriteOut in [[stage_in]]) {
    float d = length(in.at);
    if (d >= 1.0) discard_fragment();
    float4 c;
    if (in.kind < 0.5) {
        // Canvas stops (sRGB, straight alpha): 0 → (255,244,214,1), 0.1 → (255,214,130,.9), 0.35 → (255,166,70,.32), 1 → (255,140,50,0)
        float4 s0 = float4(255, 244, 214, 255) / 255.0, s1 = float4(255, 214, 130, 0.9 * 255) / 255.0;
        float4 s2 = float4(255, 166, 70, 0.32 * 255) / 255.0, s3 = float4(255, 140, 50, 0) / 255.0;
        c = d < 0.1 ? mix(s0, s1, d / 0.1) : d < 0.35 ? mix(s1, s2, (d - 0.1) / 0.25) : mix(s2, s3, (d - 0.35) / 0.65);
        c.rgb = srgbDecode(c.rgb);
    } else {
        c = float4(in.tint, pow(1.0 - d, 2.0));
    }
    return float4(c.rgb * c.a * in.opacity, 0.0);
}

// Fireflies (Meadow.ts fireflyClay): a bright yellow core in a warm halo. Never smaller on screen than a
// few pixels, so they still twinkle in the overview.
struct Firefly { float4 at; };   // xyz, w glow
struct FireflyOut { float4 position [[position]]; float2 at; float glow; };
vertex FireflyOut fireflyVertex(uint vid [[vertex_id]], uint iid [[instance_id]], device const Firefly* flies [[buffer(1)]], constant Frame& F [[buffer(0)]]) {
    Firefly f = flies[iid];
    float2 corner = float2((vid & 1) ? 0.5 : -0.5, (vid & 2) ? 0.5 : -0.5);
    float4 middle = F.view * float4(f.at.xyz, 1);
    middle.xy += corner * 0.75 * max(1.0, -middle.z / 22.0);
    FireflyOut o;
    o.position = f.at.w > 0.0 ? F.proj * middle : float4(0);
    o.at = corner * 2.0;
    o.glow = f.at.w;
    return o;
}
fragment float4 fireflyFragment(FireflyOut in [[stage_in]]) {
    float d = length(in.at);
    float core = smoothstep(0.22, 0.06, d);
    float halo = pow(max(1.0 - d, 0.0), 2.2) * 0.5;
    float3 color = mix(float3(1.0, 0.7, 0.18), float3(1.0, 0.97, 0.7), core);
    // The web shader writes these values straight to the screen, so they are sRGB.
    return float4(srgbDecode(min(color * (core + halo) * in.glow, 1.0)), 0.0);
}
"""#
}
