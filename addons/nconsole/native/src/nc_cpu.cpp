#include "nc_cpu.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;

namespace {
constexpr int F_N = 0x80;
constexpr int F_V = 0x40;
constexpr int F_I = 0x04;
constexpr int F_Z = 0x02;
constexpr int F_C = 0x01;
} // namespace

NCCpuNative::NCCpuNative() {
	// Until set_isa: every opcode is brk, as undefined ones are.
	mode_cycles.fill(2);
}

void NCCpuNative::set_isa(const PackedByteArray &ops, const PackedByteArray &modes, const PackedByteArray &r1,
		const PackedByteArray &r2, const PackedByteArray &cycles_of_mode) {
	for (int k = 0; k < 256; k++) {
		op_of[k] = k < ops.size() ? ops[k] : BRK;
		mode_of[k] = k < modes.size() ? modes[k] : IMP;
		r1_of[k] = k < r1.size() ? r1[k] : R_NONE;
		r2_of[k] = k < r2.size() ? r2[k] : R_NONE;
	}
	for (int k = 0; k < 8 && k < cycles_of_mode.size(); k++) {
		mode_cycles[k] = cycles_of_mode[k];
	}
}

void NCCpuNative::reset() {
	a = x = y = 0;
	sp = 0xFF;
	fn = fv = fz = fc = false;
	fi = true;
	waiting = halted = false;
	pc = word(VEC_RESET);
}

int NCCpuNative::word(int addr) const {
	return mem[addr & 0xFFFF] | (mem[(addr + 1) & 0xFFFF] << 8);
}

int NCCpuNative::read(int addr) {
	if (addr < RAM_END || addr >= ROM_START) {
		return mem[addr];
	}
	if ((addr >> 8) == IO_PAGE && io.is_valid()) {
		Object *device = io->get_ref();
		if (device) {
			return device->call("read_io", addr & 0xFF);
		}
	}
	return 0;
}

void NCCpuNative::write(int addr, int value) {
	if (!watches.is_empty() && watches.has(addr)) {
		watch_hit = addr;
	}
	if (addr < RAM_END) {
		mem[addr] = value & 0xFF;
		if (addr >= VRAM_START) {
			vram_dirty = true;
		}
	} else if ((addr >> 8) == IO_PAGE && io.is_valid()) {
		Object *device = io->get_ref();
		if (device) {
			device->call("write_io", addr & 0xFF, value & 0xFF);
		}
	}
}

int NCCpuNative::peek(int addr) const {
	return mem[addr & 0xFFFF];
}

void NCCpuNative::poke(int addr, int value) {
	mem[addr & 0xFFFF] = value & 0xFF;
}

PackedByteArray NCCpuNative::memory() const {
	PackedByteArray out;
	out.resize(mem.size());
	std::memcpy(out.ptrw(), mem.data(), mem.size());
	return out;
}

void NCCpuNative::load_memory(int at, const PackedByteArray &data) {
	if (at < 0 || at >= (int)mem.size()) {
		return;
	}
	int64_t n = data.size();
	if (at + n > (int64_t)mem.size()) {
		n = mem.size() - at;
	}
	std::memcpy(mem.data() + at, data.ptr(), n);
}

void NCCpuNative::clear_memory() {
	mem.fill(0);
}

int NCCpuNative::flags() const {
	return (fn ? F_N : 0) | (fv ? F_V : 0) | (fi ? F_I : 0) | (fz ? F_Z : 0) | (fc ? F_C : 0);
}

void NCCpuNative::set_flags(int f) {
	fn = f & F_N;
	fv = f & F_V;
	fi = f & F_I;
	fz = f & F_Z;
	fc = f & F_C;
}

void NCCpuNative::push(int v) {
	mem[0x100 | sp] = v & 0xFF;
	sp = (sp - 1) & 0xFF;
}

int NCCpuNative::pop() {
	sp = (sp + 1) & 0xFF;
	return mem[0x100 | sp];
}

