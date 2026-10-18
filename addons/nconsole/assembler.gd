class_name NCAssembler
extends RefCounted
## Two-pass assembler for the N8 that builds an [NCCartridge].
##
##   ; comment
##   SPEED = 8               ; a constant
##   start:  ld a, #<table   ; label; < and > take the low and high byte
##   @loop:  st a, $2000,x   ; @name is local to the last plain label
##           jnz @loop
##
## Operands: #expr, expr, expr,x, expr,y, [expr],y, and [expr] for jmp.
## Numbers: 42, $2a, %101010, 'c'. Operators: + - * / % & | ^ << >> ~,
## parentheses, unary - ~ < >.
##
## Directives:
##   .section rom|ram|chr    rom starts at $8000, ram at $0200 (only
##                           labels and .res), chr counts tiles
##   .org expr               moves the current section
##   .byte expr|"text", ...  .word expr, ...   .res count[, fill]
##   .title "Name"
##   .tile [index]           in chr: the next 8 lines are rows of 8
##                           pixels, hex digits 0-f ("." is 0); a label
##                           before it gets the tile index
##   .include "file"         relative to the including file
##   .prgbanks n             program ROM size in 16 KB banks (2-32, default
##                           2); before any code
##   .bank n                 code that follows at $8000-$BFFF goes to bank
##                           n; $C000-$FFFF is always the last bank
##   .chrbanks n             tile ROM size in sets of 256 tiles (1-16)
##   .chrbank n              tiles that follow go to set n

const SECTION_START := {"rom": 0x8000, "ram": 0x0200, "chr": 0}
const REGISTERS: PackedStringArray = ["a", "x", "y", "sp", "f"]

## "file:line: message" for each problem found.
var errors: PackedStringArray = []

var _symbols := {}
var _pass := 1
var _section := "rom"
var _pc := {}
var _scope := ""
var _cart: NCCartridge
var _written := PackedByteArray()
var _labels := {}
var _label_banks := {}
var _bank := 0
var _bank_pc := {}
var _chr_bank := 0
var _emitted := false
var _file := ""
var _line := 0
var _unresolved := false


func assemble_file(path: String) -> NCCartridge:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		errors.append("%s: cannot open file" % path)
		return null
	return assemble(text, path)


## Assembles [param source]. Returns null with [member errors] set if
## anything is wrong.
func assemble(source: String, file_name: String = "main.asm") -> NCCartridge:
	errors.clear()
	_symbols.clear()
	_labels.clear()
	_label_banks.clear()
	var lines := _expand(source, file_name, 0)
	for p in [1, 2]:
		_pass = p
		_cart = NCCartridge.new()
		_written = PackedByteArray()
		_written.resize(_cart.prg.size())
		_bank = 0
		_bank_pc = {}
		_chr_bank = 0
		_emitted = false
		_section = "rom"
		_pc = SECTION_START.duplicate()
		_scope = ""
		var k := 0
		while k < lines.size():
			k = _statement(lines, k)
		if not errors.is_empty():
			return null
	_cart.symbols = _symbols.duplicate()
	_cart.labels = _labels.duplicate()
	_cart.label_banks = _label_banks.duplicate()
	return _cart


## Source lines as [file, line number, text], with includes spliced in.
func _expand(source: String, file_name: String, depth: int) -> Array:
	var out: Array = []
	var n := 0
	for raw in source.split("\n"):
		n += 1
		var text := _strip_comment(raw).strip_edges()
		if text.to_lower().begins_with(".include"):
			var name := text.substr(8).strip_edges().trim_prefix("\"").trim_suffix("\"")
			var path := file_name.get_base_dir().path_join(name)
			if depth > 8 or not FileAccess.file_exists(path):
				errors.append("%s:%d: cannot include \"%s\"" % [file_name, n, name])
				continue
			out.append_array(_expand(FileAccess.get_file_as_string(path), path, depth + 1))
			continue
		out.append([file_name, n, text])
	return out


