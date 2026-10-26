// Interactive engine controls and measured telemetry. Game mutations are
// requested through Actions; the application applies them after drawing UI.
namespace dev;

import std;
import vec;
import math;
import os;
import gfx;
import ui;
import .entities;
import .sim;
import .world;
import .render;
import .scene;
import .telemetry;
import .horizon;
import .memory;

let ROBOTO: const u8[:] = embed_file("../assets/Roboto-Regular.ttf");
let INK = ui::Color { 27, 35, 64, 248 };
let NAVY = ui::Color { 43, 58, 102, 255 };
let BORDER = ui::Color { 58, 70, 112, 255 };
let IVORY = ui::Color { 242, 234, 216, 255 };
let MUTED = ui::Color { 169, 176, 200, 255 };
let ORANGE = ui::Color { 255, 122, 47, 255 };
let CYAN = ui::Color { 95, 242, 224, 255 };
let RED = ui::Color { 255, 77, 94, 255 };
let LAVENDER = ui::Color { 183, 164, 230, 255 };
let BONE = ui::Color { 211, 200, 176, 255 };
let SLATE = ui::Color { 74, 85, 120, 255 };
let MEADOW_MAP = ui::Color { 35, 89, 78, 255 };
let MESA_MAP = ui::Color { 107, 78, 40, 255 };
let FUNGAL_MAP = ui::Color { 87, 73, 114, 255 };
let TABS: const u8[:][5] = ["Overview", "World", "Goose", "Controls", "Inspect"];

struct Settings {
    simulation_speed: f32 = 1.0,
    day_phase: f32 = 0.375,
    lock_time: bool = false,
    detail_radius: i64 = 6,
    mesh_budget: i64 = 4,
    fog_start: f32 = 140.0,
    fog_distance: f32 = 1600.0,
    shadows: bool = true,
    vegetation: f32 = 1.0,
    camera_speed: f32 = 1.0,
    flight_speed: f32 = 48.0,
    show_wireframe: bool = false,
    load: i64 = 512,
    robot_budget: i64 = 2,
}

struct Actions {
    spawn_objects: i64,
    destroy_objects: i64,
    spawn_robots: i64,
    build_showcase: bool,
    single_step: bool,
    save: bool,
    load: bool,
    rapid_stream: bool,
    reset_stats: bool,
    churn_rounds: i64,
    toggle_flight: bool,
    reframe_flight: bool,
    trim_memory: bool,
}

var open: bool = false;
// 0 closed, 1 full, 2 compact. toggle() is the F1 integration entry point.
var mode: i64 = 0;
var pick_armed: bool = false;
var panel_ms: f64 = 0.0;
var context: ui::Context;
var selected: ecs::Handle;
var pinned: ecs::Handle;
var settings: Settings;
var actions: Actions;
var tab: i64 = 0;
var scale: f32 = 1.0;
var resume_speed: f32 = 1.0;
var was_open: bool = false;
var resized: bool = false;
var screen_previous: int2;
var kind_counts: i64[96];
var kind_sample_frame: i64 = -1;
var flight_active: bool = false;
var flight_altitude: f32 = 0.0;

struct ChurnResult {
    completed: bool,
    elapsed_ms: f64,
    slots_before: i64,
    slots_after: i64,
    cells_before: i64,
    cells_after: i64,
}

var last_churn: ChurnResult;

// Actual widget bounds are exposed for deterministic input tests. They are
// measured from Nuklear layout, never a second implementation of hit testing.
var tab_bounds: ui::Rect[5];
var spawn_bounds: ui::Rect;
var destroy_bounds: ui::Rect;
var trim_bounds: ui::Rect;
var speed_bounds: ui::Rect;
var day_bounds: ui::Rect;
var radius_bounds: ui::Rect;
var pin_bounds: ui::Rect;
var panel_bounds: ui::Rect;
var flight_bounds: ui::Rect;
var reframe_bounds: ui::Rect;
var flight_speed_bounds: ui::Rect;
var chart_bounds: ui::Rect;
var chart_axis_max: f32 = 0.0;
var map_data_bounds: ui::Rect;
var map_legend_bounds: ui::Rect;
// Programmatic scrolling is applied inside the next window build, where the
// official UI API permits it. Tests and inspector navigation use the same path.
var requested_scroll: i64 = -1;

fn toggle() {
    mode = (mode + 1) % 3;
    open = mode != 0;
}

fn decimal(value: f64, places: i64) -> u8[>..] {
    var out: u8[>..] = [];
    format_flt(out, value, places);
    out
}

fn count_text(value: i64) -> u8[>..] {
    let digits = str(value);
    var out: u8[>..] = [];
    for i in digits.len {
        if i > 0 && digits[i - 1] != '-' && (digits.len - i) % 3 == 0 {
            out.push(' ');
        }
        out.push(digits[i]);
    }
    out
}

fn time_text(value: f64) -> u8[>..] {
    if value < 1.0 {
        return str(decimal(value * 1000.0, 0), " µs");
    }
    str(decimal(value, if value < 10.0 { 2 } else { 1 }), " ms")
}

fn clock_text(hours: f32) -> u8[>..] {
    let minutes = ((hours * 60.0 + 0.5) as! i64) % 1440;
    var out: u8[>..] = [];
    format_int(out, minutes / 60, 10, 2, '0');
    out.push(':');
    format_int(out, minutes % 60, 10, 2, '0');
    out
}

fn slider_text(value: f32, step: f32, unit: const u8[:]) -> u8[>..] {
    if unit == "HH:MM" {
        return clock_text(value);
    }
    let places: i64 = if step < 0.1 || step == 0.25 { 2 } else if step < 1.0 { 1 } else { 0 };
    str(decimal(value, places), unit)
}

fn handle_text(handle: ecs::Handle) -> u8[>..] {
    if handle.slot < 0 {
        return str("No handle");
    }
    var out: u8[>..] = [];
    out.push('#');
    format_int(out, handle.slot, 10, 4, '0');
    format(out, " g", handle.generation);
    out
}

struct PoolSample {
    live: i64,
    slots: i64,
    jobs: i64,
    generation_ms: f64,
}
var pool_history: PoolSample[240];
var pool_cursor: i64 = 0;
var pool_count: i64 = 0;
var pool_sample_time: f64 = 0.0;

