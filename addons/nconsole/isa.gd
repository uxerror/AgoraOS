class_name NCIsa
extends RefCounted
## The N8 processor's instruction set. One table: the CPU decodes from it
## and the assembler encodes with it, so the two can't disagree. An
## opcode is the entry's index in the table.
##
## Registers: A (accumulator), X and Y (index), SP (stack pointer, the
## stack is page $01), PC, and the flags N, V, I, Z, C. Arithmetic and
## logic work on A. Carry is set by a borrow on subtraction, so after
## "cmp #n" jc means A < n and jnc means A >= n (unsigned).

enum Mode {
	IMP, ## no operand, or registers only
	IMM, ## #value
	ABS, ## address
	ABX, ## address,x
	ABY, ## address,y
	IND, ## [address],y: a 16-bit pointer at address, plus Y
	REL, ## branch target, a signed byte from the next instruction
	JIN, ## jmp [address]: jump through a 16-bit pointer
}
## Instruction size in bytes for each mode.
const SIZE: PackedByteArray = [1, 2, 3, 3, 3, 3, 2, 3]
## Base cycles for each mode.
const CYCLES: PackedByteArray = [2, 2, 4, 5, 5, 6, 3, 6]

enum Op {
	BRK, NOP, LD, ST, ADD, ADC, SUB, SBC, AND, OR, XOR, CMP, INC, DEC,
	SHL, SHR, ROL, ROR, MOV, PUSH, POP, JMP, CALL, RET, RETI,
	JZ, JNZ, JC, JNC, JN, JNN, JR, CLC, SEC, CLI, SEI, WAIT, HALT,
}
## Register operands. SP only appears in mov, F (the flags) in push/pop.
enum Reg { NONE, A, X, Y, SP, F }

const _ALU := ["add", "adc", "sub", "sbc", "and", "or", "xor", "cmp"]
const _OPERAND := [Mode.IMM, Mode.ABS, Mode.ABX, Mode.ABY, Mode.IND]

## Each entry: [mnemonic, registers, mode]. Registers are "" (none or A
## implied), "a", "x", "y", "f", or "dst,src" for mov.
static var TABLE: Array = _build()


static func _build() -> Array:
	var t: Array = []
	var add := func(name: String, regs: String, modes: Array) -> void:
		for m: int in modes:
			t.append([name, regs, m])
	add.call("brk", "", [Mode.IMP]) # $00: running into empty memory traps
	add.call("nop", "", [Mode.IMP])
	add.call("ld", "a", _OPERAND)
	add.call("ld", "x", [Mode.IMM, Mode.ABS, Mode.ABY])
	add.call("ld", "y", [Mode.IMM, Mode.ABS, Mode.ABX])
	add.call("st", "a", [Mode.ABS, Mode.ABX, Mode.ABY, Mode.IND])
	add.call("st", "x", [Mode.ABS, Mode.ABY])
	add.call("st", "y", [Mode.ABS, Mode.ABX])
	for name: String in _ALU:
		add.call(name, "", _OPERAND)
	add.call("cmp", "x", [Mode.IMM, Mode.ABS])
	add.call("cmp", "y", [Mode.IMM, Mode.ABS])
	for name in ["inc", "dec"]:
		for r in ["a", "x", "y"]:
			add.call(name, r, [Mode.IMP])
		add.call(name, "", [Mode.ABS, Mode.ABX])
	for name in ["shl", "shr", "rol", "ror"]:
		add.call(name, "a", [Mode.IMP])
		add.call(name, "", [Mode.ABS, Mode.ABX])
	for pair in ["a,x", "x,a", "a,y", "y,a", "x,sp", "sp,x"]:
		add.call("mov", pair, [Mode.IMP])
	for name in ["push", "pop"]:
		for r in ["a", "x", "y", "f"]:
			add.call(name, r, [Mode.IMP])
	add.call("jmp", "", [Mode.ABS, Mode.JIN])
	add.call("call", "", [Mode.ABS])
	for name in ["ret", "reti"]:
		add.call(name, "", [Mode.IMP])
	for name in ["jz", "jnz", "jc", "jnc", "jn", "jnn", "jr"]:
		add.call(name, "", [Mode.REL])
	for name in ["clc", "sec", "cli", "sei", "wait", "halt"]:
		add.call(name, "", [Mode.IMP])
	assert(t.size() <= 256)
	return t


static func op_of(name: String) -> int:
	return Op.keys().find(name.to_upper())


static func reg_of(name: String) -> int:
	return Reg.keys().find(name.to_upper()) if not name.is_empty() else Reg.NONE


## The opcode for [param name] with [param regs] in [param mode], or -1.
static func opcode(name: String, regs: String, mode: int) -> int:
	for k in TABLE.size():
		var e: Array = TABLE[k]
		if e[0] == name and e[1] == regs and e[2] == mode:
			return k
	return -1


## True if [param name] exists with registers [param regs] in any mode.
static func has_form(name: String, regs: String) -> bool:
	for e: Array in TABLE:
		if e[0] == name and e[1] == regs:
			return true
	return false


static func is_mnemonic(name: String) -> bool:
	for e: Array in TABLE:
		if e[0] == name:
			return true
	return false


## Text of the instruction at [param addr] in [param mem]: [text, size].
static func disassemble(mem: PackedByteArray, addr: int) -> Array:
	var op := mem[addr & 0xFFFF]
	if op >= TABLE.size():
		return [".byte $%02x" % op, 1]
	var e: Array = TABLE[op]
	var mode: int = e[2]
	var lo := mem[(addr + 1) & 0xFFFF]
	var word := lo | (mem[(addr + 2) & 0xFFFF] << 8)
	var operand := ""
	match mode:
		Mode.IMM: operand = "#$%02x" % lo
		Mode.ABS: operand = "$%04x" % word
		Mode.ABX: operand = "$%04x,x" % word
		Mode.ABY: operand = "$%04x,y" % word
		Mode.IND: operand = "[$%04x],y" % word
		Mode.JIN: operand = "[$%04x]" % word
		Mode.REL: operand = "$%04x" % ((addr + 2 + (lo - 256 if lo > 127 else lo)) & 0xFFFF)
	var parts: PackedStringArray = []
	var regs: String = e[1]
	if not regs.is_empty():
		parts.append(regs.replace(",", ", "))
	if not operand.is_empty():
		parts.append(operand)
	return [(e[0] + " " + ", ".join(parts)).strip_edges(), SIZE[mode]]
