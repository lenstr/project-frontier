// Real Nuklear input regression: tabs, sliders, action pulses, pinning and
// bounded live history. The scene and counters are the real game modules.
import std;
import vec;
import math;
import os;
import gfx;
import ui;
import dev_panel from "../src";

var frames: i64 = 0;
var inspected: ecs::Handle;
var last_frame: f64 = 0.0;

fn frame() {
    assert(gfx::frame());
    let started = clock();
    dev::begin_frame();
    dev::draw(inspected);
    scene::draw(float3 { 16.0, 13.0, 22.0 }, float3 { 0.0, 3.0, 0.0 },
        sim::day, frames / 60.0, inspected, 0, float3_0, true, true);
    dev::present();
    // The harness has no game HUD. Apply its shared renderer retirement
    // workaround only after every context has rendered.
    if ui::renderer.index_buffer.id != 0 {
        gfx::release(ui::renderer.index_buffer);
        ui::renderer.index_buffer = gfx::Buffer { 0 };
        ui::renderer.index_capacity = 0;
    }
    gfx::flush();
    let elapsed = (clock() - started) * 1000.0;
    stats::record(stats::Frame {
        frame_ms: if last_frame > 0.0 { (clock() - last_frame) * 1000.0 } else { elapsed },
        ui_ms: elapsed,
        ..
    });
    last_frame = clock();
    frames++;
}

fn center(bounds: ui::Rect) -> float2 {
    float2 {
        (bounds.x + bounds.w * 0.5) * dev::scale,
        (bounds.y + bounds.h * 0.5) * dev::scale,
    }
}

fn click(bounds: ui::Rect) -> dev::Actions {
    let p = center(bounds);
    gfx::inject_mouse(p.x, p.y, gfx::MOUSE_LEFT, true);
    frame();
    let down = dev::actions;
    gfx::inject_mouse(p.x, p.y, gfx::MOUSE_LEFT, false);
    frame();
    var result = dev::actions;
    result.spawn_objects = max(result.spawn_objects, down.spawn_objects);
    result.destroy_objects = max(result.destroy_objects, down.destroy_objects);
    result.toggle_flight = result.toggle_flight || down.toggle_flight;
    result.reframe_flight = result.reframe_flight || down.reframe_flight;
    return result;
}

fn drag_slider(bounds: ui::Rect, start_fraction: f32, fraction: f32) {
    let initial = float2 {
        (bounds.x + bounds.w * start_fraction) * dev::scale,
        (bounds.y + bounds.h * 0.5) * dev::scale,
    };
    let destination = float2 {
        (bounds.x + bounds.w * fraction) * dev::scale,
        initial.y,
    };
    gfx::inject_mouse(initial.x, initial.y, gfx::MOUSE_LEFT, true);
    frame();
    gfx::inject_mouse(destination.x, destination.y, 0, false);
    frame();
    gfx::inject_mouse(destination.x, destination.y, gfx::MOUSE_LEFT, false);
    frame();
}

fn test_overview_commands() {
    stats::reset_history();
    for i in 240 {
        stats::record(stats::Frame {
            frame_ms: 6.0, simulation_ms: 1.0, stream_ms: 0.5,
            mesh_ms: 0.5, render_ms: 2.0, ui_ms: 1.0, ..
        });
    }
    stats::refresh();
    assert(dev::chart_maximum() == 12.0);
    frame();
    var fills: i64[5] = [0; 5];
    var total_line = false;
    let commands = ui::commands(dev::context);
    for command in commands {
        let inside = command.x >= dev::chart_bounds.x
            && command.x < dev::chart_bounds.x + dev::chart_bounds.w
            && command.y >= dev::chart_bounds.y + 20.0
            && command.y < dev::chart_bounds.y + dev::chart_bounds.h;
        if command.kind == ui::COMMAND_RECT_FILLED && inside {
            for series in 5 {
                if command.color == dev::series_color(series) {
                    fills[series]++;
                }
            }
        }
        if command.kind == ui::COMMAND_POLYLINE && command.color == dev::IVORY {
            total_line = true;
        }
    }
    for series in 5 {
        assert(fills[series] >= 200);
    }
    assert(total_line && dev::chart_axis_max == 12.0);
    assert(dev::clock_text(15.133333) == "15:08");
    assert(dev::slider_text(140.0, 10.0, " m") == "140 m");
    assert(dev::slider_text(1.0, 0.25, "×") == "1.00×");
    assert(gfx::screenshot("build/v2-panel-overview-colors.png"));
}