void NCCpuNative::interrupt(int vector) {
	push(pc >> 8);
	push(pc & 0xFF);
	push(flags());
	fi = true;
	pc = word(vector);
	cycles += IRQ_CYCLES;
}

void NCCpuNative::vblank(bool irq) {
	waiting = false;
	if (irq && !fi && !halted) {
		interrupt(VEC_VBLANK);
	}
}

int64_t NCCpuNative::run(int64_t budget) {
	const int64_t start = cycles;
	const int64_t end = cycles + budget;
	stop_reason = "";
	if (breakpoints.is_empty() && watches.is_empty() && trace_size == 0) {
		while (cycles < end && !waiting && !halted) {
			step_inline();
		}
		return cycles - start;
	}
	// The debugging loop: the same, with checks.
	while (cycles < end && !waiting && !halted) {
		if (!resume_ && breakpoints.has(pc)) {
			if (breakpoints[pc].get_type() == Variant::STRING) {
				breakpoints.erase(pc);
			}
			stop_reason = "break";
			break;
		}
		resume_ = false;
		record_trace();
		watch_hit = -1;
		step_inline();
		if (watch_hit >= 0) {
			stop_reason = "watch";
			break;
		}
	}
	return cycles - start;
}

void NCCpuNative::resume() {
	resume_ = true;
}

void NCCpuNative::record_trace() {
	if (trace_size > 0) {
		trace.push_back(pc);
		if (trace.size() > trace_size) {
			trace = trace.slice(trace.size() - trace_size);
		}
	}
}

int NCCpuNative::reg(int r) const {
	switch (r) {
		case R_A: return a;
		case R_X: return x;
		case R_Y: return y;
		case R_SP: return sp;
	}
	return flags();
}

void NCCpuNative::set_reg(int r, int v) {
	switch (r) {
		case R_A: a = v; break;
		case R_X: x = v; break;
		case R_Y: y = v; break;
		case R_SP: sp = v; break;
		case R_F: set_flags(v); break;
	}
}

void NCCpuNative::step() {
	step_inline();
}