fn pool_sample(index: i64) -> PoolSample {
    let oldest: i64 = if pool_count == 240 { pool_cursor } else { 0 };
    pool_history[(oldest + index) % 240]
}

fn pool_history_tick() {
    let now = clock();
    if now - pool_sample_time < 0.25 && pool_count > 0 {
        return;
    }
    pool_history[pool_cursor] = PoolSample {
        ecs::alive_count,
        ecs::entities.len,
        world::pending,
        world::generation_ms,
    };
    pool_cursor = (pool_cursor + 1) % 240;
    pool_count = min(pool_count + 1, 240);
    pool_sample_time = now;
}

fn init() {
    context = ui::create_from_memory(ROBOTO, 15.0);
    assert(context.id != 0);
    var style = ui::style(context);
    style.text.color = IVORY;
    style.window.fixed_background = ui::style_item_color(INK);
    style.window.background = INK;
    style.window.border_color = BORDER;
    style.window.group_border_color = BORDER;
    style.window.padding = float2 { 14.0, 12.0 };
    style.window.group_padding = float2 { 1.0, 6.0 };
    style.window.spacing = float2 { 8.0, 6.0 };
    style.window.rounding = 8.0;
    style.window.border = 1.0;
    style.window.header.normal = ui::style_item_color(NAVY);
    style.window.header.hover = ui::style_item_color(NAVY);
    style.window.header.active = ui::style_item_color(NAVY);
    style.window.header.label_normal = IVORY;
    style.window.header.label_hover = IVORY;
    style.window.header.label_active = IVORY;
    style.button.normal = ui::style_item_color(NAVY);
    style.button.hover = ui::style_item_color(ui::Color { 66, 81, 130, 255 });
    style.button.active = ui::style_item_color(ORANGE);
    style.button.text_normal = IVORY;
    style.button.text_hover = IVORY;
    style.button.text_active = INK;
    style.button.border_color = BORDER;
    style.button.border = 1.0;
    style.button.rounding = 4.0;
    style.button.padding = float2 { 6.0, 5.0 };
    style.checkbox.text_normal = IVORY;
    style.checkbox.text_hover = IVORY;
    style.checkbox.text_active = IVORY;
    style.checkbox.cursor_normal = ui::style_item_color(CYAN);
    style.checkbox.cursor_hover = ui::style_item_color(ORANGE);
    style.slider.bar_normal = BORDER;
    style.slider.bar_hover = BORDER;
    style.slider.bar_active = BORDER;
    style.slider.bar_filled = CYAN;
    style.slider.cursor_normal = ui::style_item_color(CYAN);
    style.slider.cursor_hover = ui::style_item_color(ORANGE);
    style.slider.cursor_active = ui::style_item_color(ORANGE);
    style.slider.bar_height = 5.0;
    style.slider.cursor_size = float2 { 14.0, 18.0 };
    style.chart.background = ui::style_item_color(ui::Color { 20, 28, 51, 255 });
    style.chart.border_color = BORDER;
    style.chart.border = 1.0;
    style.chart.rounding = 4.0;
    style.chart.color = CYAN;
    style.chart.selected_color = ORANGE;
    style.chart.show_markers = false;
    style.scrollv.normal = ui::style_item_color(INK);
    style.scrollv.cursor_normal = ui::style_item_color(BORDER);
    style.scrollv.cursor_hover = ui::style_item_color(MUTED);
    style.scrollv.cursor_active = ui::style_item_color(ORANGE);
    ui::set_style(context, style);
}

fn begin_frame() {
    // Rapid streaming is a persistent toggle; all other actions are pulses.
    pool_history_tick();
    let rapid = actions.rapid_stream;
    actions = Actions { rapid_stream: rapid, .. };
    let size = gfx::screen_size();
    resized = size.x != screen_previous.x || size.y != screen_previous.y;
    screen_previous = size;
    scale = clamp(min(size.x / 1280.0, size.y / 800.0), 0.7, 2.0);
    ui::set_scale(context, scale);
    ui::input_from_gfx(context);
    if open && !was_open {
        ui::window_show(context, "Developer Console", ui::SHOWN);
    }
}

fn wants_mouse() -> bool {
    open && ui::wants_mouse(context)
}

fn wants_keyboard() -> bool {
    open && ui::wants_keyboard(context)
}

fn heading(title: const u8[:]) {
    ui::layout_row_dynamic(context, 25.0, 1);
    ui::label_colored(context, title, ui::TEXT_LEFT, ORANGE);
}

fn caption(text: const u8[:]) {
    ui::layout_row_dynamic(context, 20.0, 1);
    ui::label_colored(context, text, ui::TEXT_LEFT, MUTED);
}

fn wrapped(text: const u8[:], height: f32) {
    ui::layout_row_dynamic(context, height, 1);
    ui::label_colored_wrap(context, text, MUTED);
}

fn metric(name: const u8[:], value: const u8[:], color: ui::Color) {
    ui::layout_row_begin(context, ui::DYNAMIC, 22.0, 2);
    ui::layout_row_push(context, 0.65);
    ui::label_colored(context, name, ui::TEXT_LEFT, MUTED);
    ui::layout_row_push(context, 0.35);
    ui::label_colored(context, value, ui::TEXT_RIGHT, color);
    ui::layout_row_end(context);
}

fn milliseconds(name: const u8[:], value: f64) {
    metric(name, time_text(value), IVORY);
}

fn canvas_text(x: f32, y: f32, width: f32, text: const u8[:], color: ui::Color) {
    ui::draw_text(context, ui::rect(x, y, width, 19.0), text, ui::font(context),
        ui::Color { 0, 0, 0, 0 }, color);
}

fn series_color(series: i64) -> ui::Color {
    if series == 0 {
        return ORANGE;
    }
    if series == 1 {
        return LAVENDER;
    }
    if series == 2 {
        return CYAN;
    }
    if series == 3 {
        return BONE;
    }
    SLATE
}

fn frame_series(frame: stats::Frame) -> f64[5] {
    let simulation = max(0.0, frame.simulation_ms);
    let world = max(0.0, frame.stream_ms + frame.mesh_ms);
    let render = max(0.0, frame.render_ms);
    let ui = max(0.0, frame.ui_ms);
    let other = max(0.0, frame.frame_ms - simulation - world - render - ui);
    [simulation, world, render, ui, other]
}

