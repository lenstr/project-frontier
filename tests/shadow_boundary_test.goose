// Coarse fallback must not receive the detailed terrain sheet's rectangular shadow.
import std;
import vec;
import os;
import gfx;
import render from "../src";

fn same_image(first: const u8[:], second: const u8[:]) -> bool {
    var a: u8[>..] = [];
    var b: u8[>..] = [];
    assert(read_file(first, a) && read_file(second, b));
    if a.len != b.len {
        return false;
    }
    for i in a.len {
        if a[i] != b[i] {
            return false;
        }
    }
    true
}

fn main() {
    assert(gfx::open_headless(640, 480));
    render::init();
    var ground: ft::Vertex[>..] = [];
    let a = float3 { -150.0, 0.0, -150.0 };
    let b = float3 { -150.0, 0.0, 150.0 };
    let c = float3 { 150.0, 0.0, 150.0 };
    let d = float3 { 150.0, 0.0, -150.0 };
    let color = ft::rgb(0.22, 0.62, 0.60);
    render::triangle(ground, a, b, c, color);
    render::triangle(ground, a, c, d, color);
    var floor_mesh = render::upload(ground);
    floor_mesh.casts_shadow = false;
    var building: ft::Vertex[>..] = [];
    render::chamfered_box(building, float3 { 0.0, 5.0, 0.0 }, float3 { 12.0, 10.0, 12.0 }, color, 0.5);
    var caster = render::upload(building);
    caster.receives_shadow = false;
    var dynamic: ft::Vertex[>..] = [];
    let eye = float3 { 100.0, 130.0, 100.0 };
    let paths: const u8[:][3] = [
        "build/shadow-disabled.png",
        "build/shadow-fallback.png",
        "build/shadow-detail.png",
    ];
    for pass in 3 {
        assert(gfx::frame());
        floor_mesh.receives_shadow = pass == 2;
        let meshes: render::Mesh[2] = [floor_mesh, caster];
        render::draw_scene(meshes, dynamic, eye, float3_0, 0.18, 0.0, pass != 0);
        assert(gfx::screenshot(paths[pass]));
    }
    assert(same_image(paths[0], paths[1]));
    assert(!same_image(paths[0], paths[2]));
    render::release(floor_mesh);
    render::release(caster);
    render::shutdown();
    gfx::close();
    print("shadow_boundary PASS: fallback equals unshadowed reference; detail retains cast shadows");
}
