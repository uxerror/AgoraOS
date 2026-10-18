extends AgoraProgram
## printf FORMAT [ARGUMENT...]: formats the arguments like printf(3).
## Conversions %s %b %c %d %i %u %o %x %X %e %f %g %%, with flags (-, 0,
## space, +), width and precision; escapes \n \t \r \\ \a \b \f \v \e and
## \NNN (octal). The format is reused while arguments are left.


func summary() -> String:
	return "format and print data"


func usage() -> String:
	return "usage: printf FORMAT [ARGUMENT]..."


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail("missing operand\n" + usage(), 1)
	var format := p.argv[1]
	var args := p.argv.slice(2)
	var used := [0]
	var code := [0]
	var out := ""
	while true:
		var before: int = used[0]
		out += _format(p, format, args, used, code)
		if used[0] >= args.size() or used[0] == before:
			break
	p.out(out)
	return code[0]


## Expands backslash escapes, as in the format and in %b.
static func escapes(text: String) -> String:
	var out := ""
	var k := 0
	while k < text.length():
		var c := text[k]
		if c != "\\" or k + 1 >= text.length():
			out += c
			k += 1
			continue
		var e := text[k + 1]
		k += 2
		match e:
			"n": out += "\n"
			"t": out += "\t"
			"r": out += "\r"
			"\\": out += "\\"
			"a": out += "\u0007"
			"b": out += "\u0008"
			"f": out += "\u000c"
			"v": out += "\u000b"
			"e": out += "\u001b"
			"\"": out += "\""
			_:
				if e >= "0" and e <= "7":
					var digits := e
					while digits.length() < 3 and k < text.length() and text[k] >= "0" and text[k] <= "7":
						digits += text[k]
						k += 1
					out += char(_octal(digits))
				else:
					out += "\\" + e
	return out


static func _octal(digits: String) -> int:
	var n := 0
	for d in digits:
		n = n * 8 + d.to_int()
	return n


func _format(p: AgoraProcess, format: String, args: PackedStringArray, used: Array, code: Array) -> String:
	var out := ""
	var k := 0
	var text := format
	while k < text.length():
		var c := text[k]
		if c == "\\":
			var end := k + 2
			if k + 1 < text.length() and text[k + 1] >= "0" and text[k + 1] <= "7":
				while end < text.length() and end < k + 4 and text[end] >= "0" and text[end] <= "7":
					end += 1
			out += escapes(text.substr(k, end - k))
			k = end
			continue
		if c != "%":
			out += c
			k += 1
			continue
		if k + 1 < text.length() and text[k + 1] == "%":
			out += "%"
			k += 2
			continue
		# %[flags][width][.precision]conversion
		var spec := "%"
		k += 1
		while k < text.length() and text[k] in ["-", "0", " ", "+", "#"]:
			spec += text[k]
			k += 1
		while k < text.length() and (text[k].is_valid_int() or text[k] == "." or text[k] == "*"):
			if text[k] == "*":
				spec += str(_next(args, used).to_int())
			else:
				spec += text[k]
			k += 1
		if k >= text.length():
			out += spec
			break
		var conv := text[k]
		k += 1
		var arg := _next(args, used)
		match conv:
			"s":
				out += _pad(spec, arg)
			"b":
				out += _pad(spec, escapes(arg))
			"c":
				out += _pad(spec, arg.left(1))
			"d", "i", "u", "o", "x", "X":
				var n := 0
				if arg.begins_with("'") or arg.begins_with("\""):
					n = arg.unicode_at(1) if arg.length() > 1 else 0
				elif arg.is_empty():
					n = 0
				elif arg.is_valid_int():
					n = arg.to_int()
				elif arg.begins_with("0x") and arg.substr(2).is_valid_hex_number():
					n = arg.hex_to_int()
				else:
					p.errln("printf: %s: invalid number" % arg)
					code[0] = 1
					n = arg.to_int()
				match conv:
					"o":
						out += _pad(spec.replace("#", ""), ("0" if spec.contains("#") and n != 0 else "") + _base(n, 8))
					"x", "X":
						var h := _base(n, 16)
						out += _pad(spec.replace("#", ""), ("0x" if spec.contains("#") and n != 0 else "") + (h.to_upper() if conv == "X" else h))
					_:
						out += (spec + "d") % n
			"e", "f", "g", "E", "F", "G":
				var f := arg.to_float() if not arg.is_empty() else 0.0
				match conv:
					"f", "F":
						out += (spec + "f") % f
					"e", "E":
						var t := _sci(f, spec.get_slice(".", 1).to_int() if spec.contains(".") else 6)
						out += _pad(spec.get_slice(".", 0), t.to_upper() if conv == "E" else t)
					_:
						out += _pad(spec.get_slice(".", 0), str(f).trim_suffix(".0"))
			_:
				return out + "%" + conv
	return out


func _next(args: PackedStringArray, used: Array) -> String:
	if used[0] >= args.size():
		return ""
	var a := args[used[0]]
	used[0] += 1
	return a


## 1.500000e+00
static func _sci(f: float, precision: int) -> String:
	if f == 0.0:
		return ("%." + str(precision) + "fe+00") % 0.0
	var e := int(floor(log(absf(f)) / log(10.0)))
	var m := f / pow(10.0, e)
	if absf(m) >= 9.9999995:
		m /= 10.0
		e += 1
	return ("%." + str(precision) + "f") % m + "e%s%02d" % ["-" if e < 0 else "+", absi(e)]


static func _base(n: int, base: int) -> String:
	if n == 0:
		return "0"
	var digits := "0123456789abcdef"
	var out := ""
	var neg := n < 0
	n = absi(n)
	while n > 0:
		out = digits[n % base] + out
		n /= base
	return ("-" if neg else "") + out


## Width, precision and "-" for strings.
static func _pad(spec: String, text: String) -> String:
	var body := spec.substr(1)
	var left := body.contains("-")
	body = body.replace("-", "").replace(" ", "").replace("+", "").replace("#", "")
	var width := 0
	var precision := -1
	if body.contains("."):
		width = body.get_slice(".", 0).to_int()
		precision = body.get_slice(".", 1).to_int()
	else:
		width = body.to_int()
	if precision >= 0:
		text = text.left(precision)
	if text.length() < width:
		text = text + " ".repeat(width - text.length()) if left else " ".repeat(width - text.length()) + text
	return text
