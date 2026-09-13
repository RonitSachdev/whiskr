// MSL compiled at launch with MTLDevice.makeLibrary(source:). The Metal Toolchain component that
// compiles `.metal` files at build time was not installed on the development machine
// (`xcodebuild -showComponent MetalToolchain` → uninstalled), so, as in the spike, the source lives in
// Swift strings. Moving it into `.metal` files later changes nothing else.
//
// The meadow functions are line-for-line ports of the GLSL in src/meadow/kit.ts (MEADOW).

enum ShaderSource {
    static var all: String { common + clay + meadow + overlay }

    static let common = #"""
#include <metal_stdlib>
using namespace metal;

#define MAX_CLEARINGS 48
#define MAX_TREES 8
#define MAX_STREAMS 4
#define MAX_PATHS 32

struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4x4 proj;
    float4x4 invViewProj;
    float4 eye;          // xyz camera position, w meadow time (kit.ts uTime)
    float4 fog;          // near, far, wind (uWind), night (uNight)
    float4 counts;       // clearings, trees, streams, trodden path strips
    float4 hemiSky;      // hemisphere light, colour × intensity
    float4 hemiGround;
    float4 keyColor;     // key light, colour × intensity
    float4 keyDir;       // toward the light
    float4 rimColor;
    float4 rimDir;
    float4 turfLow;      // kit.ts uTurfLow / uTurfHigh
    float4 turfHigh;
    float4 horizon;      // fog colour, the sky at the horizon
    float4 skyTop;
    float4 skyMid;
    float4 viewport;     // drawable width, height (px), pixels per point, unused
    float4 sky2;         // stars and moon opacity, cloud glow, moonlit (0 day … 1 night), unused
    float4 camRight;     // camera right and up in the world, for sprites and particles
    float4 camUp;
};

// Each blanket: x, z, radius (eased, as kit.ts uClearings) and the radius of the mown patch round it.
// Each patch: stripe angle, space index, and in a sidebar's column its flag's half width (0 for none)
// and how far behind the blanket's middle it stands. Each tree: x, z, reach of its crown.
// Each stream: x at z = 0, how far it wanders, its phase, its half width. Each strip of path trodden
// between a worktree's blanket and its repository's: where it starts and ends (x, z each).
struct World {
    float4 clearings[MAX_CLEARINGS];
    float4 patches[MAX_CLEARINGS];
    float4 trees[MAX_TREES];
    float4 streams[MAX_STREAMS];
    float4 paths[MAX_PATHS];
};

// ---------- kit.ts MEADOW ----------
// The web hashes lattice points with fract(sin(x) · 43758), which costs a precise sine each time and was
// most of the ground's cost here. Every caller passes a whole-number lattice point, so an integer hash
// gives the same even noise for a fraction of the work (`Noise.latticeHash` is the same on the CPU).
float mHash(float2 p) {
    int2 i = int2(floor(p));
    uint x = (uint(i.x) * 0x8da6b343u) ^ (uint(i.y) * 0xd8163841u);
    x = (x ^ (x >> 16)) * 0x7feb352du;
    x = (x ^ (x >> 15)) * 0x846ca68bu;
    x ^= x >> 16;
    return float(x) * (1.0 / 4294967296.0);
}
float mNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mHash(i), mHash(i + float2(1, 0)), f.x), mix(mHash(i + float2(0, 1)), mHash(i + float2(1, 1)), f.x), f.y);
}

// The colour of the land itself: broad patches of deeper and sunnier green.
float3 meadowColor(float2 g, constant Frame& F) {
    float broad = mNoise(g * 0.028) * 0.7 + mNoise(g * 0.09 + 11.0) * 0.3;
    return mix(F.turfLow.rgb, F.turfHigh.rgb, smoothstep(0.3, 0.72, broad));
}

// Where a stream runs: its middle at a given z.
float streamX(float4 s, float z) { return s.x + s.y * sin(z * 0.045 + s.z) + s.y * 0.4 * sin(z * 0.11 + s.z * 1.7); }
// Distance across from the middle of the nearest stream, less its half width: negative in the water.
float streamDistance(float2 g, constant Frame& F, constant World& W) {
    float d = 1e5;
    int n = int(F.counts.z);
    for (int i = 0; i < n; i++) {
        float4 s = W.streams[i];
        float dx = g.x - streamX(s, g.y);
        // Its slope there, so the distance is measured square to the banks.
        float slope = s.y * (0.045 * cos(g.y * 0.045 + s.z) + 0.044 * cos(g.y * 0.11 + s.z * 1.7));
        d = min(d, abs(dx) / sqrt(1.0 + slope * slope) - s.w);
    }
    return d;
}

