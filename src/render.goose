// Low-poly triangle renderer. Geometry and GPU resource policy remain in Goose.
namespace render;
import std;
import vec;
import math;
import os;
import gfx;
import .types;

struct Mesh {
    vertices: gfx::Buffer,
    count: i64,
    casts_shadow: bool = true,
    receives_shadow: bool = true,
    // Zero is opaque, positive fades out, negative fades in with the same mask.
    dissolve: f32 = 0.0,
    plant_arrival: f32 = 1.0,
}

struct TransitionUniform { params: float4 }

struct CameraUniform { view_proj: gfx::mat4, light_view_proj: gfx::mat4 }

struct LightUniform {
    sun: float4,
    eye: float4,
    fog: float4,
    params: float4,
    distances: float4,
    terrain_center: float4,
    detail_center: float4,
}

struct SkyUniform { forward: float4, right: float4, up: float4, sun: float4, params: float4 }
var triangles: i64;
var draw_calls: i64;
var upload_ms: f64;
var dynamic_buffer: gfx::Buffer;
var dynamic_capacity: i64;
var scene_pipeline: gfx::Pipeline;
var wire_pipeline: gfx::Pipeline;
var wireframe = false;
var shadow_pipeline: gfx::Pipeline;
var sky_pipeline: gfx::Pipeline;
var shadow_map: gfx::Texture;
var shadow_compare: gfx::Sampler;
// Set to the visible chunk radius in metres; the last terrain ring dissolves into sky.
var stream_radius: f32 = 112.0;
var fog_clear: f32 = 140.0;
var visibility: f32 = 1600.0;
var horizon_edge: f32 = 2048.0;
var detached_shadows = false;
var shadow_anchor: float3;
var horizon_center: float3;
var detail_center: float3;

fn frustum(
    out: ft::Vertex[>..]&, p: float3, bottom_radius: f32, top_radius: f32,
    height: f32, color: float4, sides: i64,
) {
    let b = p - float3 { 0.0, height * 0.5, 0.0 };
    let t = p + float3 { 0.0, height * 0.5, 0.0 };
    for i in max(sides, 3) {
        let a: f32 = i * TAU / max(sides, 3);
        let aa: f32 = (i + 1) * TAU / max(sides, 3);
        let direction = float3 { cos(a), 0.0, sin(a) };
        let next = float3 { cos(aa), 0.0, sin(aa) };
        let ba = b + direction * ft::splat(bottom_radius);
        let bb = b + next * ft::splat(bottom_radius);
        let ta = t + direction * ft::splat(top_radius);
        let tb = t + next * ft::splat(top_radius);
        render::triangle(out, ba, ta, tb, color);
        render::triangle(out, ba, tb, bb, color);
        render::triangle(out, b, ba, bb, color);
        render::triangle(out, t, tb, ta, color);
    }
}

fn triangle(out: ft::Vertex[>..]&, a: float3, b: float3, c: float3, col: float4) {
    let n = cross(b - a, c - a);
    let sq = dot(n, n);
    if sq < 0.00000001 {
        return;
    }
    let normal = n * ft::splat(1.0 / sqrt(sq));
    out.push(ft::Vertex { a, normal, col });
    out.push(ft::Vertex { b, normal, col });
    out.push(ft::Vertex { c, normal, col });
}

fn turn(p: float3, yaw: f32) -> float3 {
    float3 { p.x * cos(yaw) + p.z * sin(yaw), p.y, -p.x * sin(yaw) + p.z * cos(yaw) }
}

