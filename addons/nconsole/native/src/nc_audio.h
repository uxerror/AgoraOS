// The sound chip: two pulse channels, a triangle and a noise channel.
//
// Registers ($30xx), four per channel at $30 + 4 * channel (0 and 1 pulse,
// 2 triangle, 3 noise):
//   +0 PERIOD     low 8 bits of the period; for noise, bits 0-3 pick one
//                 of 16 rates (0 is the highest)
//   +1 PERIODHI   bits 0-2: high bits of the period. Writing it starts the
//                 note: the length and the volume start again.
//   +2 VOLUME     bits 0-3 volume; bits 4-5 duty for pulse (12.5, 25, 50,
//                 75%); bit 4 for noise makes it short and metallic
//   +3 SHAPE      bits 0-5 length in frames (0: until changed); bits 6-7
//                 decay: 0 none, then the volume drops one step every 1, 2
//                 or 4 frames
//   $40 SOUND     write: channels on (bit per channel, $0f after reset);
//                 read: which channels are sounding
//
// A tone's frequency is CLOCK / (16 * (period + 1)) on all three tonal
// channels, so the same period gives the same note: 253 is A4 (440 Hz).
// Writes take effect at the sample matching the CPU cycle they happen on,
// so sound isn't limited to the frame rate.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>

#include <array>
#include <vector>

namespace godot {

class NCAudio : public RefCounted {
	GDCLASS(NCAudio, RefCounted)

public:
	static constexpr int CHANNELS = 4;
	static constexpr int TRIANGLE = 2;
	static constexpr int NOISE = 3;

	NCAudio();

	void reset();
	int status() const;
	void write(int reg, int value, int sample);
	PackedVector2Array mix(int count);

	int clock_hz = 1789773;
	int sample_rate = 44100;
	int enabled = 0x0F;

	int get_clock_hz() const { return clock_hz; }
	void set_clock_hz(int v) { clock_hz = v; }
	int get_sample_rate() const { return sample_rate; }
	void set_sample_rate(int v) { sample_rate = v; }
	int get_enabled() const { return enabled; }
	void set_enabled(int v) { enabled = v; }

protected:
	static void _bind_methods();

private:
	struct Channel {
		int period = 0;
		int volume = 0;
		int level = 0;
		int duty = 2;
		bool short_mode = false;
		int shape = 0;
		int length = 0;
		int decay_count = 0;
		bool playing = false;
		double phase = 0.0;
	};
	struct Event {
		int sample, reg, value;
	};

	std::array<Channel, CHANNELS> ch{};
	std::vector<Event> events;
	int lfsr = 1;

	void apply(int reg, int value);
	void render(Vector2 *out, int from, int to);
	void frame();
};

} // namespace godot