fn chart_maximum() -> f32 {
    let budget: f64 = 16.667;
    let maximum = if stats::p99_ms < budget {
        max(stats::p99_ms * 2.0, 8.0)
    } else {
        max(stats::p99_ms * 1.25, budget * 1.5)
    };
    maximum as f32
}

fn frame_legend() {
    ui::layout_row_dynamic(context, 40.0, 1);
    let state, bounds = ui::widget(context);
    if state == ui::WIDGET_INVALID {
        return;
    }
    let names = ["Simulation", "World", "Render CPU", "UI", "Other / wait"];
    for series in 5 {
        let column = series % 3;
        let row = series / 3;
        let x = bounds.x + column * bounds.w / 3.0;
        let y = bounds.y + row * 20.0;
        ui::fill_rect(context, ui::rect(x, y + 5.0, 8.0, 8.0), 0.0, series_color(series));
        canvas_text(x + 13.0, y, bounds.w / 3.0 - 13.0, names[series], MUTED);
    }
}

fn frame_chart(height: f32) {
    ui::layout_row_dynamic(context, height, 1);
    let visible, bounds = ui::widget(context);
    if visible == ui::WIDGET_INVALID {
        return;
    }
    chart_bounds = bounds;
    ui::fill_rect(context, bounds, 4.0, ui::Color { 20, 27, 51, 255 });
    if stats::count < 2 {
        canvas_text(bounds.x + 8.0, bounds.y + 16.0, bounds.w - 16.0, "Collecting measured frames...", MUTED);
        return;
    }
    let maximum = chart_maximum();
    chart_axis_max = maximum;
    let top = bounds.y + 20.0;
    let chart_h = bounds.h - 24.0;
    let dx = bounds.w / stats::count;
    canvas_text(bounds.x + 5.0, bounds.y + 1.0, 130.0, str(decimal(maximum, 0), " ms"), MUTED);
    if maximum < 16.667 {
        canvas_text(bounds.x + bounds.w - 170.0, bounds.y + 1.0, 170.0,
            "budget 16.67 ms above", ORANGE);
    }
    for line in 1..4 {
        let y = top + chart_h * line / 4.0;
        ui::stroke_line(context, bounds.x, y, bounds.x + bounds.w, y, 1.0, NAVY);
    }
    var points: float2[240];
    for i in stats::count {
        let f = stats::sample(i);
        let values = frame_series(f);
        var accumulated: f32 = 0.0;
        for series in 5 {
            let amount: f32 = values[series] as f32;
            let h = min(amount / maximum * chart_h, max(0.0, chart_h - accumulated));
            if h > 0.0 {
                ui::fill_rect(context, ui::rect(bounds.x + i * dx, top + chart_h - accumulated - h,
                    max(dx, 1.0), h), 0.0, series_color(series));
            }
            accumulated += h;
        }
        points[i] = float2 { bounds.x + (i + 0.5) * dx,
            top + chart_h - clamp(f.frame_ms as f32 / maximum, 0.0, 1.0) * chart_h };
        if f.frame_ms > 16.667 {
            ui::stroke_line(context, points[i].x, top, points[i].x, top + 3.0, 1.0, RED);
        }
    }
    ui::stroke_polyline(context, points[..stats::count], 1.5, IVORY);
    if maximum >= 16.667 {
        let budget_y = top + chart_h * (1.0 - 16.667 / maximum);
        for dash in ceil(bounds.w / 10.0) as i64 {
            let x = bounds.x + dash * 10.0;
            ui::stroke_line(context, x, budget_y, min(x + 5.0, bounds.x + bounds.w), budget_y,
                1.0, ui::Color { 255, 122, 47, 155 });
        }
    }
}

fn compact_header() {
    ui::layout_row_dynamic(context, 44.0, 1);
    let state, bounds = ui::widget(context);
    if state == ui::WIDGET_INVALID {
        return;
    }
    canvas_text(bounds.x, bounds.y, 180.0, "DEVELOPER / F1", ORANGE);
    let fps = if stats::count > 0 && stats::mean_ms > 0.0 {
        str(decimal(1000.0 / stats::mean_ms, 1), " FPS")
    } else {
        str("Measuring...")
    };
    canvas_text(bounds.x + bounds.w - 120.0, bounds.y, 120.0, fps, IVORY);
    canvas_text(bounds.x, bounds.y + 23.0, bounds.w,
        str("p50 ", decimal(stats::p50_ms, 1), " / p95 ", decimal(stats::p95_ms, 1),
            " / p99 ", decimal(stats::p99_ms, 1), " ms"), MUTED);
}

fn header() {
    ui::layout_row_dynamic(context, 26.0, 2);
    ui::label_colored(context, "DEVELOPER", ui::TEXT_LEFT, ORANGE);
    let fps = if stats::count > 0 && stats::mean_ms > 0.0 {
        str(decimal(1000.0 / stats::mean_ms, 1), " FPS")
    } else {
        str("Measuring...")
    };
    ui::label_colored(context, fps, ui::TEXT_RIGHT, IVORY);
    let screen = gfx::screen_size();
    caption(str("Goose a108677d300c / release / ", screen.x, " x ", screen.y, " / panel ", time_text(panel_ms)));
    ui::layout_row_dynamic(context, 21.0, 3);
    let values: f64[3] = [stats::p50_ms, stats::p95_ms, stats::p99_ms];
    let names: const u8[:][3] = ["p50 ", "p95 ", "p99 "];
    for i in 3 {
        let color = if values[i] <= 16.667 { CYAN } else { if values[i] <= 25.0 { ORANGE } else { RED } };
        ui::label_colored(context, str(names[i], decimal(values[i], 1), " ms"), ui::TEXT_LEFT, color);
    }
}

fn stage_name(stage: i64) -> const u8[:] {
    let names = ["Input / camera", "Simulation total", "  Power", "  Production",
        "  Transport", "  Robots / paths", "World streaming", "Mesh / upload CPU",
        "Render CPU", "UI / HUD", "GPU completion wait"];
    names[stage]
}

