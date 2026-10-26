import std;
import vec;
import math;
import os;
import gfx;
import horizon from "../src";

fn finish(center: float3, near_radius: f32, far_distance: f32) {
    horizon::update(center, near_radius, far_distance, 1);
    horizon::drain();
    assert(horizon::ready && !horizon::building);
    assert(horizon::live_meshes == horizon::mesh_count);
    assert(horizon::live_meshes <= horizon::RINGS);
}

fn coarse_height(x: f32, z: f32, center: float3, near_radius: f32) -> f32 {
    let gx = floor(x / 8.0) * 8.0;
    let gz = floor(z / 8.0) * 8.0;
    let tx = (x - gx) / 8.0;
    let tz = (z - gz) / 8.0;
    let a = horizon::surface(gx, gz, center, near_radius).y;
    let b = horizon::surface(gx, gz + 8.0, center, near_radius).y;
    let c = horizon::surface(gx + 8.0, gz + 8.0, center, near_radius).y;
    let d = horizon::surface(gx + 8.0, gz, center, near_radius).y;
    if tz >= tx {
        return a + (c - b) * tx + (b - a) * tz;
    }
    a + (d - a) * tx + (c - d) * tz
}

fn detail_boundary_coverage() {
    var deepest_gap: f32 = 0.0;
    var skirt: ft::Vertex[>..] = [];
    world::skirt(skirt, float3 { 0.0, 10.0, 0.0 }, float3 { 2.0, 10.0, 0.0 });
    let skirt_depth = 10.0 - skirt[2].pos.y;
    for sample in 9 {
        let viewer = float3 { -sample * 64.0, 0.0, -sample * 48.0 };
        let center = float3 {
            floor(viewer.x / 64.0) * 64.0,
            0.0,
            floor(viewer.z / 64.0) * 64.0,
        };
        let cx = floor(viewer.x / 32.0);
        let cz = floor(viewer.z / 32.0);
        let left = (cx - 6.0) * 32.0;
        let right = (cx + 7.0) * 32.0;
        let front = (cz - 6.0) * 32.0;
        let back = (cz + 7.0) * 32.0;
        for i in 209 {
            let x: f32 = left + i * 2.0;
            let z: f32 = front + i * 2.0;
            deepest_gap = max(deepest_gap, world::height(x, front) - coarse_height(x, front, center, 192.0));
            deepest_gap = max(deepest_gap, world::height(x, back) - coarse_height(x, back, center, 192.0));
            deepest_gap = max(deepest_gap, world::height(left, z) - coarse_height(left, z, center, 192.0));
            deepest_gap = max(deepest_gap, world::height(right, z) - coarse_height(right, z, center, 192.0));
        }
    }
    print("LOD boundary coverage: largest sampled gap=", deepest_gap, " skirt_depth=", skirt_depth);
    assert(deepest_gap <= skirt_depth);
}