static func _strip_comment(line: String) -> String:
	var quote := ""
	for k in line.length():
		var c := line[k]
		if not quote.is_empty():
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == ";":
			return line.left(k)
	return line


func _error(message: String) -> void:
	var text := "%s:%d: %s" % [_file, _line, message]
	if not errors.has(text):
		errors.append(text)


## Handles the line at [param k]; returns the index of the next one.
func _statement(lines: Array, k: int) -> int:
	_file = lines[k][0]
	_line = lines[k][1]
	var text: String = lines[k][2]
	if text.is_empty():
		return k + 1
	# A label.
	var colon := text.find(":")
	if colon > 0 and _is_identifier(text.left(colon)):
		_define_label(text.left(colon))
		text = text.substr(colon + 1).strip_edges()
		if text.is_empty():
			return k + 1
	# A constant.
	var eq := text.find("=")
	if eq > 0 and _is_identifier(text.left(eq).strip_edges()):
		var name := text.left(eq).strip_edges()
		var v: Variant = _eval(text.substr(eq + 1))
		if v != null:
			_symbols[_qualify(name)] = v
		return k + 1
	var word := text.get_slice(" ", 0).get_slice("\t", 0)
	var rest := text.substr(word.length()).strip_edges()
	if word.begins_with("."):
		return _directive(word.to_lower(), rest, lines, k)
	_instruction(word.to_lower(), rest)
	return k + 1


static func _is_identifier(s: String) -> bool:
	if s.is_empty() or not (s[0] == "_" or s[0] == "@" or s[0].to_lower() != s[0].to_upper()):
		return false
	for c in s.substr(1):
		if not (c == "_" or c.is_valid_int() or c.to_lower() != c.to_upper()):
			return false
	return true


func _qualify(name: String) -> String:
	return _scope + name if name.begins_with("@") else name


func _define_label(name: String) -> void:
	if REGISTERS.has(name.to_lower()):
		_error("'%s' is a register, not a label" % name)
		return
	if not name.begins_with("@"):
		_scope = name
	var full := _qualify(name)
	var value: int = _pc[_section]
	if _section == "chr":
		value = _pc.chr
	if _pass == 1 and _symbols.has(full):
		_error("'%s' is defined twice" % name)
	_symbols[full] = value
	if _section != "chr":
		_labels[full] = value
		if _section == "rom" and value >= 0x8000 and value < 0xC000:
			_label_banks[full] = _bank


# --- directives -----------------------------------------------------------------

