class_name NCMonitor
extends RefCounted
## A machine-code monitor for the NConsole, in the spirit of the ones
## built into 80s computers: one-line commands, answers as text. The
## debugger panel types into it; tests call [method command] directly.
##
## Numbers are hex ($ optional). Addresses: a number, a label, or
## label+offset. Bytes for e: hex, or #decimal.

const HELP := """r                 registers
s [n]             step n instructions
n                 step over a call
c                 continue          p   pause
f                 run to the end of the frame
b [addr]          breakpoint, or list them     bd addr|*  delete
w [addr]          stop on writes to addr       wd addr|*  delete
d [addr] [n]      disassemble (at PC)
m [addr] [n]      memory dump
e addr bytes...   write memory
g addr            set PC
t [n|on|off]      trace of executed instructions
reset             power cycle"""

var console: NConsole
## address -> name, built from the cartridge's labels.
var _names := {}
var _named_bank := {}


func _init(c: NConsole) -> void:
	console = c
	refresh_labels()


func refresh_labels() -> void:
	_names.clear()
	_named_bank.clear()
	var cart := console.cartridge
	if cart == null:
		return
	for name: String in cart.labels:
		var addr: int = cart.labels[name]
		# A plain label beats a local one at the same address.
		if not _names.has(addr) or (String(_names[addr]).contains("@") and not name.contains("@")):
			_names[addr] = name
			if cart.label_banks.has(name):
				_named_bank[addr] = cart.label_banks[name]


## The label at [param addr], or "" (labels in the switchable window only
## count while their bank is in).
func name_of(addr: int) -> String:
	if not _names.has(addr):
		return ""
	if _named_bank.has(addr) and _named_bank[addr] != console.prg_bank:
		return ""
	return _names[addr]


## Runs one command line and returns what to print.
func command(line: String) -> String:
	var words := line.strip_edges().split(" ", false)
	if words.is_empty():
		return ""
	var cmd := words[0].to_lower()
	var args := words.slice(1)
	var cpu := console.cpu
	match cmd:
		"?", "help", "h":
			return HELP
		"r":
			return registers()
		"s":
			var n := maxi(1, _number(args[0], 1) if not args.is_empty() else 1)
			for k in n:
				console.step_instruction()
				if cpu.halted:
					break
			console.paused = true
			console.render_now()
			return registers() + "\n" + disassemble(cpu.pc, 1)
		"n":
			var op: int = cpu.peek(cpu.pc)
			if NCIsa.mnemonic(op) == "call":
				cpu.breakpoints[(cpu.pc + 3) & 0xFFFF] = "temp"
				console.resume()
				return "running to $%04x" % ((cpu.pc + 3) & 0xFFFF)
			return command("s")
		"c":
			console.resume()
			return "running"
		"p":
			console.paused = true
			console.render_now()
			return registers() + "\n" + disassemble(cpu.pc, 1)
		"f":
			console.resume()
			console.run_frame()
			if console.paused:
				return stop_message()
			console.paused = true
			return "frame %d\n%s" % [console.frame, disassemble(cpu.pc, 1)]
		"b", "w":
			var table: Dictionary = cpu.breakpoints if cmd == "b" else cpu.watches
			if args.is_empty():
				return _list(table)
			var addr := address(args[0])
			if addr < 0:
				return "?address " + args[0]
			table[addr] = true
			return "%s $%04x%s" % ["break at" if cmd == "b" else "watch", addr, _label_suffix(addr)]
		"bd", "wd":
			var table: Dictionary = cpu.breakpoints if cmd == "bd" else cpu.watches
			if args.is_empty():
				return "?address"
			if args[0] == "*":
				table.clear()
				return "all deleted"
			var addr := address(args[0])
			if not table.has(addr):
				return "none at " + args[0]
			table.erase(addr)
			return "deleted $%04x" % addr
		"d":
			var at: int = address(args[0]) if not args.is_empty() else cpu.pc
			if at < 0:
				return "?address " + args[0]
			return disassemble(at, _number(args[1], 10) if args.size() > 1 else 10)
		"m":
			var at := address(args[0]) if not args.is_empty() else 0
			if at < 0:
				return "?address " + args[0]
			return dump(at, _number(args[1], 64) if args.size() > 1 else 64)
		"e":
			if args.size() < 2:
				return "?usage: e addr bytes..."
			var at := address(args[0])
			if at < 0:
				return "?address " + args[0]
			for k in range(1, args.size()):
				var v := _value(args[k])
				if v < 0 or v > 255:
					return "?byte " + args[k]
				cpu.write((at + k - 1) & 0xFFFF, v)
			console.render_now()
			return dump(at, args.size() - 1)
		"g":
			var at := address(args[0]) if not args.is_empty() else -1
			if at < 0:
				return "?address"
			cpu.pc = at
			return registers() + "\n" + disassemble(at, 1)
		"t":
			if args.is_empty() or args[0].is_valid_hex_number():
				if cpu.trace_size == 0:
					return "trace is off (t on)"
				var n := _number(args[0], 16) if not args.is_empty() else 16
				var out: PackedStringArray = []
				for addr in cpu.trace.slice(maxi(0, cpu.trace.size() - n)):
					out.append(disassemble(addr, 1))
				return "\n".join(out)
			cpu.trace_size = 256 if args[0] == "on" else 0
			cpu.trace = PackedInt32Array()
			return "trace " + args[0]
		"reset":
			console.reset()
			console.paused = true
			return registers()
	return "?command %s (help lists them)" % cmd


