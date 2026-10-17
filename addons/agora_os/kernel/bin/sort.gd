extends AgoraProgram


func summary() -> String:
	return "sort lines of text"


func usage() -> String:
	return "usage: sort [-rnu] [file...]\n  -r  reverse   -n  numeric   -u  unique"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var lines: Array = []
	for inp: Array in await read_inputs(p, a.operands):
		lines.append_array(Array(lines_of(inp[1])))
	if a.has("n"):
		lines.sort_custom(func(x: String, y: String) -> bool: return x.to_float() < y.to_float())
	else:
		lines.sort()
	if a.has("r"):
		lines.reverse()
	var prev: Variant = null
	for l: String in lines:
		if a.has("u") and l == prev:
			continue
		prev = l
		if not p.outln(l):
			return 1
	return 1 if input_failed else 0