fn box(out: ft::Vertex[>..]&, center: float3, size: float3, col: float4, yaw: f32) {
    let axes: float3[3] = [float3 { 1.0, 0.0, 0.0 }, float3 { 0.0, 1.0, 0.0 }, float3 { 0.0, 0.0, 1.0 }];
    let corners: float2[4] = [
        float2 { -1.0, -1.0 },
        float2 { 1.0, -1.0 },
        float2 { 1.0, 1.0 },
        float2 { -1.0, 1.0 },
    ];
    for face in 6 {
        let sign: f32 = if face % 2 == 0 { 1.0 } else { -1.0 };
        let n = axes[face / 2] * ft::splat(sign);
        let u = axes[(face / 2 + 1) % 3] * ft::splat(sign);
        let v = cross(n, u);
        var points: float3[4];
        for i in 4 {
            let corner = n + u * ft::splat(corners[i].x) + v * ft::splat(corners[i].y);
            let local = corner * size * ft::splat(0.5);
            points[i] = center + turn(local, yaw);
        }
        triangle(out, points[0], points[1], points[2], col);
        triangle(out, points[0], points[2], points[3], col);
    }
}

// Six inset panels, twelve bevel strips and eight corner facets.
fn chamfered_box(out: ft::Vertex[>..]&, center: float3, size: float3, col: float4, yaw: f32) {
    let half = size * ft::splat(0.5);
    let cut: f32 = min(size.x, min(size.y, size.z)) * 0.12;
    let axes: float3[3] = [float3 { 1.0, 0.0, 0.0 }, float3 { 0.0, 1.0, 0.0 }, float3 { 0.0, 0.0, 1.0 }];
    let dims: f32[3] = [half.x, half.y, half.z];
    for axis in 3 {
        let u = axes[(axis + 1) % 3];
        let v = axes[(axis + 2) % 3];
        let du = dims[(axis + 1) % 3] - cut;
        let dv = dims[(axis + 2) % 3] - cut;
        for si in 2 {
            let sign: f32 = if si == 0 { 1.0 } else { -1.0 };
            let c = axes[axis] * ft::splat(dims[axis] * sign);
            let p: float3[4] = [
                c + u * ft::splat(du) + v * ft::splat(dv),
                c - u * ft::splat(du) + v * ft::splat(dv),
                c - u * ft::splat(du) - v * ft::splat(dv),
                c + u * ft::splat(du) - v * ft::splat(dv),
            ];
            let a = center + turn(p[0], yaw);
            let b = center + turn(p[1], yaw);
            let cc = center + turn(p[2], yaw);
            let d = center + turn(p[3], yaw);
            if sign > 0.0 {
                triangle(out, a, b, cc, col);
                triangle(out, a, cc, d, col);
            } else {
                triangle(out, a, cc, b, col);
                triangle(out, a, d, cc, col);
            }
        }
        let uidx = (axis + 1) % 3;
        let vidx = (axis + 2) % 3;
        for us in 2 {
            for vs in 2 {
                let su: f32 = if us == 0 { 1.0 } else { -1.0 };
                let sv: f32 = if vs == 0 { 1.0 } else { -1.0 };
                let p = u * ft::splat(dims[uidx] * su) + v * ft::splat((dims[vidx] - cut) * sv);
                let q = u * ft::splat((dims[uidx] - cut) * su) + v * ft::splat(dims[vidx] * sv);
                let end = axes[axis] * ft::splat(dims[axis] - cut);
                let a = center + turn(p - end, yaw);
                let b = center + turn(q - end, yaw);
                let c = center + turn(q + end, yaw);
                let d = center + turn(p + end, yaw);
                if su * sv > 0.0 {
                    triangle(out, a, b, c, col);
                    triangle(out, a, c, d, col);
                } else {
                    triangle(out, a, c, b, col);
                    triangle(out, a, d, c, col);
                }
            }
        }
    }
    for xi in 2 {
        for yi in 2 {
            for zi in 2 {
                let x: f32 = if xi == 0 { 1.0 } else { -1.0 };
                let y: f32 = if yi == 0 { 1.0 } else { -1.0 };
                let z: f32 = if zi == 0 { 1.0 } else { -1.0 };
                let a = center + turn(float3 { half.x * x, (half.y - cut) * y, (half.z - cut) * z }, yaw);
                let b = center + turn(float3 { (half.x - cut) * x, half.y * y, (half.z - cut) * z }, yaw);
                let c = center + turn(float3 { (half.x - cut) * x, (half.y - cut) * y, half.z * z }, yaw);
                if x * y * z > 0.0 {
                    triangle(out, a, b, c, col);
                } else {
                    triangle(out, a, c, b, col);
                }
            }
        }
    }
}