// How far a spot is from the middle of the nearest path between a worktree and its repository.
float pathDistance(float2 g, constant Frame& F, constant World& W) {
    float d = 1e5;
    int n = int(F.counts.w);
    for (int i = 0; i < n; i++) {
        float4 p = W.paths[i];
        float2 along = p.zw - p.xy;
        float t = clamp(dot(g - p.xy, along) / max(dot(along, along), 1e-4), 0.0, 1.0);
        d = min(d, distance(g, p.xy + along * t));
    }
    return d;
}

// 0 on a blanket, low on the trodden ring just around it, 1 in open meadow. Streams clear their own bed.
// A sidebar's flags stand low, and the grass is trodden down along each one so no blade crosses its name.
float openGround(float2 g, constant Frame& F, constant World& W) {
    float open = 1.0;
    int n = int(F.counts.x);
    for (int i = 0; i < n; i++) {
        float4 c = W.clearings[i];
        float d = distance(g, c.xy) - c.z;
        open = min(open, d < 0.0 ? 0.0 : mix(0.14, 1.0, smoothstep(1.0, 4.6, d)));
        float4 p = W.patches[i];
        if (p.z > 0.0) {
            float f = length(max(abs(g - float2(c.x, c.y + p.w)) - float2(p.z, 0.0), 0.0));
            open = min(open, mix(0.14, 1.0, smoothstep(0.5, 2.0, f)));
        }
    }
    if (F.counts.z > 0.0) {
        float s = streamDistance(g, F, W);
        open = min(open, s < 0.3 ? 0.0 : mix(0.35, 1.0, smoothstep(0.3, 2.2, s)));
    }
    // A path's stepping stones lie in bare trodden earth, the grass short along its edges.
    if (F.counts.w > 0.0) open = min(open, smoothstep(0.5, 1.6, pathDistance(g, F, W)));
    return open;
}

// Blankets always lie on level ground (`Land.level`): within LEVEL_FLAT of a blanket's edge the land is
// brought down to LAND_GROUND, easing back to its own lie over LEVEL_BLEND beyond. 0…1.
#define LAND_GROUND -0.03
#define LEVEL_FLAT 6.0
#define LEVEL_BLEND 14.0
float levelAt(float2 g, constant Frame& F, constant World& W) {
    float k = 0.0;
    int n = int(F.counts.x);
    for (int i = 0; i < n; i++) {
        float4 c = W.clearings[i];
        k = max(k, 1.0 - smoothstep(LEVEL_FLAT, LEVEL_FLAT + LEVEL_BLEND, distance(g, c.xy) - max(c.z, 0.0)));
    }
    return k;
}

// How mown the grass is here, 0…1: a soft patch round each space's blankets. Also the stripe a mower
// leaves, −1…1, along the space's own direction.
float mownAt(float2 g, constant Frame& F, constant World& W, thread float& stripe) {
    float mown = 0.0;
    stripe = 0.0;
    int n = int(F.counts.x);
    for (int i = 0; i < n; i++) {
        float4 c = W.clearings[i];
        if (c.w <= 0.0) continue;
        float k = 1.0 - smoothstep(c.w - 2.2, c.w, distance(g, c.xy));
        if (k > mown) {
            mown = k;
            float a = W.patches[i].x;
            stripe = sign(sin(dot(g, float2(cos(a), sin(a))) * 1.05));
        }
    }
    return mown;
}

// Sunlight reaching the ground: dimmed under passing clouds and dappled beneath trees.
float3 shadeAt(float2 g, constant Frame& F, constant World& W) {
    float t = F.eye.w;
    float2 p = g * 0.03 + t * float2(0.014, 0.006);
    float cloud = 1.0 - smoothstep(0.52, 0.7, mNoise(p) * 0.65 + mNoise(p * 2.1 + 7.3) * 0.35);
    float tree = 1.0;
    // Dapple only matters within a crown's reach (it adds at most 0.385 to the distance there).
    int n = int(F.counts.y);
    float nearest = 2.0;
    for (int i = 0; i < n; i++) nearest = min(nearest, distance(g, W.trees[i].xy) / W.trees[i].z);
    if (nearest < 1.0) {
        float dapple = (mNoise(g * 0.5 + t * 0.07) * 0.5 + mNoise(g * 1.7 - t * 0.05) * 0.2) * 0.55;
        tree = smoothstep(0.35, 1.0, nearest + dapple);
    }
    // By moonlight colours drain toward blue, so the green field reads as night rather than a dim day.
    float3 moonlit = mix(float3(1.0), float3(0.52, 0.68, 1.15), F.fog.w);
    return mix(float3(0.8, 0.87, 0.86), float3(1.0), cloud) * mix(float3(0.66, 0.76, 0.72), float3(1.0), tree) * moonlit;
}

