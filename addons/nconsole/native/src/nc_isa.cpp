#include "nc_isa.h"

#include <godot_cpp/core/class_db.hpp>

#include <cstring>

using namespace godot;

namespace {

const char *OP_NAMES[] = {
	"brk", "nop", "ld", "st", "add", "adc", "sub", "sbc", "and", "or", "xor", "cmp", "inc", "dec",
	"shl", "shr", "rol", "ror", "mov", "push", "pop", "jmp", "call", "ret", "reti",
	"jz", "jnz", "jc", "jnc", "jn", "jnn", "jr", "clc", "sec", "cli", "sei", "wait", "halt",
};
const char *MODE_NAMES[] = { "imp", "imm", "abs", "abx", "aby", "ind", "rel", "jin" };

std::vector<NCIsa::Entry> build() {
	using M = NCIsa::Mode;
	std::vector<NCIsa::Entry> t;
	auto add = [&](const char *name, const char *regs, std::initializer_list<M> modes) {
		for (M m : modes) {
			t.push_back({ name, regs, m });
		}
	};
	const std::initializer_list<M> operand = { M::IMM, M::ABS, M::ABX, M::ABY, M::IND };
	add("brk", "", { M::IMP }); // $00: running into empty memory traps
	add("nop", "", { M::IMP });
	add("ld", "a", operand);
	add("ld", "x", { M::IMM, M::ABS, M::ABY });
	add("ld", "y", { M::IMM, M::ABS, M::ABX });
	add("st", "a", { M::ABS, M::ABX, M::ABY, M::IND });
	add("st", "x", { M::ABS, M::ABY });
	add("st", "y", { M::ABS, M::ABX });
	for (const char *name : { "add", "adc", "sub", "sbc", "and", "or", "xor", "cmp" }) {
		add(name, "", operand);
	}
	add("cmp", "x", { M::IMM, M::ABS });
	add("cmp", "y", { M::IMM, M::ABS });
	for (const char *name : { "inc", "dec" }) {
		for (const char *r : { "a", "x", "y" }) {
			add(name, r, { M::IMP });
		}
		add(name, "", { M::ABS, M::ABX });
	}
	for (const char *name : { "shl", "shr", "rol", "ror" }) {
		add(name, "a", { M::IMP });
		add(name, "", { M::ABS, M::ABX });
	}
	for (const char *pair : { "a,x", "x,a", "a,y", "y,a", "x,sp", "sp,x" }) {
		add("mov", pair, { M::IMP });
	}
	for (const char *name : { "push", "pop" }) {
		for (const char *r : { "a", "x", "y", "f" }) {
			add(name, r, { M::IMP });
		}
	}
	add("jmp", "", { M::ABS, M::JIN });
	add("call", "", { M::ABS });
	add("ret", "", { M::IMP });
	add("reti", "", { M::IMP });
	for (const char *name : { "jz", "jnz", "jc", "jnc", "jn", "jnn", "jr" }) {
		add(name, "", { M::REL });
	}
	for (const char *name : { "clc", "sec", "cli", "sei", "wait", "halt" }) {
		add(name, "", { M::IMP });
	}
	return t;
}

int op_index(const char *name) {
	for (int k = 0; k < (int)(sizeof(OP_NAMES) / sizeof(*OP_NAMES)); k++) {
		if (std::strcmp(OP_NAMES[k], name) == 0) {
			return k;
		}
	}
	return NCIsa::BRK;
}

int reg_index(const char *name, size_t len) {
	static const char *regs[] = { "", "a", "x", "y", "sp", "f" };
	for (int k = 0; k < 6; k++) {
		if (std::strlen(regs[k]) == len && std::strncmp(regs[k], name, len) == 0) {
			return k;
		}
	}
	return NCIsa::NONE;
}

String hex(int value, int digits) {
	return String::num_int64(value, 16).pad_zeros(digits);
}

} // namespace

const std::vector<NCIsa::Entry> &NCIsa::entries() {
	static const std::vector<Entry> table = build();
	return table;
}

