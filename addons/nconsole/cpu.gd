class_name NCCpu
extends RefCounted
## The N8 processor and its bus. Memory map:
##
##   $0000-$00FF  zero page (plain RAM, a good place for pointers)
##   $0100-$01FF  stack
##   $0200-$1FFF  RAM
##   $2000-$2FFF  video RAM (see [NCVideo]); plain RAM to the CPU
##   $3000-$30FF  I/O registers, handled by [member io]
##   $8000-$FFFF  cartridge ROM; writes are ignored
##
## Vectors at the top of ROM: $FFFA vblank, $FFFC reset, $FFFE brk.
## Interrupts push PC (high, then low) and the flags, set I, and jump
## through their vector; reti undoes that.

const RAM_END := 0x3000
const VRAM_START := 0x2000
const IO_PAGE := 0x30
const ROM_START := 0x8000
const VEC_VBLANK := 0xFFFA
const VEC_RESET := 0xFFFC
const VEC_BRK := 0xFFFE
## Cycles to enter an interrupt.
const IRQ_CYCLES := 7

const F_N := 0x80
const F_V := 0x40
const F_I := 0x04
const F_Z := 0x02
const F_C := 0x01

var mem := PackedByteArray()
var a := 0
var x := 0
var y := 0
var sp := 0xFF
var pc := 0
var fn := false
var fv := false
var fi := true
var fz := false
var fc := false
## Stopped by wait until the next vblank.
var waiting := false
## Stopped by halt until a reset.
var halted := false
## Cycles run since power-on.
var cycles := 0

# --- debugging ---
## Addresses where [method run] stops before executing (value: true, or
## "temp" for a one-shot stop that removes itself).
var breakpoints := {}
## Addresses whose writes stop [method run] after the instruction.
var watches := {}
## Why the last [method run] stopped early: "", "break" or "watch".
var stop_reason := ""
## The address of the write that stopped it.
var watch_hit := -1
## Executed addresses kept for the trace, oldest first (0 = off).
var trace_size := 0
var trace := PackedInt32Array()
# Lets the instruction at a breakpoint run when execution continues.
var _resume := false
## Set by any write to video RAM; the video clears it after drawing.
var vram_dirty := true
## Gets read_io(reg) -> int and write_io(reg, value) for $30xx. A weak
## reference: the device owns the CPU.
var io: WeakRef

# Decoded instruction table, indexed by opcode.
static var _op := PackedByteArray()
static var _mode := PackedByteArray()
static var _r1 := PackedByteArray()
static var _r2 := PackedByteArray()


func _init() -> void:
	mem.resize(0x10000)
	if _op.is_empty():
		_decode_table()


static func _decode_table() -> void:
	for k in 256:
		if k < NCIsa.TABLE.size():
			var e: Array = NCIsa.TABLE[k]
			var regs: PackedStringArray = (e[1] as String).split(",")
			_op.append(NCIsa.op_of(e[0]))
			_mode.append(e[2])
			_r1.append(NCIsa.reg_of(regs[0]))
			_r2.append(NCIsa.reg_of(regs[1]) if regs.size() > 1 else NCIsa.Reg.NONE)
		else:
			# Undefined opcodes act as brk.
			_op.append(NCIsa.Op.BRK)
			_mode.append(NCIsa.Mode.IMP)
			_r1.append(NCIsa.Reg.NONE)
			_r2.append(NCIsa.Reg.NONE)


func reset() -> void:
	a = 0
	x = 0
	y = 0
	sp = 0xFF
	fn = false
	fv = false
	fz = false
	fc = false
	fi = true
	waiting = false
	halted = false
	pc = word(VEC_RESET)


## The byte at [param addr] as stored, without I/O (for debuggers, tests).
func peek(addr: int) -> int:
	return mem[addr & 0xFFFF]


## Stores a byte at [param addr] as it is, ROM included (debuggers, tests).
func poke(addr: int, value: int) -> void:
	mem[addr & 0xFFFF] = value & 0xFF


## All 64 KB. Treat it as a snapshot: change memory with poke or write.
func memory() -> PackedByteArray:
	return mem


## Copies [param data] into memory from [param at] (ROM banks, tests).
func load_memory(at: int, data: PackedByteArray) -> void:
	var end := mini(at + data.size(), 0x10000)
	# Splicing whole arrays is native code: microseconds for 16 KB.
	mem = mem.slice(0, at) + data.slice(0, end - at) + mem.slice(end)


## Zeroes all memory.
func clear_memory() -> void:
	mem.fill(0)


func word(addr: int) -> int:
	return mem[addr & 0xFFFF] | (mem[(addr + 1) & 0xFFFF] << 8)


