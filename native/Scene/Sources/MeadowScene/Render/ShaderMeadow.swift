extension ShaderSource {
    // The land, the grass, the sky and the water.
    static let meadow = #"""
// ---------- sky (Meadow.ts buildSky): drawn last, only where nothing else was ----------
struct SkyOut { float4 position [[position]]; float2 ndc; };
vertex SkyOut skyVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2) * 2.0 - 1.0;
    SkyOut o; o.position = float4(p, 1.0, 1.0); o.ndc = p; return o;
}
fragment float4 skyFragment(SkyOut in [[stage_in]], constant Frame& F [[buffer(0)]]) {
    float4 far = F.invViewProj * float4(in.ndc, 1.0, 1.0);
    float3 dir = normalize(far.xyz / far.w - F.eye.xyz);
    // Tests (`Renderer.marksVoid`): where the sky shows below the horizon with ground expected there, short
    // of the fog's middle, the picture would show a hole in the world: drawn in pure magenta to be counted.
    if (F.viewport.w > 0.5 && dir.y < 0.0) {
        float along = -F.eye.y / dir.y;
        float depth = -(F.view * float4(F.eye.xyz + dir * along, 1.0)).z;
        if (depth < (F.fog.x + F.fog.y) * 0.5) return float4(1, 0, 1, 1);
    }
    float h = max(dir.y, 0.0);
    float3 c = mix(mix(F.horizon.rgb, F.skyMid.rgb, smoothstep(0.0, 0.2, h)), F.skyTop.rgb, smoothstep(0.15, 0.85, h));
    // Sheet lightning: the whole sky brightens softly toward a pale lilac, more overhead.
    c = mix(c, float3(0.62, 0.64, 0.82), F.weather.y * (0.3 + 0.2 * h));
    // A whisper of noise, one step of the screen's colour either way, so a dark gradient never breaks
    // into bands. The drawable is sRGB, so the step is taken in sRGB and brought back to linear.
    float n = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453) - 0.5;
    float3 s = select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c < 0.0031308) + n / 255.0;
    c = select(pow((s + 0.055) / 1.055, 2.4), s / 12.92, s < 0.04045);
    return float4(max(c, 0.0), 1);
}

// ---------- ground (kit.ts turf) ----------
struct GroundIn { packed_float3 p; packed_float3 n; };
struct GroundOut { float4 position [[position]]; float3 world; float3 irr; float fog; };
vertex GroundOut groundVertex(uint vid [[vertex_id]], device const GroundIn* v [[buffer(1)]], constant Frame& F [[buffer(0)]],
                              constant World& W [[buffer(2)]]) {
    GroundOut o;
    float3 w = float3(v[vid].p);
    // Level wherever blankets are laid.
    float level = levelAt(w.xz, F, W);
    w.y = mix(w.y, LAND_GROUND, level);
    o.world = w;
    o.position = F.viewProj * float4(w, 1);
    o.irr = lambertIrradiance(normalize(mix(normalize(float3(v[vid].n)), float3(0, 1, 0), level)), F);
    o.fog = fogFactor(w, F);
    return o;
}
fragment float4 groundFragment(GroundOut in [[stage_in]], constant Frame& F [[buffer(0)]], constant World& W [[buffer(2)]],
                               texture2d<float> groundMap [[texture(0)]]) {
    float2 g = in.world.xz;
    float3 land = meadowColor(g, F);
    // The land: paler where it has been trodden round a blanket, deeper under standing grass.
    float3 c = mix(land * float3(1.06, 1.04, 0.86), land * 0.8, smoothstep(0.16, 1.0, openGround(g, F, W)));
    // A space's mown patch: lighter, cut short, with the mower's stripes.
    float stripe;
    float mown = mownAt(g, F, W, stripe);
    c = mix(c, land * (1.04 + 0.05 * stripe) * float3(1.04, 1.04, 0.92), mown * 0.85);
    // A path's worn earth: warm and bare in the middle, the grass closing in over its edges.
    if (F.counts.w > 0.0) {
        float worn = 1.0 - smoothstep(0.3, 1.0, pathDistance(g, F, W) + (mNoise(g * 2.3) - 0.5) * 0.35);
        c = mix(c, float3(0.52, 0.41, 0.27) * 0.62, worn * 0.7);
    }
    // The stream's banks: damp, darker earth by the water.
    if (F.counts.z > 0.0) {
        float s = streamDistance(g, F, W);
        c = mix(c, float3(0.16, 0.14, 0.09), (1.0 - smoothstep(0.0, 0.9, s)) * 0.6);
    }
    c *= shadeAt(g, F, groundMap);
    float3 lit = c * in.irr + c * WARM * picnicLight2(g, F, W) * 0.8;
    return float4(mix(lit, F.horizon.rgb, in.fog), 1);
}

