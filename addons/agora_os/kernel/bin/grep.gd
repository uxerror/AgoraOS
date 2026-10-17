extends AgoraProgram


func summary() -> String:
	return "print lines matching a pattern"


func usage() -> String:
	return "usage: grep [-ivncFlr] pattern [file...]\n  -i  ignore case        -v  invert match\n  -n  line numbers       -c  count matches only\n  -F  fixed string       -l  list matching files\n  -r  search directories recursively"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "e")
	var operands := a.operands
	# Several -e patterns match if any does.
	var patterns: PackedStringArray = []
	for i in range(1, p.argv.size() - 1):
		if p.argv[i] == "-e":
			patterns.append(p.argv[i + 1])
	var pattern := "|".join(patterns) if patterns.size() > 1 else a.value("e")
	if a.has("F") and patterns.size() > 1:
		var escaped: PackedStringArray = []
		for pt in patterns:
			escaped.append(_rx_escape(pt))
		pattern = "|".join(escaped)
	if not a.has("e"):
		if operands.is_empty():
			return p.fail("no pattern given", 2)
		pattern = operands[0]
		operands = operands.slice(1)
	var re := RegEx.new()
	var src := _rx_escape(pattern) if a.has("F") and patterns.size() < 2 else pattern
	if a.has("i"):
		src = "(?i)" + src
	if re.compile(src) != OK:
		return p.fail("invalid pattern '%s'" % pattern, 2)
	if a.has("r"):
		var files: PackedStringArray = []
		for o in (operands if not operands.is_empty() else PackedStringArray(["."])):
			_collect(p, o, files)
		operands = files
	var inputs := await read_inputs(p, operands)
	var show_names := inputs.size() > 1 or a.has("r")
	var matched_any := false
	for inp: Array in inputs:
		var count := 0
		var line_no := 0
		for line in lines_of(inp[1]):
			line_no += 1
			var hit := re.search(line) != null
			if hit == a.has("v"):
				continue
			count += 1
			matched_any = true
			if a.has("c") or a.has("l"):
				continue
			var prefix := ""
			if show_names:
				prefix += inp[0] + ":"
			if a.has("n"):
				prefix += str(line_no) + ":"
			if not p.outln(prefix + line):
				return 1
		if a.has("l") and count > 0:
			p.outln(inp[0])
		elif a.has("c"):
			p.outln(("%s:" % inp[0] if show_names else "") + str(count))
	if input_failed:
		return 2
	return 0 if matched_any else 1


func _collect(p: AgoraProcess, path: String, out: PackedStringArray) -> void:
	var st := p.stat(path)
	if st == null:
		return
	if st.is_dir():
		for n in p.list_dir(path):
			_collect(p, AgoraPath.join(path, n), out)
	elif st.is_file():
		out.append(path)


static func _rx_escape(s: String) -> String:
	var out := ""
	for c in s:
		out += "\\" + c if ".^$+(){}|[]\\*?".contains(c) else c
	return out