fn cylinder(out: ft::Vertex[>..]&, center: float3, radius: f32, height: f32, col: float4, sides: i64) {
    let bottom = center - float3 { 0.0, height * 0.5, 0.0 };
    let top = center + float3 { 0.0, height * 0.5, 0.0 };
    for i in max(3, sides) {
        let a: f32 = i * TAU / max(3, sides);
        let b: f32 = (i + 1) * TAU / max(3, sides);
        let pa = float3 { cos(a) * radius, 0.0, sin(a) * radius };
        let pb = float3 { cos(b) * radius, 0.0, sin(b) * radius };
        triangle(out, bottom + pa, top + pa, top + pb, col);
        triangle(out, bottom + pa, top + pb, bottom + pb, col);
        triangle(out, top, top + pb, top + pa, col);
        triangle(out, bottom, bottom + pa, bottom + pb, col);
    }
}

fn cone(out: ft::Vertex[>..]&, center: float3, radius: f32, height: f32, col: float4, sides: i64) {
    let bottom = center - float3 { 0.0, height * 0.5, 0.0 };
    let top = center + float3 { 0.0, height * 0.5, 0.0 };
    for i in max(3, sides) {
        let a: f32 = i * TAU / max(3, sides);
        let b: f32 = (i + 1) * TAU / max(3, sides);
        let pa = float3 { cos(a) * radius, 0.0, sin(a) * radius };
        let pb = float3 { cos(b) * radius, 0.0, sin(b) * radius };
        triangle(out, bottom + pa, top, bottom + pb, col);
        triangle(out, bottom, bottom + pa, bottom + pb, col);
    }
}

fn octahedron(out: ft::Vertex[>..]&, center: float3, size: float3, col: float4, yaw: f32) {
    let top = center + float3 { 0.0, size.y * 0.5, 0.0 };
    let bottom = center - float3 { 0.0, size.y * 0.5, 0.0 };
    let edge: float3[4] = [
        float3 { size.x * 0.5, 0.0, 0.0 }, float3 { 0.0, 0.0, size.z * 0.5 },
        float3 { -size.x * 0.5, 0.0, 0.0 }, float3 { 0.0, 0.0, -size.z * 0.5 },
    ];
    for i in 4 {
        let a = center + turn(edge[i], yaw);
        let b = center + turn(edge[(i + 1) % 4], yaw);
        triangle(out, top, b, a, col);
        triangle(out, bottom, a, b, col);
    }
}

fn beam(out: ft::Vertex[>..]&, a: float3, b: float3, radius: f32, col: float4) {
    let delta = b - a;
    if dot(delta, delta) < 0.000001 {
        return;
    }
    let direction = normalize(delta);
    let reference = if abs(direction.y) > 0.9 { float3 { 1.0, 0.0, 0.0 } } else { float3 { 0.0, 1.0, 0.0 } };
    let u = normalize(cross(direction, reference)) * ft::splat(radius);
    let v = cross(direction, u);
    let ring: float3[4] = [u + v, u - v, -u - v, -u + v];
    for i in 4 {
        let p = ring[i];
        let q = ring[(i + 1) % 4];
        triangle(out, a + p, b + p, b + q, col);
        triangle(out, a + p, b + q, a + q, col);
    }
    triangle(out, a + ring[0], a + ring[1], a + ring[2], col);
    triangle(out, a + ring[0], a + ring[2], a + ring[3], col);
    triangle(out, b + ring[0], b + ring[2], b + ring[1], col);
    triangle(out, b + ring[0], b + ring[3], b + ring[2], col);
}