fn stage_table() {
    ui::layout_row_dynamic(context, 20.0, 1);
    let state, bounds = ui::widget(context);
    if state != ui::WIDGET_INVALID {
        canvas_text(bounds.x, bounds.y, 160.0, "CPU stage", MUTED);
        canvas_text(bounds.x + bounds.w - 202.0, bounds.y, 70.0, "Average", MUTED);
        canvas_text(bounds.x + bounds.w - 126.0, bounds.y, 70.0, "p95", MUTED);
        canvas_text(bounds.x + bounds.w - 48.0, bounds.y, 48.0, "Share", MUTED);
    }
    for rank in stats::STAGE_COUNT {
        let stage = stats::stage_order[rank];
        let value = stats::stage_summaries[stage];
        ui::layout_row_dynamic(context, 30.0, 1);
        let visible, row = ui::widget(context);
        if visible == ui::WIDGET_INVALID {
            continue;
        }
        canvas_text(row.x, row.y, 160.0, stage_name(stage), IVORY);
        canvas_text(row.x + row.w - 202.0, row.y, 70.0, time_text(value.average_ms), MUTED);
        canvas_text(row.x + row.w - 126.0, row.y, 70.0, time_text(value.p95_ms), MUTED);
        canvas_text(row.x + row.w - 48.0, row.y, 48.0,
            str(decimal(value.share_percent, 1), "%"), ORANGE);
        ui::fill_rect(context, ui::rect(row.x, row.y + 22.0, 160.0, 4.0), 1.0, NAVY);
        let fraction = clamp(value.share_percent / 100.0, 0.0, 1.0);
        let width = (fraction * 160.0) as f32;
        if width > 0.0 {
            ui::fill_rect(context, ui::rect(row.x, row.y + 22.0, width, 4.0), 1.0, ORANGE);
        }
    }
}

fn overview() {
    heading("WHERE THE FRAME GOES / 240 MEASURED FRAMES");
    frame_legend();
    frame_chart(125.0);
    caption(if chart_axis_max < 16.667 {
        "Ivory: total frame / 16.67 ms budget above chart"
    } else {
        "Ivory: total frame / Dashed orange: 16.67 ms budget"
    });
    heading("CPU STAGES / 240-FRAME AVERAGES, REFRESHED 4 Hz");
    stage_table();
    wrapped("Shares use total frame time. Indented stages are nested inside Simulation; rows do not sum to 100%. GPU wait is CPU blocking, not GPU utilization. Other includes input, waits and unattributed time.", 76.0);
    ui::layout_row_dynamic(context, 30.0, 1);
    if ui::button_label(context, "Reset recorded history") {
        actions.reset_stats = true;
    }
}

fn chunk_map() {
    ui::layout_row_dynamic(context, 210.0, 1);
    let state, bounds = ui::widget(context);
    if state == ui::WIDGET_INVALID {
        return;
    }
    let radius = settings.detail_radius;
    let across = radius * 2 + 1;
    let cell: f32 = 200.0 / across;
    let cx = floor(sim::player.x / 32.0) as i64;
    let cz = floor(sim::player.z / 32.0) as i64;
    map_data_bounds = ui::rect(bounds.x, bounds.y, 200.0, 200.0);
    map_legend_bounds = ui::rect(bounds.x + 212.0, bounds.y, max(100.0, bounds.w - 212.0), 200.0);
    ui::fill_rect(context, ui::rect(bounds.x, bounds.y, 200.0, 200.0), 3.0,
        ui::Color { 20, 27, 51, 255 });
    for z in across {
        for x in across {
            ui::stroke_rect(context, ui::rect(bounds.x + x * cell, bounds.y + z * cell,
                cell, cell), 0.0, 1.0, NAVY);
        }
    }
    for chunk in world::chunks {
        if !chunk.active || abs(chunk.cx - cx) > radius || abs(chunk.cz - cz) > radius {
            continue;
        }
        let x: f32 = bounds.x + (chunk.cx - cx + radius) * cell;
        let y: f32 = bounds.y + (chunk.cz - cz + radius) * cell;
        if chunk.ready {
            let biome = world::biome(chunk.cx * 32.0 + 16.0, chunk.cz * 32.0 + 16.0);
            var color = FUNGAL_MAP;
            if biome == 0 {
                color = MEADOW_MAP;
            } else if biome == 1 {
                color = MESA_MAP;
            }
            ui::fill_rect(context, ui::rect(x + 1.0, y + 1.0, cell - 2.0, cell - 2.0), 0.0, color);
        } else {
            ui::stroke_rect(context, ui::rect(x + 1.0, y + 1.0, cell - 2.0, cell - 2.0),
                0.0, 1.0, LAVENDER);
        }
    }
    let x = bounds.x + (radius + 0.5) * cell;
    let y = bounds.y + (radius + 0.5) * cell;
    ui::fill_triangle(context, x, y - 5.0, x - 4.0, y + 4.0, x + 4.0, y + 4.0, ORANGE);
    let text_x = bounds.x + 212.0;
    let text_w = max(100.0, bounds.w - 212.0);
    let biome = world::biome(sim::player.x, sim::player.z);
    canvas_text(text_x, bounds.y, text_w,
        if biome == 0 { "Teal meadow" } else { if biome == 1 { "Amber mesas" } else { "Fungal forest" } }, IVORY);
    canvas_text(text_x, bounds.y + 28.0, text_w, str(radius, " chunks / ", radius * 32, " m"), MUTED);
    canvas_text(text_x, bounds.y + 56.0, text_w, str(count_text(stats::counters.chunk_live), " resident"), CYAN);
    canvas_text(text_x, bounds.y + 84.0, text_w, str(count_text(stats::counters.terrain_jobs), " queued / generating"), MUTED);
    let biome_colors: ui::Color[3] = [MEADOW_MAP, MESA_MAP, FUNGAL_MAP];
    let biome_names = ["Meadow", "Mesas", "Fungal"];
    for i in 3 {
        let yy = bounds.y + 109.0 + i * 18.0;
        ui::fill_rect(context, ui::rect(text_x, yy + 4.0, 8.0, 8.0), 0.0, biome_colors[i]);
        canvas_text(text_x + 14.0, yy, text_w - 14.0, biome_names[i], MUTED);
    }
    ui::stroke_rect(context, ui::rect(text_x, bounds.y + 167.0, 8.0, 8.0), 0.0, 1.0, LAVENDER);
    canvas_text(text_x + 14.0, bounds.y + 163.0, text_w - 14.0, "Outline: pending", MUTED);
    ui::fill_triangle(context, text_x + 4.0, bounds.y + 186.0, text_x, bounds.y + 194.0,
        text_x + 8.0, bounds.y + 194.0, ORANGE);
    canvas_text(text_x + 14.0, bounds.y + 181.0, text_w - 14.0, "Triangle: you", ORANGE);
}

