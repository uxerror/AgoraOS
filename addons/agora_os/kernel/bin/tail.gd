extends AgoraProgram


func summary() -> String:
	return "print the last lines of files"


func usage() -> String:
	return "usage: tail [-n count|+start] [file...]"


func main(p: AgoraProcess) -> int:
	var args := p.argv.duplicate()
	if args.size() > 1 and args[1].begins_with("-") and args[1].substr(1).is_valid_int():
		args[1] = "-n" + args[1].substr(1)
	var a := AgoraArgs.parse(args, "n")
	if not a.error.is_empty():
		return p.fail(a.error, 2)
	var spec := a.value("n", "10")
	var inputs := await read_inputs(p, a.operands)
	for i in inputs.size():
		if inputs.size() > 1:
			p.outln(("\n" if i > 0 else "") + "==> %s <==" % inputs[i][0])
		var lines := lines_of(inputs[i][1])
		var from := maxi(0, int(spec.substr(1)) - 1) if spec.begins_with("+") else maxi(0, lines.size() - int(spec))
		for l in lines.slice(from):
			p.outln(l)
	return 1 if input_failed else 0