fn upload(verts: const ft::Vertex[:]) -> Mesh {
    if verts.len == 0 {
        return Mesh { .. };
    }
    let start = clock();
    let buffer = gfx::vertex_buffer(bytes_of(verts));
    upload_ms += (clock() - start) * 1000.0;
    return Mesh { buffer, verts.len };
}

fn release(m: Mesh) {
    if m.vertices.id != 0 {
        gfx::release(m.vertices);
    }
}

fn init() {
    let scene_vertex = embed_shader("vert", """
            layout(location = 0) in vec3 position;
            layout(location = 1) in vec3 normal;
            layout(location = 2) in vec4 color;
            layout(set = 1, binding = 0) uniform Camera {
                mat4 view_proj;
                mat4 light_view_proj;
            };
            layout(location = 0) out vec3 world;
            layout(location = 1) out vec3 norm;
            layout(location = 2) out vec4 tint;
            layout(location = 3) out vec4 shadow_position;
            void main() {
                world = position;
                norm = normal;
                tint = color;
                shadow_position = light_view_proj * vec4(position, 1.0);
                gl_Position = view_proj * vec4(position, 1.0);
            }
    """);
    let scene_fragment = embed_shader("frag", """
            layout(location = 0) in vec3 world;
            layout(location = 1) in vec3 norm;
            layout(location = 2) in vec4 tint;
            layout(location = 3) in vec4 shadow_position;
            layout(set = 2, binding = 0) uniform sampler2DShadow shadow_map;
            layout(set = 3, binding = 0) uniform Light {
                vec4 sun;
                vec4 eye;
                vec4 fog;
                vec4 params;
                vec4 distances;
                vec4 terrain_center;
                vec4 detail_center;
            };
            layout(set = 3, binding = 1) uniform Transition {
                vec4 transition;
            };
            layout(location = 0) out vec4 result;
            float shadow() {
                if (params.y < 0.5 || transition.y < 0.5) {
                    return 1.0;
                }
                vec3 p = shadow_position.xyz / shadow_position.w;
                vec2 uv = vec2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
                bool outside_uv = any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)));
                if (outside_uv || p.z < 0.0 || p.z > 1.0) {
                    return 1.0;
                }
                float bias = max(0.00035, 0.0011 * (1.0 - dot(normalize(norm), sun.xyz)));
                float value = 0.0;
                float texel = 1.0 / 2048.0;
                for (int y = -1; y <= 1; y++) {
                    for (int x = -1; x <= 1; x++) {
                        value += texture(shadow_map, vec3(uv + vec2(x, y) * texel, p.z - bias));
                    }
                }
                // Fade the finite shadow map at its border instead of exposing a square.
                float border = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
                float coverage = smoothstep(0.0, 0.12, border);
                coverage *= smoothstep(0.0, 0.08, p.z) * (1.0 - smoothstep(0.92, 1.0, p.z));
                return mix(1.0, 0.35 + 0.65 * value / 9.0, coverage);
            }
            void main() {
                float noise = fract(dot(floor(gl_FragCoord.xy), vec2(0.75487766, 0.56984029)));
                if (transition.x > 0.0 && noise < transition.x) {
                    discard;
                }
                if (transition.x < 0.0 && noise >= -transition.x) {
                    discard;
                }

                bool near_plant = tint.a <= -10.0;
                float material_alpha = near_plant ? -tint.a - 10.0 : abs(tint.a);
                if (near_plant && detail_center.w > 0.0) {
                    float d = max(abs(world.x - detail_center.x), abs(world.z - detail_center.z));
                    float opacity = 1.0 - smoothstep(detail_center.w * 0.55, detail_center.w * 0.88, d);
                    opacity = min(opacity, transition.z);
                    if (noise < 1.0 - opacity) {
                        discard;
                    }
                }
                if (tint.a < 0.0 && !near_plant) {
                    float d = max(abs(world.x - detail_center.x), abs(world.z - detail_center.z));
                    float radius = abs(detail_center.w);
                    float inner = radius * (detail_center.w > 0.0 ? 0.55 : 1.0);
                    float outer = radius * (detail_center.w > 0.0 ? 0.88 : 1.12);
                    float coarse = smoothstep(inner, outer, d);
                    if (noise >= coarse) {
                        discard;
                    }
                }
                vec3 n = normalize(norm);
                float daylight = params.x;
                float visibility = shadow();
                float direct = clamp((dot(n, sun.xyz) + 0.20) / 1.20, 0.0, 1.0);
                float hemi = n.y * 0.5 + 0.5;
                vec3 sky_ambient = mix(vec3(0.20, 0.22, 0.36), vec3(0.561, 0.702, 0.851) * 0.40, daylight);
                vec3 ground_ambient = mix(vec3(0.10, 0.085, 0.17), vec3(0.42, 0.353, 0.478) * 0.22, daylight);
                vec3 ambient = mix(ground_ambient, sky_ambient, hemi);
                ambient += vec3(0.30, 0.17, 0.14) * params.w * 0.6;
                vec3 warm = mix(vec3(0.557, 0.608, 0.851), vec3(1.0, 0.945, 0.839), daylight);
                warm = mix(warm, vec3(1.0, 0.698, 0.478), params.w * 0.8);
                vec3 direct_color = mix(vec3(0.231, 0.290, 0.416), warm, visibility);
                vec3 lit = tint.rgb * (ambient + direct_color * direct * (0.32 + 0.56 * daylight));
                lit += tint.rgb * max(material_alpha - 1.0, 0.0) * 0.8;
                float edge = pow(1.0 - max(dot(n, normalize(eye.xyz - world)), 0.0), 3.0) * 0.06;
                lit += fog.rgb * edge * 1.67;
                float distance_to_eye = length(world - eye.xyz);
                float fog_distance = max(distance_to_eye - distances.x, 0.0);
                float haze = 1.0 - exp(-fog_distance / (0.45 * distances.y));
                haze *= 1.0 - 0.45 * smoothstep(15.0, 90.0, world.y);
                vec2 from_center = abs(world.xz - terrain_center.xz);
                float terrain_edge_distance = max(from_center.x, from_center.y);
                haze = max(haze, smoothstep(distances.z * 0.88, distances.z, terrain_edge_distance));
                if (tint.a < 0.0 && !near_plant) {
                    // Keep merged distant forests in the atmospheric depth layers.
                    haze = max(haze, 0.60 * smoothstep(1500.0, 3500.0, distance_to_eye));
                }
                // Alpha >= 4 marks the objective's high-energy beacon material.
                if (material_alpha >= 4.0) {
                    haze = min(haze, 0.30);
                }
                vec3 ray = normalize(world - eye.xyz);
                vec3 atmosphere = fog.rgb + warm * pow(max(dot(ray, sun.xyz), 0.0), 8.0) * 0.35 * daylight;
                lit = mix(lit, atmosphere, haze);
                lit = clamp(lit, 0.0, 1.0);
                lit = mix(lit, lit * lit * (3.0 - 2.0 * lit), 0.25 * daylight);
                result = vec4(lit, 1.0);
            }
    """);
    scene_pipeline = gfx::pipeline(
        scene_vertex, scene_fragment,
        gfx::PipelineDesc { depth_test: true, depth_write: true, cull: gfx::CULL_NONE },
    );
    wire_pipeline = gfx::pipeline(
        scene_vertex, scene_fragment,
        gfx::PipelineDesc { depth_test: true, depth_write: true, cull: gfx::CULL_NONE, wireframe: true },
    );
    shadow_pipeline = gfx::pipeline(
        embed_shader("vert", """
            layout(location = 0) in vec3 position;
            layout(location = 1) in vec3 normal;
            layout(location = 2) in vec4 color;
            layout(set = 1, binding = 0) uniform Camera {
                mat4 view_proj;
                mat4 light_view_proj;
            };
            void main() {
                gl_Position = light_view_proj * vec4(position, 1.0);
            }
        """),
        embed_shader("frag", """ void main() {} """),
        gfx::PipelineDesc { depth_test: true, depth_write: true, depth_bias: 1.0, depth_bias_slope: 1.5 },
    );
    sky_pipeline = gfx::pipeline(
        embed_shader("vert", """
            layout(location = 0) out vec2 uv;
            void main() {
                vec2 p = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
                uv = p;
                gl_Position = vec4(p * 2.0 - 1.0, 0.9999, 1.0);
            }
        """),
        embed_shader("frag", """
            layout(location = 0) in vec2 uv;
            layout(set = 3, binding = 0) uniform Sky {
                vec4 forward;
                vec4 right;
                vec4 up;
                vec4 sun;
                vec4 params;
            };
            layout(location = 0) out vec4 result;
            float hash(vec2 p) {
                return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
            }
            void main() {
                vec2 p = uv * 2.0 - 1.0;
                vec3 ray = normalize(forward.xyz + right.xyz * p.x * params.y + up.xyz * p.y * params.z);
                float d = params.x;
                float h = max(ray.y, 0.0);
                float dusk = sun.w;
                vec3 horizon = mix(vec3(0.118, 0.157, 0.314), vec3(0.749, 0.878, 0.855), d);
                horizon = mix(horizon, vec3(0.910, 0.627, 0.478), dusk * 0.6);
                vec3 zenith = mix(vec3(0.043, 0.063, 0.149), vec3(0.243, 0.498, 0.722), d);
                zenith = mix(zenith, vec3(0.290, 0.290, 0.549), dusk * 0.8);
                vec3 color = mix(horizon, zenith, pow(clamp(h * 1.3, 0.0, 1.0), 0.6));
                float sun_dot = max(dot(ray, sun.xyz), 0.0);
                vec3 sun_color = mix(vec3(1.0, 0.945, 0.839), vec3(1.0, 0.698, 0.478), dusk * 0.8);
                color += sun_color * pow(sun_dot, 8.0) * d * 0.35;
                color += vec3(1.0, 0.91, 0.65) * smoothstep(0.99955, 0.9998, sun_dot) * d;
                vec3 planet_dir = normalize(vec3(-0.910, 0.122, -0.400));
                float planet = dot(ray, planet_dir);
                float radius = 0.087266;
                float disk = smoothstep(cos(radius), cos(radius - 0.003), planet);
                vec3 o = (ray - planet_dir) / sin(radius);
                float r2 = dot(o, o);
                vec3 nrm = normalize(o + planet_dir * sqrt(max(0.0, 1.0 - r2)));
                float bands = smoothstep(-0.3, 0.3, sin(ray.y * 90.0 + ray.x * 22.5));
                vec3 planet_color = mix(vec3(0.788, 0.651, 0.784), vec3(0.914, 0.784, 0.847), bands);
                planet_color *= 0.35 + 0.65 * max(dot(nrm, sun.xyz), 0.0);
                planet_color = mix(planet_color, horizon, smoothstep(0.85, 1.0, sqrt(r2)) * 0.25);
                planet_color = mix(planet_color, color, d * (0.55 + 0.25 * d));
                color = mix(color, planet_color, disk);
                vec2 star_cell = floor(ray.xz / max(abs(ray.y) + 0.2, 0.2) * 210.0);
                float star = step(0.9975, hash(star_cell)) * smoothstep(0.26, 0.5, ray.y);
                color += star * (1.0 - d) * 0.6;
                color = clamp(color, 0.0, 1.0);
                color = mix(color, color * color * (3.0 - 2.0 * color), 0.25 * d);
                result = vec4(color, 1.0);
            }
        """),
    );
    shadow_map = gfx::depth_target(2048, 2048);
    shadow_compare = gfx::shadow_sampler();
    gfx::check();
}

