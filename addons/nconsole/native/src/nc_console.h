// The console: an N8 at 1.79 MHz (the clock of NTSC consoles of the 80s),
// the video chip, the sound chip, two controllers and a cartridge slot.
// run_frame() runs one 60th of a second: the vblank (which wakes a waiting
// CPU and, if enabled, interrupts it), the CPU's share of cycles, then the
// sound is mixed and the picture drawn from video RAM.
//
// I/O registers ($30xx):
//   $00 VCTRL   bit 0 background on, bit 1 sprites on, bit 7 vblank
//               interrupt; $03 after reset
//   $01 BGCOLOR color behind everything (0-15)
//   $02 SCROLLX, $03 SCROLLY  the background's offset in pixels
//   $04 FIXROWS the top rows that don't scroll (0-15), for a status bar
//   $08 PRGBANK program bank seen at $8000-$BFFF (0 after reset)
//   $09 CHRBANK tile set the video chip uses (0 after reset)
//   $10 PAD1, $11 PAD2 (read): bit 0 up, 1 down, 2 left, 3 right,
//               4 A, 5 B, 6 select, 7 start
//   $20 FRAME, $21 FRAMEHI (read): frames since reset
//   $22 RANDOM  (read): a new pseudo-random byte on every read
//   $30-$40     sound, see NCAudio
//   $FF DEBUG   (write): a character for the debug log
//
// A debugger can stop a frame in the middle (a breakpoint or watched
// write pauses the console), step it one instruction at a time, and
// resume.

#pragma once

#include "nc_audio.h"
#include "nc_cartridge.h"
#include "nc_cpu.h"
#include "nc_video.h"

#include <godot_cpp/classes/ref_counted.hpp>

namespace godot {

class NConsole : public RefCounted, public NCIoDevice {
	GDCLASS(NConsole, RefCounted)

public:
	static constexpr int CLOCK_HZ = 1789773;
	static constexpr int FPS = 60;
	static constexpr int CYCLES_PER_FRAME = CLOCK_HZ / FPS;
	static constexpr int SAMPLE_RATE = 44100;
	static constexpr int SAMPLES_PER_FRAME = SAMPLE_RATE / FPS;

	static constexpr int BTN_UP = 0x01;
	static constexpr int BTN_DOWN = 0x02;
	static constexpr int BTN_LEFT = 0x04;
	static constexpr int BTN_RIGHT = 0x08;
	static constexpr int BTN_A = 0x10;
	static constexpr int BTN_B = 0x20;
	static constexpr int BTN_SELECT = 0x40;
	static constexpr int BTN_START = 0x80;

	static constexpr int REG_VCTRL = 0x00;
	static constexpr int REG_BGCOLOR = 0x01;
	static constexpr int REG_SCROLLX = 0x02;
	static constexpr int REG_SCROLLY = 0x03;
	static constexpr int REG_FIXROWS = 0x04;
	static constexpr int REG_PRGBANK = 0x08;
	static constexpr int REG_CHRBANK = 0x09;
	static constexpr int REG_PAD1 = 0x10;
	static constexpr int REG_PAD2 = 0x11;
	static constexpr int REG_FRAME = 0x20;
	static constexpr int REG_FRAMEHI = 0x21;
	static constexpr int REG_RANDOM = 0x22;
	static constexpr int REG_SOUND = 0x30;
	static constexpr int REG_SOUND_END = 0x40;
	static constexpr int REG_DEBUG = 0xFF;

	NConsole();
	~NConsole();

	void insert(const Ref<NCCartridge> &cart);
	void reset();
	void run_frame();
	void step_instruction();
	void resume();
	void render_now();
	// Controller 0 or 1 holds these buttons (BTN_* bits).
	void set_pad(int index, int buttons);
	int read_io(int reg) override;
	void write_io(int reg, int value) override;

	Ref<NCCpu> cpu;
	Ref<NCVideo> video;
	Ref<NCAudio> audio;
	Ref<NCCartridge> cartridge;
	PackedVector2Array sound;
	PackedByteArray pads;
	int frame = 0;
	int vctrl = 0x03;
	int bg_color = 0;
	int scroll_x = 0;
	int scroll_y = 0;
	int fixed_rows = 0;
	int prg_bank = 0;
	int64_t last_cycles = 0;
	String debug_log;
	bool paused = false;

#define NC_ACCESSORS(ctype, name) \
	ctype _get_##name() const { return name; } \
	void _set_##name(ctype value) { name = value; }
	NC_ACCESSORS(Ref<NCCpu>, cpu)
	NC_ACCESSORS(Ref<NCVideo>, video)
	NC_ACCESSORS(Ref<NCAudio>, audio)
	NC_ACCESSORS(Ref<NCCartridge>, cartridge)
	NC_ACCESSORS(PackedVector2Array, sound)
	NC_ACCESSORS(PackedByteArray, pads)
	NC_ACCESSORS(int, frame)
	NC_ACCESSORS(int, vctrl)
	NC_ACCESSORS(int, bg_color)
	NC_ACCESSORS(int, scroll_x)
	NC_ACCESSORS(int, scroll_y)
	NC_ACCESSORS(int, fixed_rows)
	NC_ACCESSORS(int, prg_bank)
	NC_ACCESSORS(int64_t, last_cycles)
	NC_ACCESSORS(String, debug_log)
	NC_ACCESSORS(bool, paused)
#undef NC_ACCESSORS

protected:
	static void _bind_methods();

private:
	int rng = 0xACE1;
	int64_t frame_start = 0;
	bool in_frame = false;
	int64_t left = 0;
	bool redraw = true;

	void begin_frame();
	void end_frame();
	void map_bank(int n);
	int next_random();
};

} // namespace godot
