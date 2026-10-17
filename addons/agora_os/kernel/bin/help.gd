extends AgoraProgram


func summary() -> String:
	return "list commands or show how to use one"


func usage() -> String:
	return "usage: help [command]"


func main(p: AgoraProcess) -> int:
	if p.argv.size() > 1:
		var script := AgoraPrograms.lookup(p.argv[1])
		if script == null:
			return p.fail("no help for '%s'" % p.argv[1])
		var prog: AgoraProgram = script.new()
		p.outln("%s - %s" % [p.argv[1], prog.summary()])
		if not prog.usage().is_empty():
			p.outln(prog.usage())
		return 0
	p.outln("Commands in /bin (try 'help <command>'):")
	for name in AgoraPrograms.names():
		if not p.exists("/bin/" + name):
			continue
		var prog: AgoraProgram = AgoraPrograms.lookup(name).new()
		p.outln("  %-10s %s" % [name, prog.summary()])
	p.outln("Shell builtins: cd, export, unset, local, alias, history, source, eval, read, jobs, wait,")
	p.outln("  break, continue, return, exit. Syntax: if/elif/else/fi, while/until ... do ... done,")
	p.outln("  for x in ...; do ... done, case ... esac, name() { ... }, $((arithmetic)), $(command)")
	return 0
