extends AgoraProgram


func summary() -> String:
	return "concatenate files and print them"


func usage() -> String:
	return "usage: cat [-n] [file...]\nPrints each file in order. With no file, or '-', reads stdin.\n  -n  number output lines"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var files := a.operands if not a.operands.is_empty() else PackedStringArray(["-"])
	var status := 0
	var line_no := 1
	for f in files:
		if f == "-" and not a.has("n"):
			# Copy what arrives as it arrives: interactive, and a last line
			# without a newline stays without one.
			while true:
				var chunk: Variant = await p.stdin.read_some(p.is_dead)
				if chunk == null:
					break
				if not p.out(chunk):
					return 1
			continue
		if f == "-":
			# Numbered: line by line.
			while true:
				var line: Variant = await p.read_line()
				if line == null:
					break
				if not p.outln(("%6d\t" % line_no if a.has("n") else "") + line):
					return 1
				line_no += 1
			continue
		var st := p.stat(f)
		if st != null and st.is_dir():
			p.fail("%s: Is a directory" % f)
			status = 1
			continue
		var text := p.read_text(f)
		if p.errno != AgoraErrno.OK:
			status = p.fail_path(f)
			continue
		if a.has("n"):
			for l in lines_of(text):
				p.outln("%6d\t%s" % [line_no, l])
				line_no += 1
		elif not p.out(text):
			return 1
	return status