func read(addr: int) -> int:
	if addr < RAM_END or addr >= ROM_START:
		return mem[addr]
	if (addr >> 8) == IO_PAGE and io and io.get_ref():
		return io.get_ref().read_io(addr & 0xFF)
	return 0


func write(addr: int, value: int) -> void:
	if not watches.is_empty() and watches.has(addr):
		watch_hit = addr
	if addr < RAM_END:
		mem[addr] = value
		if addr >= VRAM_START:
			vram_dirty = true
	elif (addr >> 8) == IO_PAGE and io and io.get_ref():
		io.get_ref().write_io(addr & 0xFF, value)


func flags() -> int:
	return (F_N if fn else 0) | (F_V if fv else 0) | (F_I if fi else 0) | (F_Z if fz else 0) | (F_C if fc else 0)


func set_flags(f: int) -> void:
	fn = f & F_N != 0
	fv = f & F_V != 0
	fi = f & F_I != 0
	fz = f & F_Z != 0
	fc = f & F_C != 0


func push(v: int) -> void:
	mem[0x100 | sp] = v
	sp = (sp - 1) & 0xFF


func pop() -> int:
	sp = (sp + 1) & 0xFF
	return mem[0x100 | sp]


## Enters an interrupt through [param vector].
func interrupt(vector: int) -> void:
	push(pc >> 8)
	push(pc & 0xFF)
	push(flags())
	fi = true
	pc = word(vector)
	cycles += IRQ_CYCLES


## The start of a frame: wakes a waiting CPU and, if [param irq] and
## interrupts are on, runs the vblank handler.
func vblank(irq: bool) -> void:
	waiting = false
	if irq and not fi and not halted:
		interrupt(VEC_VBLANK)


## Runs up to [param budget] cycles; stops early at wait or halt.
## Returns the cycles used.
func run(budget: int) -> int:
	var start := cycles
	var end := cycles + budget
	stop_reason = ""
	if breakpoints.is_empty() and watches.is_empty() and trace_size == 0:
		while cycles < end and not waiting and not halted:
			step()
		return cycles - start
	# The debugging loop: the same, with checks.
	while cycles < end and not waiting and not halted:
		if breakpoints.has(pc) and not _resume:
			if breakpoints[pc] is String:
				breakpoints.erase(pc)
			stop_reason = "break"
			break
		_resume = false
		record_trace()
		watch_hit = -1
		step()
		if watch_hit >= 0:
			stop_reason = "watch"
			break
	return cycles - start


## Adds the current PC to the trace, if it is on.
func record_trace() -> void:
	if trace_size > 0:
		trace.append(pc)
		if trace.size() > trace_size:
			trace = trace.slice(trace.size() - trace_size)


## Lets the instruction at the current breakpoint run on the next [method run].
func resume() -> void:
	_resume = true


func _reg(r: int) -> int:
	match r:
		NCIsa.Reg.A: return a
		NCIsa.Reg.X: return x
		NCIsa.Reg.Y: return y
		NCIsa.Reg.SP: return sp
	return flags()


func _set_reg(r: int, v: int) -> void:
	match r:
		NCIsa.Reg.A: a = v
		NCIsa.Reg.X: x = v
		NCIsa.Reg.Y: y = v
		NCIsa.Reg.SP: sp = v
		NCIsa.Reg.F: set_flags(v)