fn world_page() {
    heading("STREAMING WORLD / LIVE CHUNK MAP");
    chunk_map();
    metric("Chunks ready / resident", str(stats::counters.chunks_ready, " / ", stats::counters.chunk_live), CYAN);
    metric("Chunk storage / free slots", str(stats::counters.chunk_slots, " / ", stats::counters.free_chunk_slots), IVORY);
    metric("Generation jobs queued", count_text(stats::counters.terrain_jobs), ORANGE);
    metric("Generated / evicted", str(stats::counters.terrain_generated, " / ", stats::counters.terrain_evicted), IVORY);
    milliseconds("Worker generation / latest", stats::counters.worker_generation_last_ms);
    milliseconds("Worker generation / cumulative", stats::counters.worker_generation_ms);
    milliseconds("Queue calls / cumulative", stats::counters.queue_transfer_ms);
    milliseconds("Queue waiting / cumulative", stats::counters.queue_wait_ms);
    metric("Persistent terrain edits", count_text(stats::counters.terrain_edits), IVORY);
    metric("Depletion records", count_text(stats::counters.depletion_records), IVORY);
    heading("GPU RESOURCES / APPLICATION COUNTERS");
    metric("Terrain GPU meshes", count_text(scene::mesh_count), CYAN);
    metric("Horizon meshes / triangles", str(count_text(horizon::mesh_count), " / ", count_text(horizon::triangles)), IVORY);
    metric("Horizon rings pending", count_text(horizon::pending_rings), ORANGE);
    milliseconds("Horizon worker CPU / latest", horizon::generation_ms);
    milliseconds("Horizon queue calls / cumulative", horizon::transfer_ms);
    milliseconds("Horizon GPU uploads / cumulative", horizon::upload_ms);
    metric("Horizon worker", if horizon::worker_busy { "Generating" } else { "Idle" }, CYAN);
    metric("Terrain and prop vertices", count_text(scene::terrain_vertices), IVORY);
    metric("Visible triangle submissions", count_text(render::triangles), IVORY);
    metric("Draw calls", count_text(render::draw_calls), IVORY);
    metric("Dynamic vertex capacity", str(decimal(render::dynamic_capacity / 1000000.0, 1), " MB"), IVORY);
    milliseconds("GPU buffer upload / CPU call", render::upload_ms);
    heading("AUTOMATION / NAVIGATION");
    metric("Power graph components", count_text(stats::counters.power_components), IVORY);
    metric("Power topology rebuilds", count_text(stats::counters.power_topology_rebuilds), IVORY);
    metric("A* calls / failed", str(stats::counters.path_calls, " / ", stats::counters.path_failed), IVORY);
    metric("A* cells expanded", count_text(stats::counters.path_expanded), IVORY);
    milliseconds("A* cumulative CPU", stats::counters.path_total_ms);
    metric("Items processed", count_text(stats::counters.crafted), IVORY);
}

fn pool_row(name: const u8[:], live: i64, free: i64, slots: i64, peak: i64) {
    caption(str(name, " / live ", count_text(live), " / free ", count_text(free)));
    ui::layout_row_dynamic(context, 12.0, 1);
    let state, bounds = ui::widget(context);
    if state != ui::WIDGET_INVALID {
        ui::fill_rect(context, bounds, 3.0, ui::Color { 20, 27, 51, 255 });
        let live_width: f32 = bounds.w * live / max(slots, 1);
        let free_width: f32 = bounds.w * free / max(slots, 1);
        if live_width > 0.0 {
            ui::fill_rect(context, ui::rect(bounds.x, bounds.y, live_width, bounds.h), 0.0, CYAN);
        }
        if free_width > 0.0 {
            ui::fill_rect(context, ui::rect(bounds.x + live_width, bounds.y, free_width, bounds.h), 0.0,
                ui::Color { 74, 85, 120, 255 });
        }
        ui::stroke_line(context, bounds.x + bounds.w - 2.0, bounds.y - 1.0,
            bounds.x + bounds.w - 2.0, bounds.y + bounds.h + 1.0, 2.0, ORANGE);
    }
    caption(str("Storage ", count_text(slots), " / sampled peak ", count_text(peak)));
}

fn reuse_chart() {
    if pool_count < 2 {
        caption("Collecting 4 Hz storage samples...");
        return;
    }
    ui::layout_row_dynamic(context, 90.0, 1);
    let maximum: f32 = max(ecs::entities.len * 1.1, 10.0);
    if ui::chart_begin_colored(context, ui::CHART_LINES, CYAN, IVORY, pool_count, 0.0, maximum) {
        ui::chart_add_slot_colored(context, ui::CHART_LINES, MUTED, ORANGE, pool_count, 0.0, maximum);
        for i in pool_count {
            let value = pool_sample(i);
            ui::chart_push_slot(context, value.live, 0);
            ui::chart_push_slot(context, value.slots, 1);
        }
        ui::chart_end(context);
    }
    caption("Cyan: live / Slate: storage / 240 samples at 4 Hz");
}

fn kind_name(kind: i64) -> const u8[:] {
    if kind == sim::LANDER {
        return "Lander";
    }
    if kind == sim::MINER {
        return "Drill";
    }
    if kind == sim::SMELTER {
        return "Smelter";
    }
    if kind == sim::SOLAR {
        return "Solar array";
    }
    if kind == sim::RELAY {
        return "Power relay";
    }
    if kind == sim::ASSEMBLER {
        return "Assembler";
    }
    if kind == sim::ROBOT {
        return "Worker robot";
    }
    if kind == sim::TOWER {
        return "Comms beacon";
    }
    if kind == sim::STORAGE {
        return "Cargo depot";
    }
    if kind == sim::DEPOSIT_ORE {
        return "Ferrite deposit";
    }
    if kind == sim::DEPOSIT_CRYSTAL {
        return "Glacite deposit";
    }
    if kind == sim::STRESS {
        return "Stress object";
    }
    "Unknown kind"
}

