// The N8 processor's instruction set. One table: the CPU decodes from it
// and the assembler encodes with it, so the two can't disagree. An opcode
// is the entry's index in the table.
//
// Registers: A (accumulator), X and Y (index), SP (stack pointer, the
// stack is page $01), PC, and the flags N, V, I, Z, C. Arithmetic and logic
// work on A. Carry is set by a borrow on subtraction, so after "cmp #n"
// jc means A < n and jnc means A >= n (unsigned).

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include <array>
#include <cstdint>
#include <vector>

namespace godot {

class NCIsa : public RefCounted {
	GDCLASS(NCIsa, RefCounted)

public:
	enum Mode {
		IMP, // no operand, or registers only
		IMM, // #value
		ABS, // address
		ABX, // address,x
		ABY, // address,y
		IND, // [address],y: a 16-bit pointer at address, plus Y
		REL, // branch target, a signed byte from the next instruction
		JIN, // jmp [address]: jump through a 16-bit pointer
	};
	enum Op {
		BRK, NOP, LD, ST, ADD, ADC, SUB, SBC, AND, OR, XOR, CMP, INC, DEC,
		SHL, SHR, ROL, ROR, MOV, PUSH, POP, JMP, CALL, RET, RETI,
		JZ, JNZ, JC, JNC, JN, JNN, JR, CLC, SEC, CLI, SEI, WAIT, HALT,
	};
	enum Reg { NONE, A, X, Y, SP, F };

	// Instruction size in bytes and base cycles, by mode.
	static constexpr uint8_t MODE_SIZE[8] = { 1, 2, 3, 3, 3, 3, 2, 3 };
	static constexpr uint8_t MODE_CYCLES[8] = { 2, 2, 4, 5, 5, 6, 3, 6 };

	struct Entry {
		const char *name;
		const char *regs; // "", "a", "x", "y", "f", or "dst,src" for mov
		Mode mode;
	};

	// Decoded, for the CPU: undefined opcodes act as brk.
	struct Decoded {
		std::array<uint8_t, 256> op{}, mode{}, r1{}, r2{};
	};

	static const std::vector<Entry> &entries();
	static const Decoded &decoded();

	// For GDScript.
	static Array table();
	static int opcode(const String &name, const String &regs, int mode);
	static bool has_form(const String &name, const String &regs);
	static bool is_mnemonic(const String &name);
	static String mnemonic(int opcode);
	static String mode_name(int mode);
	static int mode_size(int mode);
	static int mode_cycles(int mode);
	static Array disassemble(const PackedByteArray &mem, int addr);

protected:
	static void _bind_methods();
};

} // namespace godot

VARIANT_ENUM_CAST(NCIsa::Mode);
VARIANT_ENUM_CAST(NCIsa::Op);
VARIANT_ENUM_CAST(NCIsa::Reg);