// How far the breeze pushes a plant top, per unit of height squared.
float2 windAt(float2 g, constant Frame& F) {
    float t = F.eye.w;
    float2 dir = normalize(float2(1.0, 0.35));
    float gust = mNoise(g * 0.045 - dir * t * 0.22);
    float flutter = sin(t * 2.6 + mHash(floor(g * 2.0)) * 6.283);
    return (dir * (0.12 + 0.88 * smoothstep(0.35, 0.85, gust)) + float2(flutter, -flutter) * 0.06) * F.fog.z;
}

// After dark every picnic sits in a pool of lamplight: full over the cloth, fading out over a few units
// of grass beyond it. It also says which way the light comes from: the middle of the picnics, a little
// above the cloth.
#define PICNIC_REACH 7.5
float picnicLight(float3 p, constant Frame& F, constant World& W, thread float3& from) {
    float light = 0.0;
    from = float3(0.0);
    float night = F.fog.w;
    if (night < 0.01) return 0.0;
    float t = F.eye.w;
    int n = int(F.counts.x);
    for (int i = 0; i < n; i++) {
        float4 c = W.clearings[i];
        float2 toward = c.xy - p.xz;
        float near = 1.0 - clamp((length(toward) - c.z * 0.7) / PICNIC_REACH, 0.0, 1.0);
        float fi = float(i);
        float w = near * near * near * (1.0 + 0.06 * sin(t * 5.3 + fi * 1.7) * sin(t * 2.1 + fi * 3.1));
        light += w;
        from += float3(toward.x, 1.4 - p.y, toward.y) * w;
    }
    return min(light, 1.25) * night;
}
float picnicLight2(float2 g, constant Frame& F, constant World& W) {
    float3 from;
    return picnicLight(float3(g.x, 0.0, g.y), F, W, from);
}
// The lamplight's colour: a candle-warm amber, set against the cool blue of the night.
constant float3 WARM = float3(1.0, 0.52, 0.17);

float3 srgbDecode(float3 s) { return select(pow((s + 0.055) / 1.055, 2.4), s / 12.92, s < 0.04045); }

// three.js Lambert: (hemisphere + direct) × diffuse / π
float3 lambertIrradiance(float3 n, constant Frame& F) {
    float3 hemi = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * n.y + 0.5);
    float3 direct = F.keyColor.rgb * max(dot(n, F.keyDir.xyz), 0.0) + F.rimColor.rgb * max(dot(n, F.rimDir.xyz), 0.0);
    return (hemi + direct) * M_1_PI_F;
}
// three.js linear fog: smoothstep(near, far, view depth).
float fogFactor(float3 world, constant Frame& F) {
    float depth = -(F.view * float4(world, 1)).z;
    return smoothstep(F.fog.x, F.fog.y, depth);
}
// three.js MeshStandardMaterial with no metal: GGX direct light plus the hemisphere as indirect light.
float D_GGX(float a, float nh) { float a2 = a * a; float d = nh * nh * (a2 - 1.0) + 1.0; return M_1_PI_F * a2 / (d * d); }
float V_GGX(float a, float nl, float nv) {
    float a2 = a * a;
    float gv = nl * sqrt(a2 + (1.0 - a2) * nv * nv), gl = nv * sqrt(a2 + (1.0 - a2) * nl * nl);
    return 0.5 / max(gv + gl, 1e-6);
}
float3 directLight(float3 L, float3 color, float3 N, float3 V, float3 diffuse, float rough) {
    float nl = saturate(dot(N, L));
    float3 H = normalize(L + V);
    float nv = saturate(dot(N, V)), nh = saturate(dot(N, H)), vh = saturate(dot(V, H));
    float a = max(rough * rough, 0.0525 * 0.0525);
    float f = 0.04 + 0.96 * exp2((-5.55473 * vh - 6.98316) * vh);
    float spec = f * V_GGX(a, nl, nv) * D_GGX(a, nh);
    return color * nl * (diffuse * M_1_PI_F + spec);
}
float3 standardLight(float3 N, float3 V, float3 diffuse, float rough, constant Frame& F) {
    float3 c = directLight(F.keyDir.xyz, F.keyColor.rgb, N, V, diffuse, rough) + directLight(F.rimDir.xyz, F.rimColor.rgb, N, V, diffuse, rough);
    float nv = saturate(dot(N, V));
    float4 c0 = float4(-1, -0.0275, -0.572, 0.022), c1 = float4(1, 0.0425, 1.04, -0.04);
    float4 r = rough * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28 * nv)) * r.x + r.y;
    float2 ab = float2(-1.04, 1.04) * a004 + r.zw;
    float3 hemi = mix(F.hemiGround.rgb, F.hemiSky.rgb, 0.5 * N.y + 0.5) * M_1_PI_F;
    return c + hemi * (diffuse + (0.04 * ab.x + ab.y));
}
"""#
}
