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
	var rows: Array = []
	for inp: Array in inputs:
		var text: String = inp[1]
		var counts := [text.count("\n"), _words(text), text.to_utf8_buffer().size()]
		for k in 3:
			total[k] += counts[k]
		rows.append([counts, inp[0] if inp[0] != "-" else ""])
	if inputs.size() > 1:
		rows.append([total, "total"])
	# Like GNU wc: one number alone isn't padded; columns get the width of
	# the largest number (7 when reading a pipe).
	var columns := 1 if pick and (a.flags.keys().filter(func(f: String) -> bool: return f in ["l", "w", "c"]).size() == 1) else 3
	var width := 0
	if columns > 1 or rows.size() > 1:
		width = str(total.max()).length()
		if a.operands.is_empty():
			width = maxi(width, 7)
	for row: Array in rows:
		p.outln(_format(row[0], a, pick, row[1], width))
	return 1 if input_failed else 0


func _words(text: String) -> int:
	return text.replace("\n", " ").replace("\t", " ").split(" ", false).size()


func _format(counts: Array, a: AgoraArgs, pick: bool, name: String, width: int) -> String:
	var cols: PackedStringArray = []
	for k in 3:
		if not pick or a.has("lwc"[k]):
			cols.append(str(counts[k]).lpad(width))
	return " ".join(cols) + (" " + name if not name.is_empty() else "")