// One instruction: a line-by-line port of NCCpu.step in cpu.gd.
inline void NCCpuNative::step_inline() {
	const int opc = mem[pc];
	const int mode = mode_of[opc];
	const int k = op_of[opc];
	int ea = 0;
	int imm = 0;
	switch (mode) {
		case IMP:
			pc = (pc + 1) & 0xFFFF;
			break;
		case IMM:
			imm = mem[(pc + 1) & 0xFFFF];
			pc = (pc + 2) & 0xFFFF;
			break;
		case REL: {
			const int off = mem[(pc + 1) & 0xFFFF];
			pc = (pc + 2) & 0xFFFF;
			ea = (pc + (off > 127 ? off - 256 : off)) & 0xFFFF;
			break;
		}
		default:
			ea = mem[(pc + 1) & 0xFFFF] | (mem[(pc + 2) & 0xFFFF] << 8);
			pc = (pc + 3) & 0xFFFF;
			switch (mode) {
				case ABX: ea = (ea + x) & 0xFFFF; break;
				case ABY: ea = (ea + y) & 0xFFFF; break;
				case IND: ea = (word(ea) + y) & 0xFFFF; break;
				case JIN: ea = word(ea); break;
			}
	}
	cycles += mode_cycles[mode];
	switch (k) {
		case LD: {
			const int v = mode == IMM ? imm : read(ea);
			set_reg(r1_of[opc], v);
			fz = v == 0;
			fn = v >= 0x80;
			break;
		}
		case ST:
			write(ea, reg(r1_of[opc]));
			break;
		case ADD:
		case ADC: {
			const int v = mode == IMM ? imm : read(ea);
			int r = a + v + (k == ADC && fc ? 1 : 0);
			fc = r > 0xFF;
			r &= 0xFF;
			fv = ((a ^ r) & (v ^ r) & 0x80) != 0;
			a = r;
			fz = r == 0;
			fn = r >= 0x80;
			break;
		}
		case SUB:
		case SBC: {
			const int v = mode == IMM ? imm : read(ea);
			int r = a - v - (k == SBC && fc ? 1 : 0);
			fc = r < 0;
			r &= 0xFF;
			fv = ((a ^ v) & (a ^ r) & 0x80) != 0;
			a = r;
			fz = r == 0;
			fn = r >= 0x80;
			break;
		}
		case AND:
		case OR:
		case XOR: {
			const int v = mode == IMM ? imm : read(ea);
			a = k == AND ? (a & v) : k == OR ? (a | v) : (a ^ v);
			fz = a == 0;
			fn = a >= 0x80;
			break;
		}
		case CMP: {
			const int v = mode == IMM ? imm : read(ea);
			const int r1 = r1_of[opc];
			const int r = (r1 == R_NONE ? a : reg(r1)) - v;
			fc = r < 0;
			fz = r == 0;
			fn = (r & 0x80) != 0;
			break;
		}
		case INC:
		case DEC:
		case SHL:
		case SHR:
		case ROL:
		case ROR: {
			const int r1 = r1_of[opc];
			int v = r1 != R_NONE ? reg(r1) : read(ea);
			switch (k) {
				case INC: v = (v + 1) & 0xFF; break;
				case DEC: v = (v - 1) & 0xFF; break;
				case SHL:
					fc = v >= 0x80;
					v = (v << 1) & 0xFF;
					break;
				case SHR:
					fc = (v & 1) == 1;
					v >>= 1;
					break;
				case ROL: {
					const int c = fc ? 1 : 0;
					fc = v >= 0x80;
					v = ((v << 1) | c) & 0xFF;
					break;
				}
				case ROR: {
					const int c = fc ? 0x80 : 0;
					fc = (v & 1) == 1;
					v = (v >> 1) | c;
					break;
				}
			}
			if (r1 != R_NONE) {
				set_reg(r1, v);
			} else {
				write(ea, v);
				cycles += 2; // read, modify, write
			}
			fz = v == 0;
			fn = v >= 0x80;
			break;
		}
		case MOV: {
			const int v = reg(r2_of[opc]);
			set_reg(r1_of[opc], v);
			if (r1_of[opc] != R_SP) {
				fz = v == 0;
				fn = v >= 0x80;
			}
			break;
		}
		case PUSH:
			push(reg(r1_of[opc]));
			cycles += 1;
			break;
		case POP: {
			const int v = pop();
			set_reg(r1_of[opc], v);
			if (r1_of[opc] != R_F) {
				fz = v == 0;
				fn = v >= 0x80;
			}
			cycles += 2;
			break;
		}
		case JMP:
			pc = ea;
			cycles -= 1;
			break;
		case CALL:
			push(pc >> 8);
			push(pc & 0xFF);
			pc = ea;
			cycles += 2;
			break;
		case RET: {
			const int lo = pop(); // low byte first: C++ doesn't order operands
			const int hi = pop();
			pc = lo | (hi << 8);
			cycles += 4;
			break;
		}
		case RETI: {
			set_flags(pop());
			const int lo = pop();
			const int hi = pop();
			pc = lo | (hi << 8);
			cycles += 4;
			break;
		}
		case JZ:
		case JNZ:
		case JC:
		case JNC:
		case JN:
		case JNN:
		case JR: {
			bool taken;
			switch (k) {
				case JZ: taken = fz; break;
				case JNZ: taken = !fz; break;
				case JC: taken = fc; break;
				case JNC: taken = !fc; break;
				case JN: taken = fn; break;
				case JNN: taken = !fn; break;
				default: taken = true;
			}
			if (taken) {
				pc = ea;
				cycles += 1;
			}
			break;
		}
		case CLC: fc = false; break;
		case SEC: fc = true; break;
		case CLI: fi = false; break;
		case SEI: fi = true; break;
		case NOP: break;
		case WAIT: waiting = true; break;
		case HALT: halted = true; break;
		case BRK: interrupt(VEC_BRK); break;
	}
}