## Why the CPU stopped, for the panel.
func stop_message() -> String:
	var cpu := console.cpu
	match cpu.stop_reason:
		"break":
			return "break at $%04x%s\n%s" % [cpu.pc, _label_suffix(cpu.pc), disassemble(cpu.pc, 1)]
		"watch":
			return "write to $%04x%s = $%02x\n%s" % [cpu.watch_hit, _label_suffix(cpu.watch_hit), cpu.peek(cpu.watch_hit) if cpu.watch_hit < 0x3000 else 0, registers()]
	return ""


func registers() -> String:
	var cpu := console.cpu
	var flags := ""
	for pair: Array in [["n", cpu.fn], ["v", cpu.fv], ["i", cpu.fi], ["z", cpu.fz], ["c", cpu.fc]]:
		flags += (pair[0] as String).to_upper() if pair[1] else "."
	var state: String = " wait" if cpu.waiting else " halt" if cpu.halted else ""
	return "PC=%04x A=%02x X=%02x Y=%02x SP=%02x %s  bank %d  frame %d  cycle %d%s" % [
		cpu.pc, cpu.a, cpu.x, cpu.y, cpu.sp, flags, console.prg_bank, console.frame, console.last_cycles, state]


## [param count] instructions from [param at]: label lines, a > at PC
## and a * at breakpoints, the bytes, and operands named by labels.
func disassemble(at: int, count: int) -> String:
	var cpu := console.cpu
	var mem: PackedByteArray = cpu.memory()
	var out: PackedStringArray = []
	var hex := RegEx.create_from_string("\\$([0-9a-f]{4})")
	for k in count:
		var label := name_of(at)
		if not label.is_empty() and count > 1:
			out.append(label + ":")
		var d := NCIsa.disassemble(mem, at)
		var text: String = d[0]
		for m in hex.search_all(text):
			var target := name_of(m.get_string(1).hex_to_int())
			if not target.is_empty():
				text = text.replace(m.get_string(0), target)
		var bytes := ""
		for b in int(d[1]):
			bytes += "%02x " % mem[(at + b) & 0xFFFF]
		var mark: String = (">" if at == cpu.pc else " ") + ("*" if cpu.breakpoints.has(at) else " ")
		out.append("%s %04x  %-9s %s" % [mark, at, bytes, text])
		at = (at + int(d[1])) & 0xFFFF
	return "\n".join(out)


func dump(at: int, count: int) -> String:
	var out: PackedStringArray = []
	var row := at
	var end := at + count
	while row < end:
		var hexs := ""
		var text := ""
		for k in mini(16, end - row):
			var v: int = console.cpu.read((row + k) & 0xFFFF)
			hexs += "%02x " % v
			text += char(v) if v > 32 and v < 127 else "."
		out.append("%04x: %-48s %s" % [row & 0xFFFF, hexs, text])
		row += 16
	return "\n".join(out)


## Parses an address: hex, a label, or label+hex / label-hex. -1 if none.
func address(text: String) -> int:
	var t := text.strip_edges()
	var offset := 0
	for sign in ["+", "-"]:
		var at := t.find(sign, 1)
		if at > 0:
			var off := _number(t.substr(at + 1), -1)
			if off < 0:
				return -1
			offset = off if sign == "+" else -off
			t = t.left(at)
			break
	var base := -1
	var cart := console.cartridge
	if cart and cart.labels.has(t):
		base = cart.labels[t]
	elif cart and cart.symbols.has(t):
		base = cart.symbols[t]
	else:
		base = _number(t, -1)
	return (base + offset) & 0xFFFF if base >= 0 else -1


func _number(text: String, default: int) -> int:
	var t := text.trim_prefix("$")
	return t.hex_to_int() if not t.is_empty() and t.is_valid_hex_number() else default


func _value(text: String) -> int:
	if text.begins_with("#"):
		return int(text.substr(1)) if text.substr(1).is_valid_int() else -1
	return _number(text, -1)


func _label_suffix(addr: int) -> String:
	var n := name_of(addr)
	return " (%s)" % n if not n.is_empty() else ""


func _list(table: Dictionary) -> String:
	if table.is_empty():
		return "none"
	var out: PackedStringArray = []
	var keys := table.keys()
	keys.sort()
	for addr: int in keys:
		out.append("$%04x%s" % [addr, _label_suffix(addr)])
	return "\n".join(out)