fn draw_meshes(meshes: const Mesh[:], dynamic_count: i64, shadow_pass: bool) {
    var dissolve: f32 = 2.0;
    var receives_shadow = false;
    var plant_arrival: f32 = -1.0;
    for m in meshes {
        if shadow_pass && !m.casts_shadow {
            continue;
        }
        if m.count <= 0 || m.vertices.id == 0 {
            continue;
        }
        if !shadow_pass && (m.dissolve != dissolve || m.receives_shadow != receives_shadow || m.plant_arrival != plant_arrival) {
            dissolve = m.dissolve;
            receives_shadow = m.receives_shadow;
            plant_arrival = m.plant_arrival;
            gfx::uniforms(gfx::FRAGMENT, 1, TransitionUniform {
                float4 { dissolve, if receives_shadow { 1.0 } else { 0.0 }, plant_arrival, 0.0 },
            });
        }
        gfx::bind_vertex_buffer(m.vertices);
        gfx::draw(m.count);
        draw_calls++;
    }
    if dynamic_count > 0 {
        if !shadow_pass && (dissolve != 0.0 || !receives_shadow || plant_arrival != 1.0) {
            gfx::uniforms(gfx::FRAGMENT, 1, TransitionUniform { float4 { 0.0, 1.0, 1.0, 0.0 } });
        }
        gfx::bind_vertex_buffer(dynamic_buffer);
        gfx::draw(dynamic_count);
        draw_calls++;
    }
}

