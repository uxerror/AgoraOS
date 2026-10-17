extends AgoraProgram


func summary() -> String:
	return "drop repeated adjacent lines"


func usage() -> String:
	return "usage: uniq [-cd] [file]\n  -c  prefix lines with their count\n  -d  only print repeated lines"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var lines: PackedStringArray = []
	for inp: Array in await read_inputs(p, a.operands):
		lines.append_array(lines_of(inp[1]))
	var i := 0
	while i < lines.size():
		var j := i
		while j + 1 < lines.size() and lines[j + 1] == lines[i]:
			j += 1
		var count := j - i + 1
		if not a.has("d") or count > 1:
			p.outln(("%7d " % count if a.has("c") else "") + lines[i])
		i = j + 1
	return 1 if input_failed else 0