fn main() {
    world::seed = 73129;
    let started = clock();
    var vertices = horizon::build_ring(0, float3_0, 192.0, 2048.0);
    assert(vertices.len > 80000 && vertices.len < 110000);
    for vertex in vertices {
        assert(abs(vertex.pos.x) <= 512.0 && abs(vertex.pos.z) <= 512.0);

        assert(vertex.pos.y == vertex.pos.y);
        assert(abs(dot(vertex.normal, vertex.normal) - 1.0) < 0.001);
    }
    // The central fallback must exist before detailed chunks arrive.
    assert(horizon::ring_inner(0, 192.0, 2048.0) == 0.0);
    for ring in horizon::RINGS - 1 {
        assert(horizon::ring_outer(ring, 16384.0) == horizon::ring_inner(ring + 1, 192.0, 16384.0));
    }
    assert(!horizon::refine_cell(-384.0, -320.0, 256.0));
    for sample in 65 {
        let z: f32 = -512.0 + sample * 16.0;
        let fine = horizon::lod_surface(512.0, z + 8.0, float3_0, 192.0, 8.0, 512.0);
        let expected = horizon::parent_height(512.0, z + 8.0, 16.0);
        assert(abs(fine.y - expected) < 0.0001);
    }
    assert(horizon::surface(12.0, 23.0, float3_0, 192.0).y ==
        horizon::surface(12.0, 23.0, float3 { 256.0, 0.0, 256.0 }, 192.0).y);
    // Every LOD has the same mathematical height at the common endpoints.
    let edge = horizon::surface(512.0, 0.0, float3_0, 192.0);
    assert(edge.y == world::base_height(512.0, 0.0) - 4.0);
    assert(horizon::ring_outer(0, 2048.0) == horizon::ring_inner(1, 192.0, 2048.0));
    assert(horizon::ring_outer(1, 2048.0) == horizon::ring_inner(2, 192.0, 2048.0));
    assert(horizon::ring_outer(2, 2048.0) == horizon::ring_inner(3, 192.0, 2048.0));
    assert(horizon::refine_cell(-384.0, -320.0, 64.0));
    let flat_color = world::far_color(-123.0, -102.0, 1.8, float3 { 0.0, 1.0, 0.0 });
    assert(flat_color == world::color(-123.0, -102.0, 1.8, float3 { 0.0, 1.0, 0.0 }));
    // Refined far-cell skirts use the horizon origin for burial, not the tile's
    // own center, which would incorrectly lower distant edge tops by four m.
    var edge_vertices: ft::Vertex[>..] = [];
    horizon::boundary(edge_vertices, float3 { 1056.0, 0.0, 1056.0 }, 32.0, 8.0, 192.0, float3_0);
    for i in edge_vertices.len {
        let point = edge_vertices[i].pos;
        let expected = world::base_height(point.x, point.z) - 4.0;
        let bottom = i % 6 == 2 || i % 6 == 4 || i % 6 == 5;
        let y = point.y + (if bottom { 64.0 } else { 0.0 });
        assert(abs(y - expected) < 0.0001);
    }
    detail_boundary_coverage();

    assert(gfx::open_headless(1280, 800));
    horizon::init();
    horizon::update(float3_0, 192.0, 2048.0, 0);
    assert(!horizon::ready && horizon::live_meshes == 0);
    horizon::update(float3_0, 192.0, 2048.0, 1);
    assert(!horizon::ready && horizon::worker_busy);
    assert(horizon::mesh_count == 0 && horizon::live_meshes == 0);
    finish(float3_0, 192.0, 2048.0);
    assert(horizon::mesh_count == 4);
    for mesh in horizon::meshes() {
        assert(!mesh.casts_shadow && !mesh.receives_shadow);
    }
    let first_id = horizon::meshes()[0].vertices.id;
    let first_rebuilds = horizon::rebuilds;
    let first_uploads = horizon::uploaded_meshes;
    for frame in 100 {
        horizon::update(float3 { 63.0, 100.0, 63.0 }, 192.0, 2048.0, 1);
    }
    assert(horizon::rebuilds == first_rebuilds);
    assert(horizon::uploaded_meshes == first_uploads);
    assert(horizon::meshes()[0].vertices.id == first_id);

    // During a budgeted rebuild the previous complete horizon remains active.
    horizon::update(float3 { 257.0, 0.0, 257.0 }, 192.0, 2048.0, 1);
    assert(horizon::ready && horizon::building);
    assert(horizon::meshes()[0].vertices.id == first_id);
    assert(horizon::live_meshes == 4 && horizon::worker_busy);
    // A moving flight camera must still finish complete horizon sets, even
    // when it crosses a snap cell every frame. Pending centers are coalesced.
    let completed_before_travel = horizon::rebuilds;
    for lap in horizon::RINGS * 2 {
        horizon::update(float3 { lap * -128.0, 0.0, lap * 192.0 }, 192.0, 2048.0, 1);
        assert(horizon::live_meshes <= 8);
    }
    horizon::drain();
    assert(horizon::rebuilds > completed_before_travel);
    // Settings and seed changes still cancel an incompatible staging set.
    finish(float3 { -2048.0, 0.0, 1024.0 }, 256.0, 2432.0);
    assert(horizon::peak_meshes <= 8);
    assert(horizon::triangles > 60000 && horizon::triangles < 400000);
    let old_uploads = horizon::uploaded_meshes;
    let old_stale = horizon::stale_results;
    horizon::update(float3 { -1792.0, 0.0, 1024.0 }, 256.0, 2432.0, 1);
    assert(horizon::worker_busy);
    world::seed++;
    finish(float3 { -2048.0, 0.0, 1024.0 }, 256.0, 2432.0);
    assert(horizon::uploaded_meshes == old_uploads + 4);
    assert(horizon::stale_results == old_stale + 1);
    // Shrinking to the shortest horizon leaves three nonempty annuli, so the
    // former fourth GPU mesh must disappear rather than remaining resident.
    finish(float3 { -2048.0, 0.0, 1024.0 }, 192.0, 1536.0);
    assert(horizon::mesh_count == 3 && horizon::live_meshes == 3);
    finish(float3 { -2048.0, 0.0, 1024.0 }, 192.0, 2432.0);
    assert(horizon::mesh_count == 4 && horizon::live_meshes == 4);
    finish(float3 { -2048.0, 0.0, 1024.0 }, 192.0, 16384.0);
    assert(horizon::mesh_count == 6 && horizon::requested_far == 16384.0);
    assert(horizon::peak_meshes <= 12);
    assert(horizon::triangles < 500000);
    // Exercise the real projection from well above the original clipping plane.
    render::init();
    render::horizon_edge = horizon::requested_far;
    render::horizon_center = horizon::active_center;
    var dynamic: ft::Vertex[>..] = [];
    let heights: f32[3] = [130.0, 800.0, 4000.0];
    for height in heights {
        assert(gfx::frame());
        let eye = horizon::active_center + float3 { 0.0, height, 0.0 };
        let target = eye + float3 { -77.0, -55.0, -64.0 };
        render::draw_scene(horizon::meshes(), dynamic, eye, target, 0.18, 0.0, false);
        if height == 800.0 {
            assert(gfx::screenshot("build/flight-horizon-800m.png"));
            // Complementary old/new masks must cover every original pixel.
            var transition: render::Mesh[>..] = [];
            for source in horizon::meshes() {
                var old = source;
                old.dissolve = 0.5;
                transition.push(old);
            }
            for source in horizon::meshes() {
                var next = source;
                next.dissolve = -0.5;
                transition.push(next);
            }
            assert(gfx::frame());
            render::draw_scene(transition, dynamic, eye, target, 0.18, 0.0, false);
            assert(gfx::screenshot("build/flight-horizon-transition.png"));
            var opaque: u8[>..] = [];
            var blended: u8[>..] = [];
            assert(read_file("build/flight-horizon-800m.png", opaque));
            assert(read_file("build/flight-horizon-transition.png", blended));
            assert(opaque.len == blended.len);
            for byte in opaque.len {
                assert(opaque[byte] == blended[byte]);
            }
        }
    }
    assert(gfx::screenshot("build/flight-horizon-high.png"));
    print("Survey coverage: radius=", horizon::requested_far, " triangles=", horizon::triangles);
    render::shutdown();
    finish(float3 { -2048.0, 0.0, 1024.0 }, 192.0, 2048.0);
    assert(horizon::mesh_count == 4 && horizon::live_meshes == 4);
    horizon::shutdown();
    assert(horizon::live_meshes == 0 && horizon::mesh_count == 0);
    assert(horizon::uploaded_meshes == horizon::released_meshes);
    gfx::close();
    print(
        "horizon: PASS; ground_rings=4 survey_rings=6, max_live_meshes=", horizon::peak_meshes,
        " uploads=", horizon::uploaded_meshes,
        " releases=", horizon::released_meshes,
        " worker_generation_ms=", horizon::generation_total_ms,
        " transfer_ms=", horizon::transfer_ms,
        " upload_ms=", horizon::upload_ms,
        " elapsed_ms=", (clock() - started) * 1000.0,
    );
}