fn goose_page() {
    heading("GOOSE POOLS / LOGICAL STORAGE");
    wrapped("Pooled storage, generational handles and isolated worker queues. This shows reuse and safety, not a claim about FPS.", 42.0);
    pool_row("Entities", stats::counters.active_entities, stats::counters.free_entity_slots,
        stats::counters.entity_slots, stats::high_water.entity_slots);
    pool_row("Inventories", stats::counters.inventory_live, stats::counters.inventory_free,
        stats::counters.inventory_cells, stats::high_water.inventory_cells);
    pool_row("Task queues", stats::counters.queue_live, stats::counters.queue_free,
        stats::counters.queue_cells, stats::high_water.queue_cells);
    pool_row("Graph edges", stats::counters.edge_live, stats::counters.edge_free,
        stats::counters.edge_cells, stats::high_water.edge_cells);
    pool_row("Packets", stats::counters.live_packets, stats::counters.free_packet_slots,
        stats::counters.packet_slots, stats::high_water.packet_slots);
    pool_row("Chunks", stats::counters.chunk_live, stats::counters.free_chunk_slots,
        stats::counters.chunk_slots, stats::high_water.chunk_slots);
    wrapped("Slots and cells are retained high-water storage. Peak counters are sampled at 4 Hz. Free runs and generational slots are reused; temporary geometry and paths end with their scope.", 58.0);
    heading("STORAGE REUSED, NOT GROWN");
    reuse_chart();
    churn_buttons();
    if last_churn.completed {
        wrapped(str("Last churn: ", time_text(last_churn.elapsed_ms),
            " / slots ", count_text(last_churn.slots_before), " -> ", count_text(last_churn.slots_after),
            " / collection cells ", count_text(last_churn.cells_before), " -> ", count_text(last_churn.cells_after)), 42.0);
    }
    heading("HANDLES / THIS PROCESS");
    metric("Handles issued / highest generation", count_text(ecs::next_generation), IVORY);
    heading("MEMORY / MEASUREMENT BOUNDARY");
    metric("Logical payload estimate", str(decimal(stats::counters.payload_estimate_bytes / 1000000.0, 1), " MB"), CYAN);
    wrapped("Estimate excludes OS residency, GPU/native driver allocations and pool freelist metadata. RSS and Goose stack byte high-water marks are unavailable in this overlay.", 58.0);
    ui::layout_row_dynamic(context, 30.0, 1);
    trim_bounds = ui::widget_bounds(context);
    if ui::button_label(context, "Release unused stack pages") {
        actions.trim_memory = true;
    }
    wrapped("Main-thread stacks only. Live data, retained pool capacity and GPU resources stay allocated.", 42.0);
    if memory::requests > 0 {
        metric("Last page-release request", str(if memory::last_ok { "OK / " } else { "Failed / " },
            time_text(memory::last_ms)), if memory::last_ok { CYAN } else { ORANGE });
        metric("Page-release requests / failures", str(count_text(memory::requests), " / ", count_text(memory::failures)), IVORY);
    }
    if stats::counters.stale_handles_rejected < 0 {
        metric("Stale-handle rejection count", "Not instrumented", MUTED);
    } else {
        metric("Stale-handle rejection count", count_text(stats::counters.stale_handles_rejected), IVORY);
    }
    heading("ENTITY KINDS / LIVE COUNTS");
    if kind_sample_frame < 0 || stats::total_frames < kind_sample_frame || stats::total_frames - kind_sample_frame >= 15 {
        kind_counts = [0; 96];
        for e in ecs::entities {
            if e.alive && e.kind >= 0 && e.kind < 96 {
                kind_counts[e.kind]++;
            }
        }
        kind_sample_frame = stats::total_frames;
    }
    for kind in 96 {
        if kind_counts[kind] > 0 {
            metric(kind_name(kind), count_text(kind_counts[kind]), IVORY);
        }
    }
}

fn float_row(name: const u8[:], value: f32&, minimum: f32, maximum: f32,
             step: f32, default_value: f32, unit: const u8[:]) -> ui::Rect {
    let changed = abs(value - default_value) > 0.0001;
    ui::layout_row_begin(context, ui::DYNAMIC, 30.0, 4);
    ui::layout_row_push(context, 0.32);
    ui::label_colored(context, str(if changed { "* " } else { "" }, name), ui::TEXT_LEFT,
        if changed { ORANGE } else { MUTED });
    ui::layout_row_push(context, 0.40);
    let bounds = ui::widget_bounds(context);
    ui::slider_float(context, minimum, value, maximum, step);
    ui::layout_row_push(context, 0.20);
    ui::label(context, slider_text(value, step, unit), ui::TEXT_RIGHT);
    ui::layout_row_push(context, 0.08);
    if changed {
        let hovered = ui::widget_is_hovered(context);
        var reset_style = ui::style(context).button;
        reset_style.padding = float2 { 1.0, 2.0 };
        if ui::button_label_styled(context, reset_style, "R") {
            value = default_value;
        }
        if hovered {
            ui::tooltip(context, str("Reset to ", slider_text(default_value, step, unit)));
        }
    } else {
        ui::spacing(context, 1);
    }
    ui::layout_row_end(context);
    bounds
}

fn integer_row(name: const u8[:], value: i64&, minimum: i64, maximum: i64,
               step: i64, default_value: i64) -> ui::Rect {
    let changed = value != default_value;
    ui::layout_row_begin(context, ui::DYNAMIC, 30.0, 4);
    ui::layout_row_push(context, 0.32);
    ui::label_colored(context, str(if changed { "* " } else { "" }, name), ui::TEXT_LEFT,
        if changed { ORANGE } else { MUTED });
    ui::layout_row_push(context, 0.40);
    let bounds = ui::widget_bounds(context);
    ui::slider_int(context, minimum, value, maximum, step);
    ui::layout_row_push(context, 0.20);
    ui::label(context, count_text(value), ui::TEXT_RIGHT);
    ui::layout_row_push(context, 0.08);
    if changed {
        let hovered = ui::widget_is_hovered(context);
        var reset_style = ui::style(context).button;
        reset_style.padding = float2 { 1.0, 2.0 };
        if ui::button_label_styled(context, reset_style, "R") {
            value = default_value;
        }
        if hovered {
            ui::tooltip(context, str("Reset to ", default_value));
        }
    } else {
        ui::spacing(context, 1);
    }
    ui::layout_row_end(context);
    bounds
}