const NCIsa::Decoded &NCIsa::decoded() {
	static const Decoded d = [] {
		Decoded out;
		const auto &t = entries();
		for (int k = 0; k < 256; k++) {
			if (k >= (int)t.size()) {
				out.op[k] = BRK;
				out.mode[k] = IMP;
				continue;
			}
			const Entry &e = t[k];
			out.op[k] = op_index(e.name);
			out.mode[k] = e.mode;
			const char *comma = std::strchr(e.regs, ',');
			if (comma) {
				out.r1[k] = reg_index(e.regs, comma - e.regs);
				out.r2[k] = reg_index(comma + 1, std::strlen(comma + 1));
			} else {
				out.r1[k] = reg_index(e.regs, std::strlen(e.regs));
			}
		}
		return out;
	}();
	return d;
}

Array NCIsa::table() {
	Array out;
	for (const Entry &e : entries()) {
		Array row;
		row.push_back(String(e.name));
		row.push_back(String(e.regs));
		row.push_back((int)e.mode);
		out.push_back(row);
	}
	return out;
}

int NCIsa::opcode(const String &name, const String &regs, int mode) {
	const auto &t = entries();
	for (int k = 0; k < (int)t.size(); k++) {
		if (name == t[k].name && regs == t[k].regs && mode == t[k].mode) {
			return k;
		}
	}
	return -1;
}

bool NCIsa::has_form(const String &name, const String &regs) {
	for (const Entry &e : entries()) {
		if (name == e.name && regs == e.regs) {
			return true;
		}
	}
	return false;
}

bool NCIsa::is_mnemonic(const String &name) {
	for (const Entry &e : entries()) {
		if (name == e.name) {
			return true;
		}
	}
	return false;
}

String NCIsa::mnemonic(int opcode) {
	const auto &t = entries();
	return opcode >= 0 && opcode < (int)t.size() ? String(t[opcode].name) : String();
}

String NCIsa::mode_name(int mode) {
	return mode >= 0 && mode < 8 ? String(MODE_NAMES[mode]) : String();
}

int NCIsa::mode_size(int mode) {
	return mode >= 0 && mode < 8 ? MODE_SIZE[mode] : 1;
}

int NCIsa::mode_cycles(int mode) {
	return mode >= 0 && mode < 8 ? MODE_CYCLES[mode] : 2;
}

// [text, size] of the instruction at addr.
Array NCIsa::disassemble(const PackedByteArray &mem, int addr) {
	auto at = [&](int a) -> int {
		a &= 0xFFFF;
		return a < mem.size() ? mem[a] : 0;
	};
	const int op = at(addr);
	const auto &t = entries();
	Array out;
	if (op >= (int)t.size()) {
		out.push_back("." + String("byte $") + hex(op, 2));
		out.push_back(1);
		return out;
	}
	const Entry &e = t[op];
	const int lo = at(addr + 1);
	const int word = lo | (at(addr + 2) << 8);
	String operand;
	switch (e.mode) {
		case IMM: operand = "#$" + hex(lo, 2); break;
		case ABS: operand = "$" + hex(word, 4); break;
		case ABX: operand = "$" + hex(word, 4) + ",x"; break;
		case ABY: operand = "$" + hex(word, 4) + ",y"; break;
		case IND: operand = "[$" + hex(word, 4) + "],y"; break;
		case JIN: operand = "[$" + hex(word, 4) + "]"; break;
		case REL: operand = "$" + hex((addr + 2 + (lo > 127 ? lo - 256 : lo)) & 0xFFFF, 4); break;
		default: break;
	}
	PackedStringArray parts;
	String regs = e.regs;
	if (!regs.is_empty()) {
		parts.push_back(regs.replace(",", ", "));
	}
	if (!operand.is_empty()) {
		parts.push_back(operand);
	}
	out.push_back((String(e.name) + " " + String(", ").join(parts)).strip_edges());
	out.push_back(MODE_SIZE[e.mode]);
	return out;
}

