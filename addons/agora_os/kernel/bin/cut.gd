extends AgoraProgram


func summary() -> String:
	return "select fields from each line"


func usage() -> String:
	return "usage: cut -f list [-d delim] [file...]\nlist is like 1,3 or 2-4 or 3-"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "fdc")
	if not a.has("f") and not a.has("c"):
		return p.fail("you must specify a list of fields", 2)
	var delim := a.value("d", "\t")
	var by_chars := a.has("c")
	var spec := a.value("c") if by_chars else a.value("f")
	for inp: Array in await read_inputs(p, a.operands):
		for line in lines_of(inp[1]):
			var items := line.split("") if by_chars else line.split(delim)
			if not by_chars and items.size() == 1:
				p.outln(line)
				continue
			var picked: PackedStringArray = []
			for idx in _indices(spec, items.size()):
				picked.append(items[idx])
			p.outln(("" if by_chars else delim).join(picked))
	return 1 if input_failed else 0


func _indices(spec: String, count: int) -> PackedInt32Array:
	var out: PackedInt32Array = []
	for part in spec.split(","):
		var lo := 1
		var hi := count
		if part.contains("-"):
			var a := part.get_slice("-", 0)
			var b := part.get_slice("-", 1)
			lo = int(a) if not a.is_empty() else 1
			hi = int(b) if not b.is_empty() else count
		else:
			lo = int(part)
			hi = lo
		for i in range(maxi(lo, 1), mini(hi, count) + 1):
			if not out.has(i - 1):
				out.append(i - 1)
	return out
