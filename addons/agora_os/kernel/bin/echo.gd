extends AgoraProgram


func summary() -> String:
	return "print arguments"


func usage() -> String:
	return "usage: echo [-n] [-e] [text...]\n  -n  no trailing newline\n  -e  interpret \\n, \\t, \\e (escape) and \\\\"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var newline := true
	var escapes := false
	while not args.is_empty() and args[0] in ["-n", "-e", "-ne", "-en"]:
		if args[0].contains("n"):
			newline = false
		if args[0].contains("e"):
			escapes = true
		args.remove_at(0)
	var text := " ".join(args)
	if escapes:
		text = text.replace("\\n", "\n").replace("\\t", "\t").replace("\\e", "\u001b") \
			.replace("\\033", "\u001b").replace("\\\\", "\\")
	p.out(text + ("\n" if newline else ""))
	return 0