fn churn_buttons() {
    ui::layout_row_dynamic(context, 32.0, 3);
    spawn_bounds = ui::widget_bounds(context);
    if ui::button_label(context, "Spawn 1 000") {
        actions.spawn_objects = 1000;
    }
    destroy_bounds = ui::widget_bounds(context);
    if ui::button_label(context, "Destroy 1 000") {
        actions.destroy_objects = 1000;
    }
    if ui::button_label(context, "Churn x10") {
        actions.churn_rounds = 10;
    }
}

fn controls_page() {
    heading("STRATEGIC FREE FLIGHT");
    ui::layout_row_dynamic(context, 32.0, 2);
    flight_bounds = ui::widget_bounds(context);
    if ui::button_label(context, if flight_active { "G Return to suit" } else { "G Free flight" }) {
        actions.toggle_flight = true;
    }
    reframe_bounds = ui::widget_bounds(context);
    if ui::button_label(context, "Home Overview") {
        actions.reframe_flight = true;
    }
    flight_speed_bounds = float_row("Flight speed", settings.flight_speed,
        10.0, 300.0, 2.0, 48.0, " m/s");
    caption(str(if flight_active { "Flying / altitude " } else { "Suit / flight altitude " },
        decimal(flight_altitude, 0), " m"));
    heading("SIMULATION / LIVE SETTINGS");
    ui::layout_row_dynamic(context, 30.0, 2);
    if ui::button_label(context, if settings.simulation_speed > 0.0 { "Pause simulation" } else { "Resume simulation" }) {
        if settings.simulation_speed > 0.0 {
            resume_speed = settings.simulation_speed;
            settings.simulation_speed = 0.0;
        } else {
            settings.simulation_speed = max(resume_speed, 0.25);
        }
    }
    if ui::button_label(context, "Single step") {
        actions.single_step = true;
    }
    speed_bounds = float_row("Simulation speed", settings.simulation_speed, 0.0, 4.0, 0.25, 1.0, "×");
    integer_row("Robot path budget", settings.robot_budget, 0, 16, 1, 2);
    ui::layout_row_dynamic(context, 26.0, 2);
    ui::checkbox_label(context, "Pause day cycle", settings.lock_time);
    if ui::button_label(context, "Step time +1 hour") {
        settings.day_phase = (settings.day_phase + 1.0 / 24.0) % 1.0;
        settings.lock_time = true;
    }
    var hours: f32 = (settings.day_phase * 24.0 + 6.0) % 24.0;
    let previous = hours;
    day_bounds = float_row("Time of day", hours, 0.0, 23.75, 0.25, 15.0, "HH:MM");
    if hours != previous {
        settings.day_phase = ((hours + 18.0) % 24.0) / 24.0;
        settings.lock_time = true;
    }
    heading("WORLD / STREAMING");
    radius_bounds = integer_row("Detailed radius", settings.detail_radius, 2, 8, 1, 6);
    let across = settings.detail_radius * 2 + 1;
    caption(str(settings.detail_radius * 32, " m radius / ", count_text(across * across), " detailed chunks"));
    integer_row("Mesh jobs / frame", settings.mesh_budget, 1, 12, 1, 4);
    heading("ATMOSPHERE / SCENE");
    float_row("Fog starts", settings.fog_start, 80.0, 400.0, 10.0, 140.0, " m");
    float_row("Visibility", settings.fog_distance, 600.0, 2400.0, 50.0, 1600.0, " m");
    float_row("Vegetation", settings.vegetation, 0.5, 3.0, 0.1, 1.0, "×");
    float_row("Camera speed", settings.camera_speed, 0.5, 2.0, 0.05, 1.0, "×");
    ui::layout_row_dynamic(context, 26.0, 2);
    ui::checkbox_label(context, "Sun shadows", settings.shadows);
    ui::checkbox_label(context, "Wireframe", settings.show_wireframe);
    heading("LOAD / MEASURE REUSE");
    integer_row("Colony load", settings.load, 32, 2000, 32, 512);
    ui::layout_row_dynamic(context, 31.0, 2);
    if ui::button_label(context, "Load factory") {
        actions.build_showcase = true;
    }
    if ui::button_label(context, "+10 worker robots") {
        actions.spawn_robots = 10;
    }
    churn_buttons();
    ui::layout_row_dynamic(context, 24.0, 1);
    ui::checkbox_label(context, "Rapid chunk streaming", actions.rapid_stream);
    ui::layout_row_dynamic(context, 30.0, 3);
    if ui::button_label(context, "Save world") {
        actions.save = true;
    }
    if ui::button_label(context, "Load world") {
        actions.load = true;
    }
    if ui::button_label(context, "Reset metrics") {
        actions.reset_stats = true;
    }
    ui::layout_row_dynamic(context, 28.0, 1);
    if ui::button_label(context, "Reset all settings") {
        settings = Settings {};
    }
    wrapped("Orange labels mark changes; R restores one default. World changes queue real terrain and mesh work.", 40.0);
}

fn resource_name(kind: i64) -> const u8[:] {
    if kind == 0 {
        return "Ferrite";
    }
    if kind == 1 {
        return "Glacite";
    }
    if kind == 2 {
        return "Alloy";
    }
    if kind == 3 {
        return "Circuits";
    }
    if kind == 4 {
        return "Regolith";
    }
    "Custom item"
}