void NCIsa::_bind_methods() {
	ClassDB::bind_static_method("NCIsa", D_METHOD("table"), &NCIsa::table);
	ClassDB::bind_static_method("NCIsa", D_METHOD("opcode", "name", "regs", "mode"), &NCIsa::opcode);
	ClassDB::bind_static_method("NCIsa", D_METHOD("has_form", "name", "regs"), &NCIsa::has_form);
	ClassDB::bind_static_method("NCIsa", D_METHOD("is_mnemonic", "name"), &NCIsa::is_mnemonic);
	ClassDB::bind_static_method("NCIsa", D_METHOD("mnemonic", "opcode"), &NCIsa::mnemonic);
	ClassDB::bind_static_method("NCIsa", D_METHOD("mode_name", "mode"), &NCIsa::mode_name);
	ClassDB::bind_static_method("NCIsa", D_METHOD("mode_size", "mode"), &NCIsa::mode_size);
	ClassDB::bind_static_method("NCIsa", D_METHOD("mode_cycles", "mode"), &NCIsa::mode_cycles);
	ClassDB::bind_static_method("NCIsa", D_METHOD("disassemble", "mem", "addr"), &NCIsa::disassemble);

	BIND_ENUM_CONSTANT(IMP);
	BIND_ENUM_CONSTANT(IMM);
	BIND_ENUM_CONSTANT(ABS);
	BIND_ENUM_CONSTANT(ABX);
	BIND_ENUM_CONSTANT(ABY);
	BIND_ENUM_CONSTANT(IND);
	BIND_ENUM_CONSTANT(REL);
	BIND_ENUM_CONSTANT(JIN);

	BIND_ENUM_CONSTANT(BRK);
	BIND_ENUM_CONSTANT(NOP);
	BIND_ENUM_CONSTANT(LD);
	BIND_ENUM_CONSTANT(ST);
	BIND_ENUM_CONSTANT(ADD);
	BIND_ENUM_CONSTANT(ADC);
	BIND_ENUM_CONSTANT(SUB);
	BIND_ENUM_CONSTANT(SBC);
	BIND_ENUM_CONSTANT(AND);
	BIND_ENUM_CONSTANT(OR);
	BIND_ENUM_CONSTANT(XOR);
	BIND_ENUM_CONSTANT(CMP);
	BIND_ENUM_CONSTANT(INC);
	BIND_ENUM_CONSTANT(DEC);
	BIND_ENUM_CONSTANT(SHL);
	BIND_ENUM_CONSTANT(SHR);
	BIND_ENUM_CONSTANT(ROL);
	BIND_ENUM_CONSTANT(ROR);
	BIND_ENUM_CONSTANT(MOV);
	BIND_ENUM_CONSTANT(PUSH);
	BIND_ENUM_CONSTANT(POP);
	BIND_ENUM_CONSTANT(JMP);
	BIND_ENUM_CONSTANT(CALL);
	BIND_ENUM_CONSTANT(RET);
	BIND_ENUM_CONSTANT(RETI);
	BIND_ENUM_CONSTANT(JZ);
	BIND_ENUM_CONSTANT(JNZ);
	BIND_ENUM_CONSTANT(JC);
	BIND_ENUM_CONSTANT(JNC);
	BIND_ENUM_CONSTANT(JN);
	BIND_ENUM_CONSTANT(JNN);
	BIND_ENUM_CONSTANT(JR);
	BIND_ENUM_CONSTANT(CLC);
	BIND_ENUM_CONSTANT(SEC);
	BIND_ENUM_CONSTANT(CLI);
	BIND_ENUM_CONSTANT(SEI);
	BIND_ENUM_CONSTANT(WAIT);
	BIND_ENUM_CONSTANT(HALT);

	BIND_ENUM_CONSTANT(NONE);
	BIND_ENUM_CONSTANT(A);
	BIND_ENUM_CONSTANT(X);
	BIND_ENUM_CONSTANT(Y);
	BIND_ENUM_CONSTANT(SP);
	BIND_ENUM_CONSTANT(F);
}
