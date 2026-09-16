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
#define MAX_STREAMS 4
#define MAX_PATHS 32

struct Frame {
    float4x4 viewProj;
    float4x4 view;
    float4x4 proj;
    float4x4 invViewProj;
    float4 eye;          // xyz camera position, w meadow time (kit.ts uTime)
    float4 fog;          // near, far, wind (uWind), night (uNight)
    float4 counts;       // clearings, unused, streams, trodden path strips
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
    float4 viewport;     // drawable width, height (px), pixels per point, 1 to mark holes in the ground (tests)
    float4 sky2;         // stars and moon opacity, cloud glow, moonlit (0 day … 1 night), unused
    float4 camRight;     // camera right and up in the world, for sprites and particles
    float4 camUp;
    float4 wind;         // which way the wind blows (x, z), how far its gusts have travelled (Stage.gustDrift)
    float4 weather;      // a gust's share kept between gusts, lightning's flash 0…1, unused, unused
};

// Each blanket: x, z, radius (eased, as kit.ts uClearings) and the radius of the mown patch round it.
// Each patch: stripe angle, space index, and in a sidebar's column its flag's half width (0 for none)
// and how far behind the blanket's middle it stands.
// Each stream: x at z = 0, how far it wanders, its phase, its half width. Each strip of path trodden
// between a worktree's blanket and its repository's: where it starts and ends (x, z each).
struct World {
    float4 clearings[MAX_CLEARINGS];
    float4 patches[MAX_CLEARINGS];
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
// `blankets`: the same, for the blankets alone (the painted ground gives way to them, `paintedAt`).
float openGround(float2 g, constant Frame& F, constant World& W, thread float& blankets) {
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
    blankets = open;
    if (F.counts.z > 0.0) {
        float s = streamDistance(g, F, W);
        open = min(open, s < 0.3 ? 0.0 : mix(0.35, 1.0, smoothstep(0.3, 2.2, s)));
    }
    // A path's stepping stones lie in bare trodden earth, the grass short along its edges.
    if (F.counts.w > 0.0) open = min(open, smoothstep(0.5, 1.6, pathDistance(g, F, W)));
    return open;
}
float openGround(float2 g, constant Frame& F, constant World& W) {
    float blankets;
    return openGround(g, F, W, blankets);
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

// The ground's map (`GroundMap`), baked from the scenery: painted ground, the trees' shade and lamplight.
// Bilinear between texel middles; nothing outside it.
#define GROUND_MAP_REACH \#(GroundMap.reach)
constexpr sampler groundMapSampler(coord::normalized, address::clamp_to_zero, filter::linear);
float4 groundMapAt(float2 g, texture2d<float> map) {
    return map.sample(groundMapSampler, g / (2.0 * GROUND_MAP_REACH) + 0.5, level(0));
}
// Where the ground and the grass read the map: a little off the point, by noise up to about two-thirds of a
// unit each way, so a painted edge wanders as grass grows back instead of following the grid of cells; a
// single dab reads round, a straight stroke's sides uneven. The trees' shade, smooth over many units, is
// read there too and does not mind.
float2 paintWarp(float2 g) {
    float2 broad = float2(mNoise(g * 0.42 + 17.0), mNoise(g * 0.42 - 9.0)) - 0.5;
    float2 fine = float2(mNoise(g * 1.6 + 3.0), mNoise(g * 1.6 - 21.0)) - 0.5;
    return broad * 1.1 + fine * 0.35;
}

// The painted ground (`GroundMap`) at a point, from the map's sample `m`, as the land and the grass take it:
// how worn it is (1 bare earth, about ½ the grass trodden short), how much is mown lawn and how much tilled
// soil. Each edge is pushed either way by noise, as grass grows back unevenly, so nothing reads as drawn; and
// each fades out within a blanket's clearing and the trodden ring round it (`blankets`, from `openGround`),
// so a cat and its blanket always lie on the blanket's own ground.
struct Painted { float worn; float lawn; float soil; };
Painted paintedAt(float2 g, float4 m, float blankets) {
    float keep = smoothstep(0.14, 0.9, blankets);
    float n = (mNoise(g * 1.1) - 0.5) * 0.7 + (mNoise(g * 3.7 + 5.0) - 0.5) * 0.35;
    float3 w = m.rgb;
    // Only at an edge (a weight between 0 and 1), never inside or out.
    w = saturate(w + n * 4.0 * w * (1.0 - w));
    Painted p;
    p.worn = w.r * keep;
    p.lawn = smoothstep(0.25, 0.75, w.g) * keep;
    p.soil = smoothstep(0.3, 0.7, w.b) * keep;
    return p;
}
// A painted lawn's stripes, −1…1: the mower's passes run along the meadow (z), each about three units wide,
// soft and a little wavering, as a real mower leaves them.
float lawnStripe(float2 g) { return sin(g.x * 1.05 + (mNoise(g * 0.25) - 0.5) * 0.8); }
// Soft round specks scattered over the ground, 0…1: in each cell of a grid `scale` to the unit (turned off
// the meadow's axes, so no row of them lines up), at most one speck, there with chance `density`, a round dot
// of up to `size` of a cell across, its edge soft. Specks smaller than a pixel fade out rather than shimmer.
// For the fragment shader only (it reads how fast the grid passes across the screen).
float speckle(float2 g, float scale, float density, float size) {
    float2 p = float2(g.x * 0.8 + g.y * 0.6, g.y * 0.8 - g.x * 0.6) * scale;
    float2 cell = floor(p);
    float2 centre = cell + 0.27 + 0.46 * float2(mHash(cell), mHash(cell + float2(13.0, 71.0)));
    float pick = mHash(cell + float2(37.0, 11.0));
    float r = size * 0.5 * (0.55 + 0.45 * mHash(cell + float2(5.0, 29.0)));
    float blur = max(fwidth(p.x), fwidth(p.y));
    float speck = 1.0 - smoothstep(r * 0.45, r + blur, distance(p, centre));
    return pick < density ? speck * saturate(r * 2.0 / max(blur, 1e-4) - 0.5) : 0.0;
}
// A path's earth: dry, compacted and pale sandy tan, worn smoothest and palest along its middle (`worn` 1) and a
// little darker where the grass closes in at its edges; small pebbles and grit trodden into it.
float3 pathEarth(float2 g, float worn) {
    float3 earth = float3(0.44, 0.335, 0.195) * (0.92 + 0.12 * mNoise(g * 0.7 + 3.0) + 0.05 * mNoise(g * 2.3 - 7.0));
    earth *= mix(0.84, 1.06, smoothstep(0.45, 0.95, worn));
    // Pebbles a little greyer than the earth and few, each with a dark rim where it is pressed in; grit finer.
    float pebbles = speckle(g, 2.6, 0.16, 0.5), rims = speckle(g, 2.6, 0.16, 0.62), grit = speckle(g + 9.0, 9.0, 0.5, 0.5);
    earth *= 1.0 - 0.22 * saturate(rims - pebbles);
    earth = mix(earth, float3(0.5, 0.46, 0.39), pebbles * 0.65);
    return earth * (1.0 - 0.12 * grit);
}
// Tilled soil: dark, rich and crumbly, turned in low ridges along x, deep shade in the furrows and drier
// crumbs on the crests, darkest at its edge where the bed is cut out of the turf (`soil` there under 1).
float3 soilEarth(float2 g, float soil) {
    float ridge = sin(g.y * 3.0 + (mNoise(g * 0.6) - 0.5) * 2.0) * 0.5 + 0.5;
    float3 earth = mix(float3(0.05, 0.03, 0.019), float3(0.11, 0.068, 0.04), smoothstep(0.1, 0.9, ridge));
    float crumbs = speckle(g, 5.5, 0.55, 0.6) * smoothstep(0.35, 0.8, ridge), pores = speckle(g - 4.0, 8.0, 0.45, 0.5);
    earth = mix(earth, float3(0.16, 0.11, 0.07), crumbs * 0.75) * (1.0 - 0.3 * pores);
    return earth * mix(0.7, 1.0, smoothstep(0.55, 0.95, soil));
}

// Sunlight reaching the ground: dimmed under clouds passing with the wind and dappled beneath trees
// (`treeShade`: the trees' shade the ground's map holds there, its alpha).
float3 shadeFrom(float2 g, constant Frame& F, float treeShade) {
    float t = F.eye.w;
    float2 p = g * 0.03 - F.wind.zw * 0.07;
    float cloud = 1.0 - smoothstep(0.52, 0.7, mNoise(p) * 0.65 + mNoise(p * 2.1 + 7.3) * 0.35);
    float tree = 1.0;
    // How near the nearest crown's middle, as a share of its reach (1 at the reach and beyond). Dapple only
    // matters within a crown's reach (it adds at most 0.385 to the distance there).
    float nearest = 1.0 - treeShade;
    if (nearest < 1.0) {
        float dapple = (mNoise(g * 0.5 + t * 0.07) * 0.5 + mNoise(g * 1.7 - t * 0.05) * 0.2) * 0.55;
        tree = smoothstep(0.35, 1.0, nearest + dapple);
    }
    // By moonlight colours drain toward blue, so the green field reads as night rather than a dim day.
    float3 moonlit = mix(float3(1.0), float3(0.52, 0.68, 1.15), F.fog.w);
    return mix(float3(0.8, 0.87, 0.86), float3(1.0), cloud) * mix(float3(0.66, 0.76, 0.72), float3(1.0), tree) * moonlit;
}
float3 shadeAt(float2 g, constant Frame& F, texture2d<float> map) {
    return shadeFrom(g, F, groundMapAt(g, map).a);
}

// How far the wind pushes a plant top, per unit of height squared: gusts passing over in waves along the
// wind, and between them the wind's steady share.
float2 windAt(float2 g, constant Frame& F) {
    float t = F.eye.w;
    float gust = mNoise(g * 0.045 - F.wind.zw);
    float flutter = sin(t * 2.6 + mHash(floor(g * 2.0)) * 6.283);
    float calm = F.weather.x;
    return (F.wind.xy * (calm + (1.0 - calm) * smoothstep(0.35, 0.85, gust)) + float2(flutter, -flutter) * 0.06) * F.fog.z;
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
