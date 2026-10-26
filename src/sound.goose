namespace sound;
import std;
import math;
import audio;
var enabled = false;
var mining: audio::Sound;
var building: audio::Sound;
var chime: audio::Sound;

fn tone(start: f32, end: f32, length: f32) -> audio::Sound {
    var samples: f32[>..] = [];
    let n = (length * 24000.0) as! i64;
    var phase: f32 = 0.0;
    for i in n {
        let t = i / (n as f32);
        phase += (start + (end - start) * t) * TAU / 24000.0;
        let envelope = sin(t * PI) * (1.0 - t);
        samples.push((sin(phase) * 0.55 + sin(phase * 2.01) * 0.15) * envelope * 0.25);
    }
    audio::create_sound(samples, 24000, 1)
}

fn init() {
    enabled = audio::open();
    if enabled {
        mining = tone(180.0, 70.0, 0.12);
        building = tone(330.0, 880.0, 0.25);
        chime = tone(660.0, 1320.0, 0.7);
    }
}

fn mine() {
    if enabled {
        audio::play(mining, 0.6);
    }
}

fn build() {
    if enabled {
        audio::play(building, 0.65);
    }
}

fn success() {
    if enabled {
        audio::play(chime, 0.7);
    }
}

fn shutdown() {
    if enabled {
        audio::close();
    }
}