// day is phase: 0 sunrise, .25 noon, .5 sunset, .75 midnight.
fn draw_scene(
    meshes: const Mesh[:], dynamic: const ft::Vertex[:], eye: float3, target: float3,
    day: f32, seconds: f32, shadows: bool,
) {
    triangles = dynamic.len / 3;
    draw_calls = 0;
    for m in meshes {
        triangles += m.count / 3;
    }
    let upload_start = clock();
    if dynamic.len > 0 {
        let raw = bytes_of(dynamic);
        if raw.len > dynamic_capacity {
            if dynamic_buffer.id != 0 {
                gfx::release(dynamic_buffer);
            }
            dynamic_capacity = max(raw.len * 2, 262144);
            dynamic_buffer = gfx::buffer(gfx::BUFFER_VERTEX, dynamic_capacity, raw);
        } else {
            gfx::update_buffer(dynamic_buffer, raw);
        }
    }
    upload_ms = (clock() - upload_start) * 1000.0;
    let size = gfx::screen_size();
    let aspect: f32 = size.x as f32 / max(size.y, 1);
    let angle: f32 = day * TAU;
    let raw_sun_y: f32 = sin(angle) * 0.72;
    let sun = normalize(float3 { -cos(angle) * 0.72, max(raw_sun_y, 0.17), 0.44 });
    let dusk_t: f32 = clamp(abs(raw_sun_y - 0.12) / 0.35, 0.0, 1.0);
    let dusk: f32 = 1.0 - dusk_t * dusk_t * (3.0 - 2.0 * dusk_t);
    let daylight: f32 = clamp(sin(angle) * 2.2 + 0.23, 0.0, 1.0);
    let horizontal_forward = normalize(float3 { target.x - eye.x, 0.0, target.z - eye.z });
    let grounded_target = if detached_shadows { shadow_anchor } else { float3 { target.x, target.y - 1.2, target.z } };
    let focus = grounded_target + horizontal_forward * ft::splat(40.0);
    let light_eye = focus + sun * ft::splat(120.0);
    let up_axis = float3 { 0.0, 1.0, 0.0 };
    let light_projection = gfx::ortho(-80.0, 80.0, -80.0, 80.0, 1.0, 260.0);
    let light_view_proj = gfx::mul(light_projection, gfx::look_at(light_eye, focus, up_axis));
    // Cover the square horizon's corners and high survey viewpoints as well.
    let far_clip = max(3200.0, horizon_edge * 1.8 + abs(eye.y));
    // Survey has no nearby suit geometry; a one-metre near plane preserves
    // depth precision when the far plane grows to tens of kilometres.
    let near_clip: f32 = if horizon_edge > 4096.0 { 1.0 } else { 0.08 };
    let projection = gfx::perspective(0.95993, aspect, near_clip, far_clip);
    let camera = CameraUniform {
        gfx::mul(projection, gfx::look_at(eye, target, up_axis)),
        light_view_proj,
    };
    gfx::begin_pass(gfx::PassDesc { depth: shadow_map });
    if shadows {
        gfx::bind(shadow_pipeline);
        gfx::uniforms(gfx::VERTEX, 0, camera);
        draw_meshes(meshes, dynamic.len, true);
    }
    gfx::end_pass();
    let fog_day = float3 { 0.749, 0.878, 0.855 };
    let fog_night = float3 { 0.118, 0.157, 0.314 };
    let fog_base = fog_night * ft::splat(1.0 - daylight) + fog_day * ft::splat(daylight);
    let fog = fog_base * ft::splat(1.0 - dusk * 0.6) + float3 { 0.910, 0.627, 0.478 } * ft::splat(dusk * 0.6);
    gfx::begin_screen(float4 { fog.x, fog.y, fog.z, 1.0 });
    gfx::bind(sky_pipeline);
    let forward = normalize(target - eye);
    let right = normalize(cross(forward, float3 { 0.0, 1.0, 0.0 }));
    let up = cross(right, forward);
    gfx::uniforms(gfx::FRAGMENT, 0, SkyUniform {
        float4 { forward.x, forward.y, forward.z, 0.0 },
        float4 { right.x, right.y, right.z, 0.0 },
        float4 { up.x, up.y, up.z, 0.0 },
        float4 { sun.x, sun.y, sun.z, dusk },
        float4 { daylight, aspect * 0.52057, 0.52057, seconds },
    });
    gfx::draw(3);
    draw_calls++;
    gfx::bind(if wireframe { wire_pipeline } else { scene_pipeline });
    gfx::uniforms(gfx::VERTEX, 0, camera);
    let fog_density = 0.833 / max(0.70 * stream_radius - 40.0, 12.0);
    gfx::uniforms(gfx::FRAGMENT, 0, LightUniform {
        float4 { sun.x, sun.y, sun.z, 0.0 },
        float4 { eye.x, eye.y, eye.z, 0.0 },
        float4 { fog.x, fog.y, fog.z, fog_density },
        float4 { daylight, if shadows { 1.0 } else { 0.0 }, seconds, dusk },
        float4 { fog_clear, visibility, horizon_edge, 0.0 },
        float4 { horizon_center.x, horizon_center.y, horizon_center.z, 0.0 },
        float4 { detail_center.x, detail_center.y, detail_center.z, stream_radius * (if detached_shadows { 1.0 } else { -1.0 }) },
    });
    gfx::bind_texture(gfx::FRAGMENT, 0, shadow_map, shadow_compare);
    draw_meshes(meshes, dynamic.len, false);
    gfx::end_pass();
}

fn shutdown() {
    if dynamic_buffer.id != 0 {
        gfx::release(dynamic_buffer);
    }
    dynamic_buffer = gfx::Buffer { 0 };
    dynamic_capacity = 0;
    gfx::release(scene_pipeline);
    gfx::release(wire_pipeline);
    gfx::release(shadow_pipeline);
    gfx::release(sky_pipeline);
    gfx::release(shadow_map);
    gfx::release(shadow_compare);
}
