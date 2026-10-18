// The N8 processor and its bus. Memory map:
//
//   $0000-$00FF  zero page (plain RAM, a good place for pointers)
//   $0100-$01FF  stack
//   $0200-$1FFF  RAM
//   $2000-$2FFF  video RAM (see NCVideo); plain RAM to the CPU
//   $3000-$30FF  I/O registers, handled by `io`
//   $8000-$FFFF  cartridge ROM; writes are ignored
//
// Vectors at the top of ROM: $FFFA vblank, $FFFC reset, $FFFE brk.
// Interrupts push PC (high, then low) and the flags, set I, and jump
// through their vector; reti undoes that. Instructions decode through the
// table in NCIsa.

#pragma once

#include "nc_isa.h"

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/classes/weak_ref.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <cstdint>

namespace godot {

class NCCpu : public RefCounted {
	GDCLASS(NCCpu, RefCounted)

public:
	// NCIsa's enums, unscoped for the instruction switch (checked in nc_cpu.cpp).
	enum Op {
		BRK, NOP, LD, ST, ADD, ADC, SUB, SBC, AND, OR, XOR, CMP, INC, DEC,
		SHL, SHR, ROL, ROR, MOV, PUSH, POP, JMP, CALL, RET, RETI,
		JZ, JNZ, JC, JNC, JN, JNN, JR, CLC, SEC, CLI, SEI, WAIT, HALT,
	};
	enum Mode { IMP, IMM, ABS, ABX, ABY, IND, REL, JIN };
	enum Reg { R_NONE, R_A, R_X, R_Y, R_SP, R_F };

	static constexpr int RAM_END = 0x3000;
	static constexpr int VRAM_START = 0x2000;
	static constexpr int IO_PAGE = 0x30;
	static constexpr int ROM_START = 0x8000;
	static constexpr int VEC_VBLANK = 0xFFFA;
	static constexpr int VEC_RESET = 0xFFFC;
	static constexpr int VEC_BRK = 0xFFFE;
	static constexpr int IRQ_CYCLES = 7;

	NCCpu();

	void reset();
	int word(int addr) const;
	int read(int addr);
	void write(int addr, int value);
	int peek(int addr) const;
	void poke(int addr, int value);
	PackedByteArray memory() const;
	void load_memory(int at, const PackedByteArray &data);
	void clear_memory();
	int flags() const;
	void set_flags(int f);
	void push(int v);
	int pop();
	void interrupt(int vector);
	void vblank(bool irq);
	int64_t run(int64_t budget);
	void resume();
	void record_trace();
	void step();

	// Registers and state, as properties.
	int a = 0, x = 0, y = 0, sp = 0xFF, pc = 0;
	bool fn = false, fv = false, fi = true, fz = false, fc = false;
	bool waiting = false, halted = false, vram_dirty = true;
	int64_t cycles = 0;
	Ref<WeakRef> io;
	Dictionary breakpoints;
	Dictionary watches;
	String stop_reason;
	int watch_hit = -1;
	int trace_size = 0;
	PackedInt32Array trace;

	// Accessors for the properties above (bound in _bind_methods).
#define NC_ACCESSORS(ctype, name) \
	ctype _get_##name() const { return name; } \
	void _set_##name(ctype value) { name = value; }
	NC_ACCESSORS(int, a)
	NC_ACCESSORS(int, x)
	NC_ACCESSORS(int, y)
	NC_ACCESSORS(int, sp)
	NC_ACCESSORS(int, pc)
	NC_ACCESSORS(bool, fn)
	NC_ACCESSORS(bool, fv)
	NC_ACCESSORS(bool, fi)
	NC_ACCESSORS(bool, fz)
	NC_ACCESSORS(bool, fc)
	NC_ACCESSORS(bool, waiting)
	NC_ACCESSORS(bool, halted)
	NC_ACCESSORS(bool, vram_dirty)
	NC_ACCESSORS(int64_t, cycles)
	NC_ACCESSORS(Ref<WeakRef>, io)
	NC_ACCESSORS(Dictionary, breakpoints)
	NC_ACCESSORS(Dictionary, watches)
	NC_ACCESSORS(String, stop_reason)
	NC_ACCESSORS(int, watch_hit)
	NC_ACCESSORS(int, trace_size)
	NC_ACCESSORS(PackedInt32Array, trace)
#undef NC_ACCESSORS

protected:
	static void _bind_methods();

private:
	std::array<uint8_t, 0x10000> mem{};
	const NCIsa::Decoded &isa;
	bool resume_ = false;

	int reg(int r) const;
	void set_reg(int r, int v);
	void step_inline();
};

} // namespace godot