func _directive(word: String, rest: String, lines: Array, k: int) -> int:
	match word:
		".section":
			var s := rest.to_lower()
			if not SECTION_START.has(s):
				_error("unknown section '%s'" % rest)
			else:
				_section = s
		".org":
			var v: Variant = _eval(rest, true)
			if v != null:
				_pc[_section] = v
		".title":
			_cart.title = rest.trim_prefix("\"").trim_suffix("\"")
		".byte", ".word":
			for item in _split_operands(rest):
				if word == ".byte" and item.begins_with("\"") and item.ends_with("\"") and item.length() >= 2:
					for b in item.substr(1, item.length() - 2).to_ascii_buffer():
						_emit(b)
					continue
				var v: Variant = _eval(item)
				var n: int = v if v != null else 0
				if word == ".byte":
					if n < -128 or n > 255:
						_error("value %d doesn't fit in a byte" % n)
					_emit(n & 0xFF)
				else:
					_emit(n & 0xFF)
					_emit((n >> 8) & 0xFF)
		".res":
			var parts := _split_operands(rest)
			var count: Variant = _eval(parts[0] if not parts.is_empty() else "", true)
			var fill: Variant = _eval(parts[1]) if parts.size() > 1 else 0
			if count != null:
				for n in int(count):
					if _section == "ram":
						_pc.ram += 1
					else:
						_emit(int(fill if fill != null else 0) & 0xFF)
		".tile":
			return _tile(rest, lines, k)
		".prgbanks":
			var v: Variant = _eval(rest, true)
			if v == null:
				pass
			elif v < 2 or v > NCCartridge.MAX_PRG_BANKS:
				_error("a cartridge has 2 to %d program banks" % NCCartridge.MAX_PRG_BANKS)
			elif _emitted:
				_error(".prgbanks must come before any code")
			else:
				var title := _cart.title
				var chr := _cart.chr
				_cart = NCCartridge.new(v)
				_cart.title = title
				_cart.chr = chr
				_written.resize(_cart.prg.size())
		".bank":
			var v: Variant = _eval(rest, true)
			if v != null and (v < 0 or v >= _cart.prg_banks):
				_error("bank %d doesn't exist (the cartridge has %d)" % [v, _cart.prg_banks])
			elif v != null:
				_bank_pc[_bank] = _pc.rom
				_bank = v
				_section = "rom"
				_pc.rom = _bank_pc.get(_bank, 0x8000)
		".chrbanks":
			var v: Variant = _eval(rest, true)
			if v != null and (v < 1 or v > NCCartridge.MAX_CHR_BANKS):
				_error("a cartridge has 1 to %d tile banks" % NCCartridge.MAX_CHR_BANKS)
			elif v != null:
				_cart.chr.resize(v * NCCartridge.CHR_BANK_SIZE)
		".chrbank":
			var v: Variant = _eval(rest, true)
			if v != null and (v < 0 or v >= _cart.chr_banks):
				_error("tile bank %d doesn't exist (the cartridge has %d)" % [v, _cart.chr_banks])
			elif v != null:
				_chr_bank = v
				_section = "chr"
				_pc.chr = 0
		_:
			_error("unknown directive '%s'" % word)
	return k + 1


func _tile(rest: String, lines: Array, k: int) -> int:
	if _section != "chr":
		_error(".tile outside the chr section")
		return k + 1
	if not rest.is_empty():
		var v: Variant = _eval(rest, true)
		if v != null:
			_pc.chr = v
	var index: int = _pc.chr
	if index < 0 or index > 255:
		_error("tile index %d out of range" % index)
		return k + 9
	var row := 0
	var j := k + 1
	while row < 8 and j < lines.size():
		var text: String = (lines[j][2] as String).trim_prefix("\"").trim_suffix("\"")
		_line = lines[j][1]
		j += 1
		if text.is_empty():
			continue
		if text.length() != 8:
			_error("a tile row has 8 pixels: '%s'" % text)
		for px in mini(8, text.length()):
			var c := text[px].to_lower()
			var color := 0 if c == "." else "0123456789abcdef".find(c)
			if color < 0:
				_error("bad pixel '%s' (use 0-f or .)" % c)
				color = 0
			var at := ((_chr_bank << 8) + index) * NCCartridge.TILE_BYTES + row * 4 + px / 2
			_cart.chr[at] |= color << 4 if px % 2 == 0 else color
		row += 1
	if row < 8:
		_error("tile %d has only %d rows" % [index, row])
	_pc.chr = index + 1
	return j


func _emit(b: int) -> void:
	if _section == "chr":
		_error("data in the chr section; use .tile")
		return
	if _section == "ram":
		_error("data in the ram section; use .res")
		return
	_emitted = true
	var addr: int = _pc.rom
	if addr < 0x8000 or addr > 0xFFFF:
		_error("address $%04x is outside ROM ($8000-$ffff)" % addr)
	else:
		# $8000-$BFFF is the current bank, $C000-$FFFF the last one.
		var at := (_cart.prg_banks - 1) * NCCartridge.BANK_SIZE + addr - 0xC000 if addr >= 0xC000 \
			else _bank * NCCartridge.BANK_SIZE + addr - 0x8000
		if _pass == 2 and _written[at] != 0:
			_error("code overlaps at $%04x" % addr)
		_cart.prg[at] = b
		_written[at] = 1
	_pc.rom = addr + 1