// ---------- grass: kit.ts blades() ----------
struct Blade { packed_float3 p; packed_float3 n; };
struct Tuft { float4 rootYaw; float4 scale; };
struct GrassOut { float4 position [[position]]; float3 land; float3 lit; float3 glow; float blade; float fog; };
vertex GrassOut grassVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            device const Blade* shape [[buffer(1)]], device const Tuft* tufts [[buffer(3)]],
                            constant Frame& F [[buffer(0)]], constant World& W [[buffer(2)]], texture2d<float> groundMap [[texture(0)]]) {
    Tuft t = tufts[iid];
    float3 root = t.rootYaw.xyz;
    root.y = mix(root.y, LAND_GROUND, levelAt(root.xz, F, W));
    float open = openGround(root.xz, F, W);
    // Mown grass is cut to a short even sward.
    float stripe;
    float mown = mownAt(root.xz, F, W, stripe);
    float3 position = float3(shape[vid].p);
    float cut = mix(1.0, 0.42, mown);
    float3 transformed = position * float3(mix(0.55, 1.0, open), open * cut, mix(0.55, 1.0, open));
    float cy = cos(t.rootYaw.w), sy = sin(t.rootYaw.w);
    float3 s = float3(t.scale.x, t.scale.y, t.scale.x);
    float3 q = transformed * s;
    float3 w = root + float3(q.x * cy + q.z * sy, q.y, -q.x * sy + q.z * cy);
    float lift = w.y - root.y;
    w.xz += windAt(root.xz, F) * lift * lift * 0.3;
    // Its normal leans toward straight up, so the field catches the light as one rounded surface.
    float3 n0 = float3(shape[vid].n);
    float3 on = normalize(float3(n0.x * 0.45, 1.6, n0.z * 0.45)) / s;
    float3 n = normalize(float3(on.x * cy + on.z * sy, on.y, -on.x * sy + on.z * cy));
    GrassOut o;
    o.position = F.viewProj * float4(w, 1);
    float3 land = meadowColor(root.xz, F);
    o.land = mix(land, land * (1.06 + 0.05 * stripe), mown * 0.8);
    o.lit = shadeAt(root.xz, F, groundMap) * (0.93 + 0.14 * mHash(floor(root.xz * 2.0))) * lambertIrradiance(n, F);
    o.glow = WARM * picnicLight2(root.xz, F, W);
    o.blade = position.y;
    o.fog = fogFactor(w, F);
    return o;
}
fragment float4 grassFragment(GrassOut in [[stage_in]], constant Frame& F [[buffer(0)]]) {
    float3 sunlit = in.land * float3(1.2, 1.18, 0.9) + float3(0.03, 0.04, 0.0);
    float3 diffuse = mix(in.land * 0.8, sunlit, smoothstep(0.0, 0.9, in.blade));
    // Lamplight catches the tips more than the shaded roots.
    float3 c = diffuse * in.lit + diffuse * in.glow * (0.3 + 0.55 * in.blade);
    return float4(mix(c, F.horizon.rgb, in.fog), 1);
}

// ---------- water: a stream between machines ----------
struct WaterIn { packed_float3 p; float across; float along; };
struct WaterOut { float4 position [[position]]; float3 world; float across; float along; float fog; };
vertex WaterOut waterVertex(uint vid [[vertex_id]], device const WaterIn* v [[buffer(1)]], constant Frame& F [[buffer(0)]]) {
    WaterOut o;
    float3 w = float3(v[vid].p);
    o.world = w;
    o.position = F.viewProj * float4(w, 1);
    o.across = v[vid].across;
    o.along = v[vid].along;
    o.fog = fogFactor(w, F);
    return o;
}
fragment float4 waterFragment(WaterOut in [[stage_in]], constant Frame& F [[buffer(0)]], constant World& W [[buffer(2)]],
                               texture2d<float> groundMap [[texture(0)]]) {
    float t = F.eye.w;
    float edge = abs(in.across);
    // Clear shallow water over a sandy bed at the edges, deeper blue in the middle.
    float3 shallow = float3(0.62, 0.78, 0.82), deep = float3(0.22, 0.47, 0.62);
    float3 c = mix(deep, shallow, smoothstep(0.35, 1.0, edge));
    // Ripples drifting downstream, and glints where they catch the sky.
    float r = mNoise(float2(in.along * 0.7 - t * 1.1, in.across * 2.0)) * 0.6 + mNoise(float2(in.along * 1.9 - t * 1.7, in.across * 4.0 + 3.0)) * 0.4;
    float glint = smoothstep(0.72, 0.9, r);
    c *= shadeAt(in.world.xz, F, groundMap);
    float3 sky = mix(F.skyMid.rgb, F.hemiSky.rgb * 0.5, 0.3);
    float3 lit = c * lambertIrradiance(float3(0, 1, 0), F) + sky * glint * 0.35 * (1.0 - F.fog.w * 0.7);
    // A pale lip where the water meets the bank, as in the design's drawing.
    lit = mix(lit, float3(0.86, 0.92, 0.94) * lambertIrradiance(float3(0, 1, 0), F) * 1.4, smoothstep(0.86, 0.98, edge) * 0.7);
    // After dark water holds little colour: it goes as deep and grey as the meadow round it.
    float night = F.fog.w;
    lit = mix(lit, float3(dot(lit, float3(0.3, 0.55, 0.15))), night * 0.55) * mix(1.0, 0.55, night);
    lit += WARM * picnicLight2(in.world.xz, F, W) * c * 0.6;
    return float4(mix(lit, F.horizon.rgb, in.fog), 1);
}

// ---------- stars and the moon ----------
struct StarOut { float4 position [[position]]; float size [[point_size]]; float alpha; };
vertex StarOut starVertex(uint vid [[vertex_id]], device const packed_float3* stars [[buffer(1)]], constant Frame& F [[buffer(0)]]) {
    StarOut o;
    float3 w = F.eye.xyz + float3(stars[vid]);
    o.position = F.viewProj * float4(w, 1);
    o.position.z = o.position.w * 0.99999;
    o.size = 2.2 * F.viewport.z;
    o.alpha = F.sky2.x;
    return o;
}
fragment float4 starFragment(StarOut in [[stage_in]], float2 pc [[point_coord]]) {
    float d = length(pc - 0.5) * 2.0;
    float a = 1.0 - smoothstep(0.6, 1.0, d);
    return float4(1, 1, 1, a * in.alpha);
}
"""#
}
