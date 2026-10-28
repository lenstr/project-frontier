// Native mesh lifetime and exact identity checks through body-cache reuse.
import std;
import vec;
import gfx;
import scene from "../src";

fn main() {
    assert(gfx::open_headless(128, 96));
    scene::init();
    sim::player = float3_0;
    var handles: ecs::Handle[>..] = [];
    for index in 128 {
        let position = float3 { -180.0 + (index % 16) * 3.0, 1.8, (index / 16) * 3.0 };
        let handle = ecs::spawn(sim::SMELTER, position);
        ecs::entities[handle.slot].powered = true;
        handles.push(handle);
    }
    let eye = float3 { 0.0, 100.0, 0.0 };
    scene::sync_buildings(eye, 0.0);
    assert(scene::building_live_meshes == 2);
    for handle in handles {
        assert(scene::building_cached(handle.slot));
    }
    let first = handles[0];
    let old_buffer = scene::building_batches[0].mesh.vertices.id;
    ecs::destroy(first);
    let replacement = ecs::spawn(sim::STORAGE, float3 { -180.0, 1.8, 0.0 });
    assert(replacement.slot == first.slot && replacement.generation != first.generation);
    scene::sync_buildings(eye, 0.1);
    assert(scene::building_stamps[first.slot].generation == replacement.generation);
    assert(scene::building_stamps[first.slot].kind == sim::STORAGE);
    assert(scene::building_batches[0].mesh.vertices.id != old_buffer);
    // Near-field transitions remove the cached body instead of double-drawing it.
    scene::sync_buildings(float3 { -180.0, 4.0, 0.0 }, 0.2);
    assert(!scene::building_cached(replacement.slot));
    assert(scene::building_live_meshes == 0);
    scene::sync_buildings(eye, 0.3);
    assert(scene::building_live_meshes == 2);
    let slots = scene::building_batches.len;
    for frame in 120 {
        scene::sync_buildings(eye, frame / 60.0);
        assert(scene::building_batches.len == slots);
        assert(scene::building_live_meshes == 2);
        assert(scene::building_uploads - scene::building_releases == 2);
    }
    ecs::clear();
    scene::sync_buildings(eye, 3.0);
    assert(scene::building_live_meshes == 0);
    scene::shutdown();
    assert(scene::building_uploads == scene::building_releases);
    gfx::close();
    print("building_cache PASS: stable batch slots, near/far transitions, generation reuse; uploads=",
          scene::building_uploads, " releases=", scene::building_releases);
}
