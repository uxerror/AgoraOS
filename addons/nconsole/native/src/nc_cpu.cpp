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

// The two copies of the enums must agree.
static_assert((int)NCCpu::HALT == (int)NCIsa::HALT && (int)NCCpu::JIN == (int)NCIsa::JIN && (int)NCCpu::R_F == (int)NCIsa::F);

NCCpu::NCCpu() :
		isa(NCIsa::decoded()) {
}

void NCCpu::reset() {
	a = x = y = 0;
	sp = 0xFF;
	fn = fv = fz = fc = false;
	fi = true;
	waiting = halted = false;
	pc = word(VEC_RESET);
}

int NCCpu::word(int addr) const {
	return mem[addr & 0xFFFF] | (mem[(addr + 1) & 0xFFFF] << 8);
}

int NCCpu::read(int addr) {
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

void NCCpu::write(int addr, int value) {
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

int NCCpu::peek(int addr) const {
	return mem[addr & 0xFFFF];
}

void NCCpu::poke(int addr, int value) {
	mem[addr & 0xFFFF] = value & 0xFF;
}

PackedByteArray NCCpu::memory() const {
	PackedByteArray out;
	out.resize(mem.size());
	std::memcpy(out.ptrw(), mem.data(), mem.size());
	return out;
}

void NCCpu::load_memory(int at, const PackedByteArray &data) {
	if (at < 0 || at >= (int)mem.size()) {
		return;
	}
	int64_t n = data.size();
	if (at + n > (int64_t)mem.size()) {
		n = mem.size() - at;
	}
	std::memcpy(mem.data() + at, data.ptr(), n);
}

void NCCpu::clear_memory() {
	mem.fill(0);
}

int NCCpu::flags() const {
	return (fn ? F_N : 0) | (fv ? F_V : 0) | (fi ? F_I : 0) | (fz ? F_Z : 0) | (fc ? F_C : 0);
}

void NCCpu::set_flags(int f) {
	fn = f & F_N;
	fv = f & F_V;
	fi = f & F_I;
	fz = f & F_Z;
	fc = f & F_C;
}

void NCCpu::push(int v) {
	mem[0x100 | sp] = v & 0xFF;
	sp = (sp - 1) & 0xFF;
}

int NCCpu::pop() {
	sp = (sp + 1) & 0xFF;
	return mem[0x100 | sp];
}

void NCCpu::interrupt(int vector) {
	push(pc >> 8);
	push(pc & 0xFF);
	push(flags());
	fi = true;
	pc = word(vector);
	cycles += IRQ_CYCLES;
}

void NCCpu::vblank(bool irq) {
	waiting = false;
	if (irq && !fi && !halted) {
		interrupt(VEC_VBLANK);
	}
}

int64_t NCCpu::run(int64_t budget) {
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

void NCCpu::resume() {
	resume_ = true;
}

void NCCpu::record_trace() {
	if (trace_size > 0) {
		trace.push_back(pc);
		if (trace.size() > trace_size) {
			trace = trace.slice(trace.size() - trace_size);
		}
	}
}

int NCCpu::reg(int r) const {
	switch (r) {
		case R_A: return a;
		case R_X: return x;
		case R_Y: return y;
		case R_SP: return sp;
	}
	return flags();
}

void NCCpu::set_reg(int r, int v) {
	switch (r) {
		case R_A: a = v; break;
		case R_X: x = v; break;
		case R_Y: y = v; break;
		case R_SP: sp = v; break;
		case R_F: set_flags(v); break;
	}
}

void NCCpu::step() {
	step_inline();
}

// One instruction: a line-by-line port of NCCpu.step in cpu.gd.
inline void NCCpu::step_inline() {
	const int opc = mem[pc];
	const int mode = isa.mode[opc];
	const int k = isa.op[opc];
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
	cycles += NCIsa::MODE_CYCLES[mode];
	switch (k) {
		case LD: {
			const int v = mode == IMM ? imm : read(ea);
			set_reg(isa.r1[opc], v);
			fz = v == 0;
			fn = v >= 0x80;
			break;
		}
		case ST:
			write(ea, reg(isa.r1[opc]));
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
			const int r1 = isa.r1[opc];
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
			const int r1 = isa.r1[opc];
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
			const int v = reg(isa.r2[opc]);
			set_reg(isa.r1[opc], v);
			if (isa.r1[opc] != R_SP) {
				fz = v == 0;
				fn = v >= 0x80;
			}
			break;
		}
		case PUSH:
			push(reg(isa.r1[opc]));
			cycles += 1;
			break;
		case POP: {
			const int v = pop();
			set_reg(isa.r1[opc], v);
			if (isa.r1[opc] != R_F) {
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
	ClassDB::bind_method(D_METHOD("_get_" #name), &NCCpu::_get_##name);            \
	ClassDB::bind_method(D_METHOD("_set_" #name, "value"), &NCCpu::_set_##name); \
	ADD_PROPERTY(PropertyInfo(Variant::type, #name), "_set_" #name, "_get_" #name);

void NCCpu::_bind_methods() {
	ClassDB::bind_method(D_METHOD("reset"), &NCCpu::reset);
	ClassDB::bind_method(D_METHOD("word", "addr"), &NCCpu::word);
	ClassDB::bind_method(D_METHOD("read", "addr"), &NCCpu::read);
	ClassDB::bind_method(D_METHOD("write", "addr", "value"), &NCCpu::write);
	ClassDB::bind_method(D_METHOD("peek", "addr"), &NCCpu::peek);
	ClassDB::bind_method(D_METHOD("poke", "addr", "value"), &NCCpu::poke);
	ClassDB::bind_method(D_METHOD("memory"), &NCCpu::memory);
	ClassDB::bind_method(D_METHOD("load_memory", "at", "data"), &NCCpu::load_memory);
	ClassDB::bind_method(D_METHOD("clear_memory"), &NCCpu::clear_memory);
	ClassDB::bind_method(D_METHOD("flags"), &NCCpu::flags);
	ClassDB::bind_method(D_METHOD("set_flags", "f"), &NCCpu::set_flags);
	ClassDB::bind_method(D_METHOD("push", "v"), &NCCpu::push);
	ClassDB::bind_method(D_METHOD("pop"), &NCCpu::pop);
	ClassDB::bind_method(D_METHOD("interrupt", "vector"), &NCCpu::interrupt);
	ClassDB::bind_method(D_METHOD("vblank", "irq"), &NCCpu::vblank);
	ClassDB::bind_method(D_METHOD("run", "budget"), &NCCpu::run);
	ClassDB::bind_method(D_METHOD("resume"), &NCCpu::resume);
	ClassDB::bind_method(D_METHOD("record_trace"), &NCCpu::record_trace);
	ClassDB::bind_method(D_METHOD("step"), &NCCpu::step);

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

	BIND_CONSTANT(RAM_END);
	BIND_CONSTANT(VRAM_START);
	BIND_CONSTANT(IO_PAGE);
	BIND_CONSTANT(ROM_START);
	BIND_CONSTANT(VEC_VBLANK);
	BIND_CONSTANT(VEC_RESET);
	BIND_CONSTANT(VEC_BRK);
}