# --- instructions ---------------------------------------------------------------

func _instruction(name: String, rest: String) -> void:
	if not NCIsa.is_mnemonic(name):
		_error("unknown instruction '%s'" % name)
		return
	var ops := _split_operands(rest)
	var regs := ""
	# Leading register operands: "ld x, ...", "mov a, x", "inc y".
	if name == "mov":
		regs = ",".join(ops).to_lower()
		ops = []
	elif not ops.is_empty() and REGISTERS.has(ops[0].to_lower()):
		var r := ops[0].to_lower()
		if NCIsa.has_form(name, r):
			regs = r
			ops = ops.slice(1)
		elif r == "a" and NCIsa.has_form(name, ""):
			ops = ops.slice(1) # "add a, #1" is "add #1"
	if not NCIsa.has_form(name, regs):
		_error("'%s' can't be used with %s" % [name, regs if not regs.is_empty() else "no register"])
		return
	var mode := NCIsa.Mode.IMP
	var expr := ""
	if ops.size() == 1 and ops[0].begins_with("#"):
		mode = NCIsa.Mode.IMM
		expr = ops[0].substr(1)
	elif ops.size() >= 1 and ops[0].begins_with("[") and ops[0].ends_with("]"):
		expr = ops[0].substr(1, ops[0].length() - 2)
		if ops.size() == 2 and ops[1].to_lower() == "y":
			mode = NCIsa.Mode.IND
		elif ops.size() == 1:
			mode = NCIsa.Mode.JIN
		else:
			_error("an indirect operand is [address],y")
			return
	elif ops.size() == 2 and ops[1].to_lower() in ["x", "y"]:
		mode = NCIsa.Mode.ABX if ops[1].to_lower() == "x" else NCIsa.Mode.ABY
		expr = ops[0]
	elif ops.size() == 1:
		expr = ops[0]
		mode = NCIsa.Mode.REL if NCIsa.opcode(name, regs, NCIsa.Mode.REL) >= 0 else NCIsa.Mode.ABS
	elif ops.size() > 1:
		_error("too many operands")
		return
	var opc := NCIsa.opcode(name, regs, mode)
	if opc < 0:
		_error("'%s' has no %s form" % [(name + " " + regs).strip_edges(), NCIsa.mode_name(mode)])
		return
	var at: int = _pc.rom
	_emit(opc)
	if mode == NCIsa.Mode.IMP:
		return
	var v: Variant = _eval(expr)
	var value: int = v if v != null else 0
	match mode:
		NCIsa.Mode.IMM:
			if value < -128 or value > 255:
				_error("value %d doesn't fit in a byte" % value)
			_emit(value & 0xFF)
		NCIsa.Mode.REL:
			var off := value - (at + 2)
			if _pass == 2 and v != null and (off < -128 or off > 127):
				_error("branch target is %d bytes away (at most 127 back or forward); use jmp" % off)
			_emit(off & 0xFF)
		_:
			_emit(value & 0xFF)
			_emit((value >> 8) & 0xFF)


