extends AgoraProgram


func summary() -> String:
	return "count lines, words and characters"


func usage() -> String:
	return "usage: wc [-lwc] [file...]"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var pick := a.has("l") or a.has("w") or a.has("c")
	var inputs := await read_inputs(p, a.operands)
	var total := [0, 0, 0]
	for inp: Array in inputs:
		var text: String = inp[1]
		var counts := [text.count("\n"), _words(text), text.to_utf8_buffer().size()]
		for k in 3:
			total[k] += counts[k]
		p.outln(_format(counts, a, pick, inp[0] if inp[0] != "-" else ""))
	if inputs.size() > 1:
		p.outln(_format(total, a, pick, "total"))
	return 1 if input_failed else 0


func _words(text: String) -> int:
	return text.replace("\n", " ").replace("\t", " ").split(" ", false).size()


func _format(counts: Array, a: AgoraArgs, pick: bool, name: String) -> String:
	var cols: PackedStringArray = []
	for k in 3:
		if not pick or a.has("lwc"[k]):
			cols.append(str(counts[k]).lpad(7))
	return " ".join(cols) + (" " + name if not name.is_empty() else "")
