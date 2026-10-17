extends AgoraProgram


func summary() -> String:
	return "print the first lines of files"


func usage() -> String:
	return "usage: head [-n count] [file...]"


func main(p: AgoraProcess) -> int:
	var args := p.argv.duplicate()
	if args.size() > 1 and args[1].begins_with("-") and args[1].substr(1).is_valid_int():
		args[1] = "-n" + args[1].substr(1)
	var a := AgoraArgs.parse(args, "n")
	if not a.error.is_empty():
		return p.fail(a.error, 2)
	var count := int(a.value("n", "10"))
	if a.operands.is_empty():
		# Read stdin lazily so "yes | head" stops the producer early.
		for i in count:
			var line: Variant = await p.read_line()
			if line == null:
				break
			p.outln(line)
		return 0
	var inputs := await read_inputs(p, a.operands)
	for i in inputs.size():
		if inputs.size() > 1:
			p.outln(("\n" if i > 0 else "") + "==> %s <==" % inputs[i][0])
		var lines := lines_of(inputs[i][1])
		for l in lines.slice(0, count):
			p.outln(l)
	return 1 if input_failed else 0