## Splits on commas that are not inside quotes or brackets.
static func _split_operands(text: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var depth := 0
	var quote := ""
	var cur := ""
	for c in text:
		if not quote.is_empty():
			if c == quote:
				quote = ""
		elif c == "\"" or c == "'":
			quote = c
		elif c == "[" or c == "(":
			depth += 1
		elif c == "]" or c == ")":
			depth -= 1
		elif c == "," and depth == 0:
			out.append(cur.strip_edges())
			cur = ""
			continue
		cur += c
	if not cur.strip_edges().is_empty() or not out.is_empty():
		out.append(cur.strip_edges())
	return out


# --- expressions ----------------------------------------------------------------

var _toks: Array = []
var _at := 0


## The value of [param text], or null after reporting an error. Unknown
## symbols are 0 in the first pass unless [param now] says the value is
## needed at once (.org, .res).
func _eval(text: String, now: bool = false) -> Variant:
	_toks = _tokenize(text)
	if _toks.is_empty():
		_error("missing value")
		return null
	if _toks.has(null):
		_error("can't read '%s'" % text.strip_edges())
		return null
	_at = 0
	_unresolved = false
	var v: Variant = _binary(0)
	if v != null and _at < _toks.size():
		_error("unexpected '%s'" % str(_toks[_at]))
		return null
	if _unresolved and (_pass == 2 or now):
		return null
	return v


const _PRECEDENCE := [["|"], ["^"], ["&"], ["<<", ">>"], ["+", "-"], ["*", "/", "%"]]


func _binary(level: int) -> Variant:
	if level >= _PRECEDENCE.size():
		return _unary()
	var left: Variant = _binary(level + 1)
	while left != null and _at < _toks.size() and _toks[_at] is String and _PRECEDENCE[level].has(_toks[_at]):
		var op: String = _toks[_at]
		_at += 1
		var right: Variant = _binary(level + 1)
		if right == null:
			return null
		match op:
			"|": left = left | right
			"^": left = left ^ right
			"&": left = left & right
			"<<": left = left << right
			">>": left = left >> right
			"+": left = left + right
			"-": left = left - right
			"*": left = left * right
			"/", "%":
				if right == 0:
					_error("division by zero")
					return null
				left = left / right if op == "/" else left % right
	return left


func _unary() -> Variant:
	if _at >= _toks.size():
		_error("missing value")
		return null
	var t: Variant = _toks[_at]
	_at += 1
	if t is int:
		return t
	match t:
		"-", "~", "<", ">":
			var v: Variant = _unary()
			if v == null:
				return null
			match t:
				"-": return -v
				"~": return ~v & 0xFFFF
				"<": return v & 0xFF
				">": return (v >> 8) & 0xFF
		"(":
			var v: Variant = _binary(0)
			if _at >= _toks.size() or _toks[_at] != ")":
				_error("missing ')'")
				return null
			_at += 1
			return v
	if t is StringName:
		var name := _qualify(String(t))
		if _symbols.has(name):
			return _symbols[name]
		if _pass == 2:
			_error("unknown symbol '%s'" % t)
			return null
		_unresolved = true
		return 0
	_error("unexpected '%s'" % str(t))
	return null


## Tokens: ints, operators as Strings, names as StringNames; null for
## anything unreadable.
static func _tokenize(text: String) -> Array:
	var out: Array = []
	var k := 0
	while k < text.length():
		var c := text[k]
		if c == " " or c == "\t":
			k += 1
			continue
		var two := text.substr(k, 2)
		if two == "<<" or two == ">>":
			out.append(two)
			k += 2
			continue
		if c == "%" and k + 1 < text.length() and text[k + 1] in ["0", "1"] and (out.is_empty() or (out[-1] is String and out[-1] != ")")):
			var b := k + 1
			while b < text.length() and text[b] in ["0", "1"]:
				b += 1
			out.append(text.substr(k + 1, b - k - 1).bin_to_int())
			k = b
			continue
		if "+-*/%&|^~<>()".contains(c):
			out.append(c)
			k += 1
			continue
		if c == "'" and k + 2 < text.length() and text[k + 2] == "'":
			out.append(text.unicode_at(k + 1))
			k += 3
			continue
		var j := k + 1
		while j < text.length() and not " \t+-*/%&|^~<>()'".contains(text[j]):
			j += 1
		var word := text.substr(k, j - k)
		k = j
		if word.begins_with("$") and word.length() > 1 and word.substr(1).is_valid_hex_number():
			out.append(word.substr(1).hex_to_int())
		elif word.is_valid_int():
			out.append(int(word))
		elif _is_identifier(word):
			out.append(StringName(word))
		else:
			out.append(null)
	return out