// --- bindings -----------------------------------------------------------------

#define NC_PROPERTY(type, name)                                                          \
	ClassDB::bind_method(D_METHOD("_get_" #name), &NCCpuNative::_get_##name);            \
	ClassDB::bind_method(D_METHOD("_set_" #name, "value"), &NCCpuNative::_set_##name); \
	ADD_PROPERTY(PropertyInfo(Variant::type, #name), "_set_" #name, "_get_" #name);

void NCCpuNative::_bind_methods() {
	ClassDB::bind_method(D_METHOD("set_isa", "ops", "modes", "r1", "r2", "cycles"), &NCCpuNative::set_isa);
	ClassDB::bind_method(D_METHOD("reset"), &NCCpuNative::reset);
	ClassDB::bind_method(D_METHOD("word", "addr"), &NCCpuNative::word);
	ClassDB::bind_method(D_METHOD("read", "addr"), &NCCpuNative::read);
	ClassDB::bind_method(D_METHOD("write", "addr", "value"), &NCCpuNative::write);
	ClassDB::bind_method(D_METHOD("peek", "addr"), &NCCpuNative::peek);
	ClassDB::bind_method(D_METHOD("poke", "addr", "value"), &NCCpuNative::poke);
	ClassDB::bind_method(D_METHOD("memory"), &NCCpuNative::memory);
	ClassDB::bind_method(D_METHOD("load_memory", "at", "data"), &NCCpuNative::load_memory);
	ClassDB::bind_method(D_METHOD("clear_memory"), &NCCpuNative::clear_memory);
	ClassDB::bind_method(D_METHOD("flags"), &NCCpuNative::flags);
	ClassDB::bind_method(D_METHOD("set_flags", "f"), &NCCpuNative::set_flags);
	ClassDB::bind_method(D_METHOD("push", "v"), &NCCpuNative::push);
	ClassDB::bind_method(D_METHOD("pop"), &NCCpuNative::pop);
	ClassDB::bind_method(D_METHOD("interrupt", "vector"), &NCCpuNative::interrupt);
	ClassDB::bind_method(D_METHOD("vblank", "irq"), &NCCpuNative::vblank);
	ClassDB::bind_method(D_METHOD("run", "budget"), &NCCpuNative::run);
	ClassDB::bind_method(D_METHOD("resume"), &NCCpuNative::resume);
	ClassDB::bind_method(D_METHOD("record_trace"), &NCCpuNative::record_trace);
	ClassDB::bind_method(D_METHOD("step"), &NCCpuNative::step);

	NC_PROPERTY(INT, a)
	NC_PROPERTY(INT, x)
	NC_PROPERTY(INT, y)
	NC_PROPERTY(INT, sp)
	NC_PROPERTY(INT, pc)
	NC_PROPERTY(BOOL, fn)
	NC_PROPERTY(BOOL, fv)
	NC_PROPERTY(BOOL, fi)
	NC_PROPERTY(BOOL, fz)
	NC_PROPERTY(BOOL, fc)
	NC_PROPERTY(BOOL, waiting)
	NC_PROPERTY(BOOL, halted)
	NC_PROPERTY(BOOL, vram_dirty)
	NC_PROPERTY(INT, cycles)
	NC_PROPERTY(OBJECT, io)
	NC_PROPERTY(DICTIONARY, breakpoints)
	NC_PROPERTY(DICTIONARY, watches)
	NC_PROPERTY(STRING, stop_reason)
	NC_PROPERTY(INT, watch_hit)
	NC_PROPERTY(INT, trace_size)
	NC_PROPERTY(PACKED_INT32_ARRAY, trace)
}