fn inspect_page() {
    ui::layout_row_dynamic(context, 30.0, 3);
    if ui::button_label(context, if pick_armed { "Pick armed" } else { "Pick in world" }) {
        pick_armed = !pick_armed;
    }
    pin_bounds = ui::widget_bounds(context);
    if ui::button_label(context, "Pin selected entity") {
        pinned = selected;
    }
    if ui::button_label(context, "Clear pin") {
        pinned = ecs::Handle {};
    }
    let handle = if pinned.slot >= 0 { pinned } else { selected };
    heading(if pinned.slot >= 0 { "PINNED ENTITY" } else { "SELECTED ENTITY" });
    metric("Handle slot / generation", handle_text(handle), CYAN);
    if !ecs::valid(handle) {
        wrapped(if handle.slot < 0 { "Aim at a machine or deposit to inspect its live state, then pin it to keep watching while you explore." }
            else { "This handle is stale. Its slot was destroyed or reused; the generation check prevents following the replacement entity." }, 76.0);
        return;
    }
    let e .= ecs::entities[handle.slot];
    metric("Kind", kind_name(e.kind), IVORY);
    metric("Position X / Y / Z", str(round(e.pos.x), " / ", round(e.pos.y), " / ", round(e.pos.z)), IVORY);
    metric("Power", if e.powered { "Powered" } else { "Unpowered" }, if e.powered { CYAN } else { ORANGE });
    metric("Production phase", decimal(e.progress, 2), IVORY);
    metric("State / timer", str(e.state, " / ", decimal(e.timer, 2)), IVORY);
    metric("Cargo kind / count", str(resource_name(e.cargo_kind), " / ", e.cargo_count), IVORY);
    metric("Target slot / generation", handle_text(e.target), if ecs::valid(e.target) { CYAN } else { MUTED });
    heading(str("INVENTORY / ", e.inventory.len, " ITEM KINDS"));
    for item in e.inventory {
        metric(resource_name(item.kind), count_text(item.count), IVORY);
    }
    if e.inventory.len == 0 {
        caption("Empty");
    }
    heading(str("QUEUE / ", e.queue.len, " ENTRIES"));
    for i in min(e.queue.len, 32) {
        metric(str("Entry ", i, " / kind ", e.queue[i].kind), str(e.queue[i].count), IVORY);
    }
    if e.queue.len == 0 {
        caption("Empty");
    }
    if e.queue.len > 32 {
        caption("First 32 entries shown");
    }
    heading(str("GRAPH LINKS / ", e.links.len));
    for i in min(e.links.len, 32) {
        let link = e.links[i];
        ui::layout_row_dynamic(context, 28.0, 1);
        let label = if ecs::valid(link) {
            str("-> ", handle_text(link), " / ", kind_name(ecs::entities[link.slot].kind))
        } else {
            str("-> ", handle_text(link), " / stale")
        };
        if ui::button_label(context, label) && ecs::valid(link) {
            pinned = link;
        }
    }
    if e.links.len == 0 {
        caption("No outgoing links");
    }
    if e.links.len > 32 {
        caption("First 32 links shown");
    }
}

fn draw(current: ecs::Handle) {
    let draw_started = clock();
    selected = current;
    if !open {
        was_open = false;
        return;
    }
    if mode == 0 {
        mode = 1;
    }
    if !was_open {
        ui::window_show(context, "Developer Console", ui::SHOWN);
        ui::window_collapse(context, "Developer Console", ui::MAXIMIZED);
    }
    let size = gfx::screen_size();
    let screen_w: f32 = size.x / scale;
    let screen_h: f32 = size.y / scale;
    let width: f32 = min(450.0, screen_w - 32.0);
    let height: f32 = max(360.0, screen_h - 32.0);
    let bounds = ui::rect(screen_w - width - 16.0, 16.0, width, height);
    if resized && ui::window_find(context, "Developer Console") {
        ui::window_set_bounds(context, "Developer Console", bounds);
    }
    if mode == 2 {
        let compact = ui::rect(screen_w - width - 16.0, 16.0, width, 156.0);
        if ui::begin(context, "Developer Compact", compact, ui::WINDOW_BORDER | ui::WINDOW_NO_SCROLLBAR) {
            panel_bounds = ui::window_get_bounds(context);
            compact_header();
            frame_chart(76.0);
        }
        ui::end(context);
        was_open = open;
        panel_ms = (clock() - draw_started) * 1000.0;
        return;
    }
    let flags = ui::WINDOW_BORDER | ui::WINDOW_MOVABLE | ui::WINDOW_TITLE | ui::WINDOW_MINIMIZABLE | ui::WINDOW_CLOSABLE | ui::WINDOW_NO_SCROLLBAR;
    if ui::begin(context, "Developer Console", bounds, flags) {
        panel_bounds = ui::window_get_bounds(context);
        header();
        ui::layout_row_dynamic(context, 30.0, 5);
        for i in 5 {
            tab_bounds[i] = ui::widget_bounds(context);
            var style = ui::style(context).button;
            if tab == i {
                style.normal = ui::style_item_color(ORANGE);
                style.text_normal = INK;
            }
            if ui::button_label_styled(context, style, TABS[i]) {
                tab = i;
            }
        }
        let available = ui::window_get_content_region_size(context);
        ui::layout_row_dynamic(context, max(200.0, available.y - 112.0), 1);
        if requested_scroll >= 0 {
            ui::group_set_scroll(context, TABS[tab], 0, requested_scroll);
            requested_scroll = -1;
        }
        if ui::group_begin(context, TABS[tab], 0) {
            if tab == 0 {
                overview();
            }
            if tab == 1 {
                world_page();
            }
            if tab == 2 {
                goose_page();
            }
            if tab == 3 {
                controls_page();
            }
            if tab == 4 {
                inspect_page();
            }
            ui::group_end(context);
        }
    }
    ui::end(context);
    if ui::window_is_closed(context, "Developer Console") {
        open = false;
        mode = 0;
    }
    was_open = open;
    panel_ms = (clock() - draw_started) * 1000.0;
}

fn present() {
    if open {
        let started = clock();
        ui::render(context);
        panel_ms += (clock() - started) * 1000.0;
    }
    // Deliberately do not retire the shared UI index buffer here. The root
    // must call hud::present() after ALL contexts, including this one, so its
    // pinned Metal resource-retirement workaround runs exactly once.
}

fn shutdown() {
    if context.id != 0 {
        ui::destroy(context);
        context = ui::Context { 0 };
    }
}
