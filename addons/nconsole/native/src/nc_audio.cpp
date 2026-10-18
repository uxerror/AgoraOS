#include "nc_audio.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>

using namespace godot;

namespace {
// CPU cycles per noise generator step, for each rate.
const int NOISE_PERIODS[16] = { 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048 };
const double DUTY[4] = { 0.125, 0.25, 0.5, 0.75 };
// Frames between volume steps for each decay setting.
const int DECAY_FRAMES[4] = { 0, 1, 2, 4 };
// Loudest output, all channels at full volume.
const double MASTER = 0.5;
} // namespace

NCAudio::NCAudio() {
	reset();
}

void NCAudio::reset() {
	ch.fill(Channel());
	enabled = 0x0F;
	events.clear();
	lfsr = 1;
}

// Bits for the channels that are sounding (a note on, volume above 0).
int NCAudio::status() const {
	int bits = 0;
	for (int k = 0; k < CHANNELS; k++) {
		if (ch[k].playing && ch[k].level > 0) {
			bits |= 1 << k;
		}
	}
	return bits;
}

// Queues a register write (reg counted from $3030) to happen at `sample`
// of the next mix.
void NCAudio::write(int reg, int value, int sample) {
	events.push_back({ sample, reg, value });
}

// The next `count` stereo samples, then one frame's worth of length and
// decay.
PackedVector2Array NCAudio::mix(int count) {
	PackedVector2Array out;
	out.resize(count);
	Vector2 *samples = out.ptrw();
	size_t e = 0;
	int s = 0;
	while (s < count) {
		while (e < events.size() && events[e].sample <= s) {
			apply(events[e].reg, events[e].value);
			e++;
		}
		const int until = e >= events.size() ? count : std::clamp(events[e].sample, s + 1, count);
		render(samples, s, until);
		s = until;
	}
	for (; e < events.size(); e++) {
		apply(events[e].reg, events[e].value);
	}
	events.clear();
	frame();
	return out;
}

void NCAudio::apply(int reg, int value) {
	if (reg == 0x10) {
		enabled = value & 0x0F;
		return;
	}
	if (reg < 0 || reg > 0x0F) {
		return;
	}
	Channel &c = ch[reg >> 2];
	switch (reg & 3) {
		case 0:
			c.period = (c.period & 0x700) | (value & 0xFF);
			break;
		case 1:
			c.period = (c.period & 0xFF) | ((value & 7) << 8);
			c.playing = true;
			c.level = c.volume;
			c.length = c.shape & 63;
			c.decay_count = 0;
			break;
		case 2:
			c.volume = value & 15;
			c.level = c.volume;
			c.duty = (value >> 4) & 3;
			c.short_mode = (value & 0x10) != 0;
			break;
		case 3:
			c.shape = value & 0xFF;
			break;
	}
}

void NCAudio::render(Vector2 *out, int from, int to) {
	for (int k = 0; k < CHANNELS; k++) {
		Channel &c = ch[k];
		if (!c.playing || c.level == 0 || !(enabled & (1 << k))) {
			continue;
		}
		const float amp = c.level / 15.0 * MASTER / CHANNELS;
		if (k == NOISE) {
			const double steps = double(clock_hz) / NOISE_PERIODS[c.period & 15] / sample_rate;
			const int tap = c.short_mode ? 6 : 1;
			for (int s = from; s < to; s++) {
				c.phase += steps;
				while (c.phase >= 1.0) {
					c.phase -= 1.0;
					const int fb = (lfsr ^ (lfsr >> tap)) & 1;
					lfsr = (lfsr >> 1) | (fb << 14);
				}
				const float v = (lfsr & 1) ? amp : -amp;
				out[s] += Vector2(v, v);
			}
			continue;
		}
		if (c.period < 8) {
			continue; // above hearing: silent, as on real chips
		}
		const double inc = double(clock_hz) / (16.0 * (c.period + 1)) / sample_rate;
		if (k == TRIANGLE) {
			for (int s = from; s < to; s++) {
				c.phase = std::fmod(c.phase + inc, 1.0);
				const float v = amp * (1.0 - 4.0 * std::abs(c.phase - 0.5));
				out[s] += Vector2(v, v);
			}
		} else {
			const double duty = DUTY[c.duty];
			for (int s = from; s < to; s++) {
				c.phase = std::fmod(c.phase + inc, 1.0);
				const float v = c.phase < duty ? amp : -amp;
				out[s] += Vector2(v, v);
			}
		}
	}
}

// Length counters and decay, once a frame.
void NCAudio::frame() {
	for (Channel &c : ch) {
		if (!c.playing) {
			continue;
		}
		if (c.length > 0) {
			c.length--;
			if (c.length == 0) {
				c.playing = false;
				continue;
			}
		}
		const int decay = c.shape >> 6;
		if (decay > 0 && c.level > 0) {
			c.decay_count++;
			if (c.decay_count >= DECAY_FRAMES[decay]) {
				c.decay_count = 0;
				c.level--;
				if (c.level == 0) {
					c.playing = false;
				}
			}
		}
	}
}

void NCAudio::_bind_methods() {
	ClassDB::bind_method(D_METHOD("reset"), &NCAudio::reset);
	ClassDB::bind_method(D_METHOD("status"), &NCAudio::status);
	ClassDB::bind_method(D_METHOD("write", "reg", "value", "sample"), &NCAudio::write);
	ClassDB::bind_method(D_METHOD("mix", "count"), &NCAudio::mix);
	ClassDB::bind_method(D_METHOD("get_clock_hz"), &NCAudio::get_clock_hz);
	ClassDB::bind_method(D_METHOD("set_clock_hz", "hz"), &NCAudio::set_clock_hz);
	ClassDB::bind_method(D_METHOD("get_sample_rate"), &NCAudio::get_sample_rate);
	ClassDB::bind_method(D_METHOD("set_sample_rate", "rate"), &NCAudio::set_sample_rate);
	ClassDB::bind_method(D_METHOD("get_enabled"), &NCAudio::get_enabled);
	ClassDB::bind_method(D_METHOD("set_enabled", "mask"), &NCAudio::set_enabled);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "clock_hz"), "set_clock_hz", "get_clock_hz");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "sample_rate"), "set_sample_rate", "get_sample_rate");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "enabled"), "set_enabled", "get_enabled");
	BIND_CONSTANT(CHANNELS);
	BIND_CONSTANT(TRIANGLE);
	BIND_CONSTANT(NOISE);
}