fn test_map_commands() {
    var pending: i64 = -1;
    for i in world::chunks.len {
        if world::chunks[i].active {
            pending = i;
            break;
        }
    }
    assert(pending >= 0);
    world::chunks[pending].ready = false;
    frame();
    assert(dev::map_legend_bounds.x >= dev::map_data_bounds.x + 200.0);
    var pending_outline = false;
    var player_arrow = false;
    let commands = ui::commands(dev::context);
    for command in commands {
        let inside = command.x >= dev::map_data_bounds.x
            && command.x < dev::map_data_bounds.x + 200.0
            && command.y >= dev::map_data_bounds.y
            && command.y < dev::map_data_bounds.y + 200.0;
        if command.kind == ui::COMMAND_RECT && inside && command.color == dev::LAVENDER {
            pending_outline = true;
        }
        if command.kind == ui::COMMAND_RECT_FILLED && inside {
            assert(command.color != dev::ORANGE && command.color != dev::LAVENDER);
        }
        let arrow_x = command.points[0].x;
        let arrow_y = command.points[0].y;
        let arrow_inside = arrow_x >= dev::map_data_bounds.x
            && arrow_x < dev::map_data_bounds.x + 200.0
            && arrow_y >= dev::map_data_bounds.y
            && arrow_y < dev::map_data_bounds.y + 200.0;
        if command.kind == ui::COMMAND_TRIANGLE_FILLED && command.color == dev::ORANGE && arrow_inside {
            player_arrow = true;
        }
    }
    assert(pending_outline && player_arrow);
    assert(gfx::screenshot("build/v2-panel-world-legend.png"));
    world::chunks[pending].ready = true;
}

fn main() {
    assert(gfx::open_headless(1280, 800, gfx::NO_VSYNC));
    sim::init(73129);
    scene::init();
    for batch in 4 {
        world::stream(0.0, 0.0, 2, 8);
        world::drain();
    }
    scene::sync(81);
    inspected = ecs::spawn(sim::SMELTER, sim::ground(4.0, 5.0));
    ecs::add(inspected, sim::ORE, 15);
    ecs::enqueue(inspected, sim::METAL, 1);
    ecs::link(inspected, sim::base);
    stats::refresh();
    dev::init();
    dev::open = true;
    frame();
    assert(dev::tab == 0);
    test_overview_commands();
    click(dev::tab_bounds[1]);
    assert(dev::tab == 1);
    test_map_commands();
    click(dev::tab_bounds[2]);
    assert(dev::tab == 2);
    click(dev::tab_bounds[3]);
    assert(dev::tab == 3);
    assert(dev::settings.flight_speed == 48.0);
    let flight_action = click(dev::flight_bounds);
    assert(flight_action.toggle_flight);
    frame();
    assert(!dev::actions.toggle_flight);
    let overview_action = click(dev::reframe_bounds);
    assert(overview_action.reframe_flight);
    frame();
    assert(!dev::actions.reframe_flight);
    drag_slider(dev::flight_speed_bounds, (48.0 - 10.0) / 290.0, 0.7);
    assert(dev::settings.flight_speed > 48.0 && dev::settings.flight_speed <= 300.0);
    let commands = ui::commands(dev::context);
    let text = ui::command_text(dev::context);
    var reset_label = false;
    for command in commands {
        if command.kind == ui::COMMAND_TEXT && command.count == 1 && command.w >= 6 {
            if text[command.first..command.first + command.count] == "R" {
                reset_label = true;
            }
        }
    }
    assert(reset_label);
    let old_speed = dev::settings.simulation_speed;
    drag_slider(dev::speed_bounds, old_speed / 4.0, 0.7);
    assert(dev::settings.simulation_speed > old_speed);
    let old_day = dev::settings.day_phase;
    let displayed_hour: f32 = (old_day * 24.0 + 6.0) % 24.0;
    drag_slider(dev::day_bounds, displayed_hour / 23.75, 0.8);
    assert(dev::settings.day_phase != old_day && dev::settings.lock_time);
    drag_slider(dev::radius_bounds, (dev::settings.detail_radius - 2) / 6.0, 0.95);
    assert(dev::settings.detail_radius >= 7);
    // Scroll the actual Nuklear group so the lower action buttons are visible.
    dev::requested_scroll = 500;
    frame();
    frame();
    assert(dev::spawn_bounds.y > dev::panel_bounds.y + 50.0);
    assert(dev::spawn_bounds.y < dev::panel_bounds.y + dev::panel_bounds.h - 45.0);
    let spawned = click(dev::spawn_bounds);
    assert(spawned.spawn_objects == 1000);
    let destroyed = click(dev::destroy_bounds);
    assert(destroyed.destroy_objects == 1000);
    frame();
    assert(dev::actions.spawn_objects == 0 && dev::actions.destroy_objects == 0);
    click(dev::tab_bounds[4]);
    assert(dev::tab == 4);
    click(dev::pin_bounds);
    assert(ecs::same(dev::pinned, inspected));
    ecs::destroy(inspected);
    let replacement = ecs::spawn(sim::STORAGE, sim::ground(4.0, 5.0));
    assert(replacement.slot == inspected.slot);
    assert(!ecs::valid(dev::pinned));
    frame();
    assert(!ecs::valid(dev::pinned));
    click(dev::tab_bounds[0]);
    assert(dev::tab == 0);
    for i in 250 {
        frame();
    }
    assert(stats::count == 240);
    assert(stats::total_frames > 240);
    assert(stats::counters.entity_slots == ecs::entities.len);
    assert(gfx::screenshot("build/dev-panel.png"));
    print("DEV_PANEL_TEST PASS frames=", frames,
        " tabs=5 slider_speed=", dev::settings.simulation_speed,
        " day=", dev::settings.day_phase, " radius=", dev::settings.detail_radius,
        " history=", stats::count, " action_pulses=1000/1000 pinned_stale=true");
    dev::shutdown();
    scene::shutdown();
    sim::shutdown();
    sim::reset();
    gfx::close();
}
