import std;
import math;
import os;
import world from "../src";

fn settle(x: f32, z: f32, radius: i64) {
    let diameter = radius * 2 + 1;
    let batches = (diameter * diameter + world::MAX_JOBS - 1) / world::MAX_JOBS + 2;
    for i in batches {
        world::stream(x, z, radius, 8);
        world::drain();
    }
}

fn terrain_properties() {
    for i in 16 {
        let angle: f32 = i * 6.2831853 / 16.0;
        assert(world::base_height(cos(angle) * 12.0, sin(angle) * 12.0) == 1.8);
    }
    for ui in -2..3 {
        for vi in -2..3 {
            let u: f32 = ui * 40.0;
            let v: f32 = vi * 36.0;
            let x = -123.0 + u * 0.64 - v * 0.77;
            let z = -102.0 - u * 0.77 - v * 0.64;
            assert(world::district_distance(x, z) == 0.0);
            assert(world::base_height(x, z) == 1.8);
            assert(world::height(x, z) == 1.8);
        }
    }
    // The apron connects the landing to the district with no ridge in the
    // actual interpolated collision surface, including negative chunk borders.
    var previous: f32 = 1.8;
    for i in 465 {
        let v: f32 = i * 0.5;
        let x = -0.77 * v;
        let z = -0.64 * v;
        let floor = world::height(x, z);
        assert(floor == 1.8);
        assert(abs(floor - previous) < 0.0001);
        previous = floor;
    }
    for ui in -4..5 {
        for vi in 1..23 {
            let u: f32 = ui * 4.0;
            let v: f32 = vi * 4.0;
            let x = u * 0.64 - v * 0.77;
            let z = -u * 0.77 - v * 0.64;
            assert(world::base_height(x, z) == 1.8);
            assert(world::height(x, z) == 1.8);
        }
    }
    let amber_x: f32 = -121.0;
    let amber_z: f32 = -207.0;
    let fungal_x: f32 = -226.0;
    let fungal_z: f32 = -81.0;
    let amber_climate = world::climate(amber_x, amber_z);
    let fungal_climate = world::climate(fungal_x, fungal_z);
    let amber_weights = world::climate_weights(amber_climate);
    let fungal_weights = world::climate_weights(fungal_climate);
    print(
        "framing climates: amber=", amber_climate, " weights=", amber_weights,
        " fungal=", fungal_climate, " weights=", fungal_weights
    );
    assert(world::biome(amber_x, amber_z) == 1);
    assert(world::biome(fungal_x, fungal_z) == 2);
    assert(amber_weights.y == 1.0 && fungal_weights.z == 1.0);
    assert(world::biome(-123.0, -102.0) == 0);
    assert(amber_climate == world::climate_at(amber_x, amber_z, world::seed));
    assert(world::biome(0.0, 0.0) == 0);
    let distant_climate = world::noise(4096.0 / 160.0 + 1.5, -4096.0 / 160.0 - 2.0, world::seed + 101);
    assert(world::climate(4096.0, -4096.0) == distant_climate);
    // Both anchors sit about 240 metres away, twenty degrees to either side of
    // the default camera's forward axis, rather than outside its useful frame.
    let amber_distance = sqrt(amber_x * amber_x + amber_z * amber_z);
    let fungal_distance = sqrt(fungal_x * fungal_x + fungal_z * fungal_z);
    let amber_forward = -0.77 * amber_x - 0.64 * amber_z;
    let fungal_forward = -0.77 * fungal_x - 0.64 * fungal_z;
    let amber_side = 0.64 * amber_x - 0.77 * amber_z;
    let fungal_side = 0.64 * fungal_x - 0.77 * fungal_z;
    assert(abs(amber_distance - 240.0) < 1.0);
    assert(abs(fungal_distance - 240.0) < 1.0);
    assert(abs(amber_forward / amber_distance - 0.94) < 0.01);
    assert(abs(fungal_forward / fungal_distance - 0.94) < 0.01);
    assert(amber_side > 75.0 && amber_side < 90.0);
    assert(fungal_side < -75.0 && fungal_side > -90.0);
    // These are climate anchors inside the district corners. Its preserved
    // flat mask wins over the height field; surrounding patches carry relief.
    assert(world::natural_weight(amber_x, amber_z) == 0.0);
    assert(world::natural_weight(fungal_x, fungal_z) == 0.0);
    assert(world::base_height(amber_x, amber_z) == 1.8);
    assert(world::base_height(fungal_x, fungal_z) == 1.8);
    var arid_relief: i64 = 0;
    var fungal_relief: i64 = 0;
    var arid_low: f32 = 10000.0;
    var arid_high: f32 = -10000.0;
    var fungal_low: f32 = 10000.0;
    var fungal_high: f32 = -10000.0;
    for vi in 5 {
        for ui in 4 {
            let v: f32 = 260.0 + vi * 20.0;
            let u: f32 = 90.0 + ui * 10.0;
            let ax = u * 0.64 - v * 0.77;
            let az = -u * 0.77 - v * 0.64;
            let ux = -u * 0.64 - v * 0.77;
            let uz = u * 0.77 - v * 0.64;
            let ah = world::base_height(ax, az);
            let uh = world::base_height(ux, uz);
            if world::biome(ax, az) == 1 && abs(ah - 1.8) > 0.5 {
                arid_relief++;
                arid_low = min(arid_low, ah);
                arid_high = max(arid_high, ah);
            }
            if world::biome(ux, uz) == 2 && abs(uh - 1.8) > 0.5 {
                fungal_relief++;
                fungal_low = min(fungal_low, uh);
                fungal_high = max(fungal_high, uh);
            }
        }
    }
    print(
        "framing relief: arid_samples=", arid_relief,
        " range=", arid_low, "..", arid_high,
        " fungal_samples=", fungal_relief,
        " range=", fungal_low, "..", fungal_high
    );
    assert(arid_relief > 0 && fungal_relief > 0);
    assert(world::ridge_amplitude(0.0, 0.0) == 10.0);
    assert(world::ridge_amplitude(120.0, 0.0) == 10.0);
    assert(world::ridge_amplitude(150.0, 0.0) == 28.0);
    assert(world::ridge_amplitude(180.0, 0.0) == 46.0);
    assert(world::ridge_amplitude(1000.0, 1000.0) == 46.0);
    for zi in -15..16 {
        for xi in -15..16 {
            let x: f32 = xi * 8.0;
            let z: f32 = zi * 8.0;
            if x * x + z * z <= 120.0 * 120.0 {
                let ridge = world::ridge_height(x, z, world::seed);
                assert(ridge >= 0.0 && ridge <= 10.0);
            }
        }
    }
    // The nominal low play camera must see the representative 20 m fungal
    // canopy without a foreground terrain ridge crossing that sightline.
    let eye = float3 { 9.0, 6.0, 14.5 };
    let canopy_y = world::height(fungal_x, fungal_z) + 20.0;
    var clearance: f32 = 10000.0;
    for i in 1..201 {
        let t: f32 = i / 200.0;
        let x = eye.x + (fungal_x - eye.x) * t;
        let z = eye.z + (fungal_z - eye.z) * t;
        let y = eye.y + (canopy_y - eye.y) * t;
        clearance = min(clearance, y - world::height(x, z));
    }
    print("fungal canopy terrain sightline: minimum clearance=", clearance);
    assert(clearance > 0.0);
    assert(abs(world::forced_spire(-370.0, -307.0) - 70.0) < 0.0001);
    assert(world::forced_spire(-401.0, -307.0) == 0.0);
    let up = float3 { 0.0, 1.0, 0.0 };
    let amber_color = world::color(amber_x, amber_z, 1.8, up);
    let fungal_color = world::color(fungal_x, fungal_z, 1.8, up);
    print("framing colors: amber=", amber_color, " fungal=", fungal_color);
    assert(amber_color.x > amber_color.z + 0.1);
    assert(fungal_color.z > fungal_color.x + 0.1);
    let near_color = world::color(-123.0, -102.0, 1.8, up);
    let far_color = world::far_color(-123.0, -102.0, 1.8, up);
    assert(near_color == far_color);
    var low: f32 = 10000.0;
    var high: f32 = -10000.0;
    var meadow_samples: i64 = 0;
    var open_samples: i64 = 0;
    for zi in -64..65 {
        for xi in -64..65 {
            let x: f32 = xi * 16.0;
            let z: f32 = zi * 16.0;
            let height = world::base_height(x, z);
            low = min(low, height);
            high = max(high, height);
            assert(height == height && abs(height) < 200.0);
            if world::biome(x, z) == 0 {
                meadow_samples++;
                if world::grove_mask(x, z) < 0.42 {
                    open_samples++;
                }
            }
        }
    }
    assert(high > 65.0 && low < -10.0 && high - low > 80.0);
    print(
        "terrain properties: PASS; min_height=", low,
        " max_height=", high,
        " meadow_open_mask_percent=", open_samples * 100.0 / meadow_samples
    );
}

