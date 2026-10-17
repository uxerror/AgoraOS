extends AgoraProgram


func summary() -> String:
	return "send a signal to processes"


func usage() -> String:
	return "usage: kill [-signal] pid...\n       kill -l\nSignals: HUP(1) INT(2) KILL(9) TERM(15, default)"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var sig := AgoraProcess.SIGTERM
	if not args.is_empty() and args[0] == "-l":
		for n in AgoraProcess.SIGNAL_NAMES:
			p.outln("%2d) SIG%s" % [n, AgoraProcess.SIGNAL_NAMES[n]])
		return 0
	if not args.is_empty() and args[0].begins_with("-"):
		var spec := args[0].substr(1).to_upper().trim_prefix("SIG")
		args.remove_at(0)
		if spec.is_valid_int():
			sig = int(spec)
		else:
			sig = AgoraProcess.SIGNAL_NAMES.find_key(spec) if AgoraProcess.SIGNAL_NAMES.find_key(spec) != null else -1
		if sig <= 0:
			return p.fail("invalid signal '%s'" % spec)
	if args.is_empty():
		return p.fail("missing pid", 2)
	var status := 0
	for a in args:
		if not a.is_valid_int():
			status = p.fail("'%s': arguments must be process ids" % a)
			continue
		if p.machine.kill(int(a), sig, p.cred) != AgoraErrno.OK:
			status = p.fail("(%s) - %s" % [a, AgoraErrno.describe(p.machine.errno)])
	return status
