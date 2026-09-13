extension ShaderSource {
    // Everything modelled in clay: the cats and what they hold, the picnic, flowers, trees, stones, the log.
    // One family of shaders; each instance says how it is lit (kit.ts `warmed`, `shaded`, `rooted`).
    static let clay = #"""
// Static meshes: position, normal, colour (linear) and roughness, 40 bytes.
struct ClayVertex { packed_float3 p; packed_float3 n; packed_float4 c; };
// The posed cat skin and tail: position and normal, 24 bytes.
struct SkinVertex { packed_float3 p; packed_float3 n; };

// How an instance is lit, as bits of `info.x`.
#define LIT_UNLIT     1u   // MeshBasicMaterial: its colour as it is
#define LIT_SHADED    2u   // takes the passing cloud and tree shade where it stands (kit.ts `shaded`)
#define LIT_WARMED    4u   // a cat or what it holds: lamplight fills the side facing the picnic (kit.ts `warmed`)
#define LIT_ROOTED    8u   // rooted plant: shrinks where a blanket is laid, bows in the wind (kit.ts `rooted`)
#define LIT_TWOSIDED 16u   // seen from both sides, normal flipped for the back
#define LIT_LAMBERT  32u   // MeshLambertMaterial instead of Standard
#define LIT_NOFOG    64u
#define LIT_GLOW    128u   // lamplight on a surface standing in the meadow (`shaded` glow)
#define LIT_GINGHAM 256u   // a blanket: gingham in the tint colour (sRGB); extra.z checks per unit, extra.w faded

struct Instance {
    float4x4 model;
    float4 tint;       // multiplies the colour; a = opacity
    float4 emissive;   // added after lighting
    float4 extra;      // x sway (rooted), y roughness override (< 0: per vertex), z, w unused
    uint4 info;        // x lighting bits
};

struct ClayOut {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 color;
    float rough;
    float opacity;
    float3 emissive;
    float3 light;      // per-vertex ground shade for rooted plants
    float glow;        // per-vertex lamplight for rooted plants
    float2 local;      // object-space x, z (the blanket's gingham)
    float2 pattern;    // gingham: repeat, faded
    float fog;
    uint flags [[flat]];
};

// The normal matrix (inverse transpose of the upper 3×3), up to scale: its cofactor matrix.
float3 normalTransform(float4x4 m, float3 n) {
    float3 a = m[0].xyz, b = m[1].xyz, c = m[2].xyz;
    float3x3 cof = float3x3(cross(b, c), cross(c, a), cross(a, b));
    // A mirrored transform turns the cofactors inside out; the determinant's sign turns them back.
    return normalize(cof * n) * sign(dot(a, cross(b, c)));
}

// What a rooted plant needs to know about where it stands, worked out once per plant per frame by
// `rootKernel` rather than for each of its thousands of vertices: the wind at its root (already scaled by
// its sway), how far it shrinks where a blanket is laid and sinks where the land is levelled, the light
// reaching it and the lamplight on it.
struct RootInfo { float4 wind; float4 light; };   // wind.xy, wind.z shrink, wind.w sink; light.rgb, light.w glow

kernel void rootKernel(uint i [[thread_position_in_grid]], constant uint& count [[buffer(5)]], device const Instance* inst [[buffer(3)]],
                       device RootInfo* out [[buffer(4)]], constant Frame& F [[buffer(0)]], constant World& W [[buffer(2)]]) {
    if (i >= count) return;
    float3 base = (inst[i].model * float4(0, 0, 0, 1)).xyz;
    float2 root = base.xz;
    float open = openGround(root, F, W);
    // w: how far it goes down with the land where that is levelled for blankets.
    out[i].wind = float4(windAt(root, F) * inst[i].extra.x, smoothstep(0.25, 0.95, open), (base.y - LAND_GROUND) * levelAt(root, F, W));
    out[i].light = float4(shadeAt(root, F, W), picnicLight2(root, F, W) * 0.8);
}

ClayOut clayCommon(float3 p, float3 n, float4 c, Instance I, RootInfo R, constant Frame& F) {
    uint flags = I.info.x;
    ClayOut o;
    o.light = float3(1.0);
    o.glow = 0.0;
    float4 w;
    if ((flags & LIT_ROOTED) != 0u) {
        float4 root = I.model * float4(0, 0, 0, 1);
        p *= R.wind.z;
        w = I.model * float4(p, 1);
        float lift = w.y - root.y;
        w.xz += R.wind.xy * lift * lift;
        w.y -= R.wind.w;
        o.light = R.light.rgb;
        o.glow = R.light.w;
    } else {
        w = I.model * float4(p, 1);
    }
    o.position = F.viewProj * w;
    o.world = w.xyz;
    o.normal = normalTransform(I.model, n);
    o.color = c.rgb * I.tint.rgb;
    o.local = p.xz;
    o.pattern = I.extra.zw;
    o.rough = I.extra.y >= 0.0 ? I.extra.y : c.a;
    o.opacity = I.tint.a;
    o.emissive = I.emissive.rgb;
    o.fog = (flags & LIT_NOFOG) != 0u ? 0.0 : fogFactor(w.xyz, F);
    o.flags = flags;
    return o;
}

vertex ClayOut clayVertex(uint vid [[vertex_id]], uint iid [[instance_id]], device const ClayVertex* v [[buffer(1)]],
                          device const Instance* inst [[buffer(3)]], device const RootInfo* roots [[buffer(4)]], constant Frame& F [[buffer(0)]]) {
    Instance I = inst[iid];
    RootInfo R = (I.info.x & LIT_ROOTED) != 0u ? roots[iid] : RootInfo{ float4(0, 0, 1, 0), float4(1, 1, 1, 0) };
    return clayCommon(float3(v[vid].p), float3(v[vid].n), float4(v[vid].c), I, R, F);
}
vertex ClayOut skinVertex(uint vid [[vertex_id]], uint iid [[instance_id]], device const SkinVertex* v [[buffer(1)]],
                          device const Instance* inst [[buffer(3)]], constant Frame& F [[buffer(0)]]) {
    return clayCommon(float3(v[vid].p), float3(v[vid].n), float4(1, 1, 1, 0.6), inst[iid], RootInfo{ float4(0, 0, 1, 0), float4(1, 1, 1, 0) }, F);
}

float4 shadeClay(ClayOut in, bool front, constant Frame& F, constant World& W) {
    uint flags = in.flags;
    float3 diffuse = in.color;
    if ((flags & LIT_GINGHAM) != 0u) {
        // blanket.ts gingham: cream cloth, and two half-strength bands of the colour crossing, so where
        // they overlap it is stronger, as in woven gingham. Composited in sRGB, as on the web's canvas.
        float2 uv = float2(in.local.x, -in.local.y) * in.pattern.x;
        float2 w = fwidth(uv) * 0.75 + 1e-4;
        float cu = 1.0 - smoothstep(0.25 - w.x, 0.25 + w.x, abs(fract(uv.x + 0.25) - 0.5));
        float cv = 1.0 - smoothstep(0.25 - w.y, 0.25 + w.y, abs(fract(uv.y + 0.75) - 0.5));
        float k = cu * 0.5 + cv * 0.5 - cu * cv * 0.25;
        float3 cream = float3(1.0, 247.0 / 255.0, 238.0 / 255.0);
        float3 tint = mix(in.color, cream, in.pattern.y);
        diffuse = srgbDecode(mix(cream, tint, k));
    }
    if ((flags & LIT_UNLIT) != 0u) return float4(mix(diffuse, F.horizon.rgb, in.fog), in.opacity);
    float3 N = normalize(in.normal);
    if ((flags & LIT_TWOSIDED) != 0u && !front) N = -N;
    float3 V = normalize(F.eye.xyz - in.world);
    if ((flags & LIT_SHADED) != 0u) diffuse *= shadeAt(in.world.xz, F, W);
    diffuse *= in.light;
    float3 c = (flags & LIT_LAMBERT) != 0u ? diffuse * lambertIrradiance(N, F) : standardLight(N, V, diffuse, in.rough, F);
    c += in.emissive;
    // Lamplight after dark.
    if ((flags & LIT_WARMED) != 0u) {
        float3 from;
        float glow = picnicLight(in.world, F, W, from);
        if (glow > 0.0) {
            float3 toLight = normalize(from + float3(0.0, 1e-3, 0.0));
            float facing = dot(N, toLight);
            float edge = pow(1.0 - clamp(dot(N, V), 0.0, 1.0), 2.0);
            c += WARM * glow * (diffuse * (0.3 + 0.7 * max(facing, 0.0)) * 0.7 + edge * smoothstep(-0.5, 0.6, facing) * 0.7);
        }
    } else if ((flags & LIT_GLOW) != 0u) {
        c += diffuse * WARM * picnicLight2(in.world.xz, F, W) * 0.85;
    }
    if ((flags & LIT_ROOTED) != 0u) c += diffuse * WARM * in.glow;
    return float4(mix(c, F.horizon.rgb, in.fog), in.opacity);
}

fragment float4 clayFragment(ClayOut in [[stage_in]], bool front [[front_facing]], constant Frame& F [[buffer(0)]], constant World& W [[buffer(2)]]) {
    return shadeClay(in, front, F, W);
}

// ---------- blob shadow (props.ts shadowTexture: a canvas gradient read as linear) ----------
struct ShadowOut { float4 position [[position]]; float2 uv; float opacity; };
struct ShadowInstance { float4x4 model; float4 extra; };   // extra.x opacity
vertex ShadowOut shadowVertex(uint vid [[vertex_id]], uint iid [[instance_id]], device const ShadowInstance* inst [[buffer(3)]], constant Frame& F [[buffer(0)]]) {
    float2 c = float2((vid & 1) ? 0.5 : -0.5, (vid & 2) ? 0.5 : -0.5);
    ShadowOut o;
    o.position = F.viewProj * (inst[iid].model * float4(c.x, 0, c.y, 1));
    o.uv = c * 2.0;
    o.opacity = inst[iid].extra.x;
    return o;
}
fragment float4 shadowFragment(ShadowOut in [[stage_in]]) {
    float d = length(in.uv);
    float a = d < 0.55 ? mix(0.32, 0.14, d / 0.55) : mix(0.14, 0.0, saturate((d - 0.55) / 0.45));
    return float4(float3(40, 38, 34) / 255.0, a * in.opacity);
}
"""#
}
