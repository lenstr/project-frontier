import std;
import vec;
import math;
import os;
import gfx;
import render from "../src";

fn main() {
    var frames: i64 = 3;
    let argv = args();
    if argv.len == 3 && argv[1] == "--frames" {
        let n, ok = parse_int(argv[2]);
        if ok {
            frames = max(n, 1);
        }
    }
    guard gfx::open("Project Frontier — renderer smoke", 1280, 720, gfx::WINDOW_RESIZABLE) else {
        print(gfx::error());
        exit(1);
    }
    render::init();
    var geometry: ft::Vertex[>..] = [];
    for zi in -18..18 {
        for xi in -18..18 {
            let x: f32 = xi;
            let z: f32 = zi;
            let a = float3 { x * 2.0, sin(x * 0.2) * cos(z * 0.18), z * 2.0 };
            let b = float3 { (x + 1) * 2.0, sin((x + 1) * 0.2) * cos(z * 0.18), z * 2.0 };
            let c = float3 { (x + 1) * 2.0, sin((x + 1) * 0.2) * cos((z + 1) * 0.18), (z + 1) * 2.0 };
            let d = float3 { x * 2.0, sin(x * 0.2) * cos((z + 1) * 0.18), (z + 1) * 2.0 };
            render::triangle(geometry, a, c, b, ft::rgb(0.23, 0.53, 0.41));
            render::triangle(geometry, a, d, c, ft::rgb(0.25, 0.57, 0.44));
        }
    }
    for ii in 20 {
        let i: f32 = ii;
        let x: f32 = sin(i * 5.3) * 20.0;
        let z: f32 = cos(i * 3.1) * 20.0;
        render::cylinder(geometry, float3 { x, 1.2, z }, 0.22, 3.0, ft::rgb(0.28, 0.20, 0.32), 6);
        let crown_color = ft::rgb(0.60, 0.35, 0.62);
        render::octahedron(geometry, float3 { x, 3.6, z }, float3 { 3.4, 3.8, 3.4 }, crown_color, i * 0.4);
    }
    render::cylinder(geometry, float3 { 0.0, 0.7, 0.0 }, 2.4, 1.4, ft::rgb(0.72, 0.78, 0.76), 8);
    let body_color = ft::rgb(0.84, 0.88, 0.82);
    render::chamfered_box(geometry, float3 { 0.0, 1.5, 0.0 }, float3 { 2.6, 1.2, 2.6 }, body_color, 0.2);
    render::cone(geometry, float3 { 0.0, 2.5, 0.0 }, 1.4, 0.8, ft::rgb(0.30, 0.65, 0.66), 8);
    let mast_color = ft::rgb(0.92, 0.63, 0.28);
    render::beam(geometry, float3 { 0.0, 2.9, 0.0 }, float3 { 0.0, 7.0, 0.0 }, 0.12, mast_color);
    let mesh = render::upload(geometry);
    let meshes: render::Mesh[1] = [mesh];
    var dynamic: ft::Vertex[>..] = [];
    let glow = float4 { 0.18, 0.90, 0.90, 1.4 };
    render::octahedron(dynamic, float3 { 3.2, 1.2, 0.0 }, float3 { 1.2, 2.4, 1.2 }, glow, 0.0);
    var drawn = 0;
    while gfx::frame() {
        let eye = float3 { 15.0, 10.0, 19.0 };
        let target = float3 { 0.0, 1.0, 0.0 };
        render::draw_scene(meshes, dynamic, eye, target, 0.18, drawn / 60.0, true);
        drawn++;
        if drawn == frames {
            break;
        }
    }
    assert(gfx::screenshot("build/render-smoke.png"));
    assert(render::dynamic_capacity > 0);
    print(
        "render_smoke PASS frames=", drawn, " triangles=", render::triangles,
        " calls=", render::draw_calls,
    );
    render::release(mesh);
    render::shutdown();
    gfx::close();
}