fn chunk_seams() {
    for i in world::chunks.len {
        let current .= world::chunks[i];
        if !current.active || !current.ready {
            continue;
        }
        let right = world::find(current.cx + 1, current.cz);
        let back = world::find(current.cx, current.cz + 1);
        for vertex in world::GRID {
            if right >= 0 && world::chunks[right].ready {
                assert(current.heights[vertex * 17 + 16] == world::chunks[right].heights[vertex * 17]);
            }
            if back >= 0 && world::chunks[back].ready {
                assert(current.heights[16 * 17 + vertex] == world::chunks[back].heights[vertex]);
            }
        }
    }
}

fn main() {
    let start = clock();
    world::init(73129);
    terrain_properties();
    settle(0.0, 0.0, 2);
    assert(world::loaded == 25);
    assert(world::pending == 0);
    assert(world::chunks.len == 25);
    chunk_seams();
    assert(world::height(0.0, 0.0) == world::base_height(0.0, 0.0));
    let origin = world::find(0, 0);
    for z in 17 {
        for x in 17 {
            let expected = world::generated_height(x * 2.0, z * 2.0, 73129);
            assert(world::chunks[origin].heights[z * 17 + x] == expected);
        }
    }
    let before = world::height(-2.0, -2.0);
    world::edit(-2.0, -2.0, -1.25);
    assert(abs(world::height(-2.0, -2.0) - (before - 1.25)) < 0.0001);
    let s = world::find(-1, -1);
    assert(s >= 0 && world::chunks[s].ready);
    var verts = world::mesh(s);
    assert(verts.len == 1920);
    assert(verts[0].normal.y > 0.0);
    // An edit on a shared vertex must update every chunk meeting there.
    world::edit(0.0, 0.0, -0.5);
    let left = world::find(-1, 0);
    let right = world::find(0, 0);
    assert(world::chunks[left].heights[16] == world::chunks[right].heights[0]);
    chunk_seams();
    let edited = world::height(-2.0, -2.0);
    var checksum: f64 = 0.0;
    for lap in 100 {
        let x: f32 = ((lap * 17) % 31 - 15) * 96.0;
        let z: f32 = ((lap * 13) % 29 - 14) * 96.0;
        settle(x, z, 2);
        assert(world::loaded == 25);
        assert(world::chunks.len == 25);
        assert(world::max_pending <= 8);
        checksum += world::height(x + 1.0, z + 1.0);
    }
    settle(0.0, 0.0, 2);
    assert(abs(world::height(-2.0, -2.0) - edited) < 0.0001);
    let slot = world::find(-1, -1);
    assert(abs(world::chunks[slot].heights[15 * 17 + 15] - edited) < 0.0001);
    // Repeatedly abandon outstanding jobs before their results are collected.
    for lap in 50 {
        world::stream(lap * 128.0, -lap * 96.0, 2, 8);
    }
    world::drain();
    settle(0.0, 0.0, 4);
    assert(world::loaded == 81);
    assert(world::chunks.len == 81);
    settle(-1000.0, -1000.0, 4);
    assert(world::chunks.len == 81);
    // The expanded near field remains bounded at the new maximum radius.
    settle(0.0, 0.0, 8);
    assert(world::loaded == 289);
    assert(world::chunks.len == world::MAX_CHUNKS);
    for lap in 12 {
        settle(lap * 768.0 - 4096.0, -lap * 512.0, 8);
        assert(world::loaded == 289);
        assert(world::chunks.len == 289);
        assert(world::pending == 0);
    }
    // Abandon results repeatedly at the expanded radius before revisiting.
    for lap in 40 {
        world::stream(-lap * 1024.0, lap * 768.0, 8, 8);
    }
    settle(-2.0, -2.0, 8);
    assert(world::loaded == 289);
    assert(world::chunks.len == 289);
    assert(world::max_pending <= world::MAX_JOBS);
    assert(abs(world::height(-2.0, -2.0) - edited) < 0.0001);
    chunk_seams();
    world::shutdown();
    assert(world::loaded == 0 && world::pending == 0);
    world::init(73129);
    settle(-2.0, -2.0, 2);
    assert(world::chunks.len == 289);
    assert(abs(world::height(-2.0, -2.0) - edited) < 0.0001);
    world::shutdown();
    print(
        "world: PASS; chunks generated=", world::generated,
        " evicted=", world::evicted, " slots_high_water=", world::chunks.len,
        " edits=", world::edits.len, " max_pending=", world::max_pending,
        " generation_ms_total=", world::generation_total_ms,
        " queue_call_ms=", world::transfer_ms, " blocking_drain_ms=", world::wait_ms,
        " elapsed_ms=", (clock() - start) * 1000.0, " checksum=", checksum
    );
}