## Runs one instruction.
func step() -> void:
	var opc := mem[pc]
	var mode := _mode[opc]
	var k := _op[opc]
	var ea := 0
	var imm := 0
	match mode:
		NCIsa.Mode.IMP:
			pc = (pc + 1) & 0xFFFF
		NCIsa.Mode.IMM:
			imm = mem[(pc + 1) & 0xFFFF]
			pc = (pc + 2) & 0xFFFF
		NCIsa.Mode.REL:
			var off := mem[(pc + 1) & 0xFFFF]
			pc = (pc + 2) & 0xFFFF
			ea = (pc + (off - 256 if off > 127 else off)) & 0xFFFF
		_:
			ea = mem[(pc + 1) & 0xFFFF] | (mem[(pc + 2) & 0xFFFF] << 8)
			pc = (pc + 3) & 0xFFFF
			match mode:
				NCIsa.Mode.ABX: ea = (ea + x) & 0xFFFF
				NCIsa.Mode.ABY: ea = (ea + y) & 0xFFFF
				NCIsa.Mode.IND: ea = (word(ea) + y) & 0xFFFF
				NCIsa.Mode.JIN: ea = word(ea)
	cycles += NCIsa.CYCLES[mode]
	match k:
		NCIsa.Op.LD:
			var v := imm if mode == NCIsa.Mode.IMM else read(ea)
			_set_reg(_r1[opc], v)
			fz = v == 0
			fn = v >= 0x80
		NCIsa.Op.ST:
			write(ea, _reg(_r1[opc]))
		NCIsa.Op.ADD, NCIsa.Op.ADC:
			var v := imm if mode == NCIsa.Mode.IMM else read(ea)
			var r := a + v + (1 if k == NCIsa.Op.ADC and fc else 0)
			fc = r > 0xFF
			r &= 0xFF
			fv = ((a ^ r) & (v ^ r) & 0x80) != 0
			a = r
			fz = r == 0
			fn = r >= 0x80
		NCIsa.Op.SUB, NCIsa.Op.SBC:
			var v := imm if mode == NCIsa.Mode.IMM else read(ea)
			var r := a - v - (1 if k == NCIsa.Op.SBC and fc else 0)
			fc = r < 0
			r &= 0xFF
			fv = ((a ^ v) & (a ^ r) & 0x80) != 0
			a = r
			fz = r == 0
			fn = r >= 0x80
		NCIsa.Op.AND, NCIsa.Op.OR, NCIsa.Op.XOR:
			var v := imm if mode == NCIsa.Mode.IMM else read(ea)
			a = a & v if k == NCIsa.Op.AND else a | v if k == NCIsa.Op.OR else a ^ v
			fz = a == 0
			fn = a >= 0x80
		NCIsa.Op.CMP:
			var v := imm if mode == NCIsa.Mode.IMM else read(ea)
			var r1 := _r1[opc]
			var r := (a if r1 == NCIsa.Reg.NONE else _reg(r1)) - v
			fc = r < 0
			fz = r == 0
			fn = (r & 0x80) != 0
		NCIsa.Op.INC, NCIsa.Op.DEC, NCIsa.Op.SHL, NCIsa.Op.SHR, NCIsa.Op.ROL, NCIsa.Op.ROR:
			var r1 := _r1[opc]
			var v := _reg(r1) if r1 != NCIsa.Reg.NONE else read(ea)
			match k:
				NCIsa.Op.INC: v = (v + 1) & 0xFF
				NCIsa.Op.DEC: v = (v - 1) & 0xFF
				NCIsa.Op.SHL:
					fc = v >= 0x80
					v = (v << 1) & 0xFF
				NCIsa.Op.SHR:
					fc = v & 1 == 1
					v >>= 1
				NCIsa.Op.ROL:
					var c := 1 if fc else 0
					fc = v >= 0x80
					v = ((v << 1) | c) & 0xFF
				NCIsa.Op.ROR:
					var c := 0x80 if fc else 0
					fc = v & 1 == 1
					v = (v >> 1) | c
			if r1 != NCIsa.Reg.NONE:
				_set_reg(r1, v)
			else:
				write(ea, v)
				cycles += 2 # read, modify, write
			fz = v == 0
			fn = v >= 0x80
		NCIsa.Op.MOV:
			var v := _reg(_r2[opc])
			_set_reg(_r1[opc], v)
			if _r1[opc] != NCIsa.Reg.SP:
				fz = v == 0
				fn = v >= 0x80
		NCIsa.Op.PUSH:
			push(_reg(_r1[opc]))
			cycles += 1
		NCIsa.Op.POP:
			var v := pop()
			_set_reg(_r1[opc], v)
			if _r1[opc] != NCIsa.Reg.F:
				fz = v == 0
				fn = v >= 0x80
			cycles += 2
		NCIsa.Op.JMP:
			pc = ea
			cycles -= 1
		NCIsa.Op.CALL:
			push(pc >> 8)
			push(pc & 0xFF)
			pc = ea
			cycles += 2
		NCIsa.Op.RET:
			pc = pop() | (pop() << 8)
			cycles += 4
		NCIsa.Op.RETI:
			set_flags(pop())
			pc = pop() | (pop() << 8)
			cycles += 4
		NCIsa.Op.JZ, NCIsa.Op.JNZ, NCIsa.Op.JC, NCIsa.Op.JNC, NCIsa.Op.JN, NCIsa.Op.JNN, NCIsa.Op.JR:
			var taken: bool
			match k:
				NCIsa.Op.JZ: taken = fz
				NCIsa.Op.JNZ: taken = not fz
				NCIsa.Op.JC: taken = fc
				NCIsa.Op.JNC: taken = not fc
				NCIsa.Op.JN: taken = fn
				NCIsa.Op.JNN: taken = not fn
				_: taken = true
			if taken:
				pc = ea
				cycles += 1
		NCIsa.Op.CLC: fc = false
		NCIsa.Op.SEC: fc = true
		NCIsa.Op.CLI: fi = false
		NCIsa.Op.SEI: fi = true
		NCIsa.Op.NOP: pass
		NCIsa.Op.WAIT: waiting = true
		NCIsa.Op.HALT: halted = true
		NCIsa.Op.BRK: interrupt(VEC_BRK)
