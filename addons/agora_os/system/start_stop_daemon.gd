extends AgoraProgram
## Starts or stops a background daemon tracked by a pid file, as used by the
## scripts in /etc/init.d.


func summary() -> String:
	return "start and stop system daemons"


func usage() -> String:
	return """usage: start-stop-daemon --start --exec PATH [--pidfile FILE] [--chuid USER] [-- ARGS]
       start-stop-daemon --stop --pidfile FILE [--signal SIG]
  --oknodo  exit 0 when there is nothing to do"""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "pxcs", PackedStringArray(["pidfile", "exec", "chuid", "signal", "name", "startas"]))
	if not a.error.is_empty():
		return p.fail(a.error, 2)
	var pidfile := a.value("p", a.value("pidfile"))
	var oknodo := a.has("o") or a.has("oknodo")
	var running := _running_pid(p, pidfile)
	if a.has("S") or a.has("start"):
		var exec := a.value("x", a.value("exec", a.value("startas")))
		if exec.is_empty():
			return p.fail("--exec is required", 2)
		if running > 0:
			p.outln("%s already running." % AgoraPath.basename(exec))
			return 0 if oknodo else 1
		var argv := PackedStringArray([exec])
		argv.append_array(a.operands)
		var user := a.value("c", a.value("chuid", "root"))
		var cred := p.machine.users.cred_for(user)
		if cred == null:
			return p.fail("user '%s' not found" % user, 2)
		if user != "root" and not p.cred.is_root():
			return p.fail("only root can change user", 2)
		# Detached: own session, parent becomes init, no terminal.
		var child := p.machine.spawn(argv, {
			"cred": cred if user != "root" else p.cred, "env": {"PATH": AgoraMachine.DEFAULT_PATH},
			"cwd": "/", "new_session": true,
		})
		if child == null:
			return p.fail("unable to start %s: %s" % [exec, AgoraErrno.describe(p.machine.errno)], 2)
		if not pidfile.is_empty() and p.write_text(pidfile, "%d\n" % child.pid) != AgoraErrno.OK:
			p.fail("cannot write %s: %s" % [pidfile, AgoraErrno.describe(p.errno)])
		return 0
	if a.has("K") or a.has("stop"):
		if running <= 0:
			p.outln("No process in pidfile '%s' found running; none killed." % pidfile)
			return 0 if oknodo else 1
		var sig_name := a.value("s", a.value("signal", "TERM")).to_upper().trim_prefix("SIG")
		var sig := AgoraProcess.SIGTERM
		if sig_name.is_valid_int():
			sig = int(sig_name)
		elif AgoraProcess.SIGNAL_NAMES.find_key(sig_name) != null:
			sig = AgoraProcess.SIGNAL_NAMES.find_key(sig_name)
		var target := p.machine.get_process(running)
		var sid := target.sid
		if p.machine.kill(running, 0, p.cred) != AgoraErrno.OK:
			return p.fail("cannot kill %d: %s" % [running, AgoraErrno.describe(p.machine.errno)], 2)
		p.machine.kill_session(sid, sig) # the daemon and anything it started
		p.unlink(pidfile)
		return 0
	return p.fail("need one of --start or --stop", 2)


static func _running_pid(p: AgoraProcess, pidfile: String) -> int:
	if pidfile.is_empty():
		return 0
	var text := p.read_text(pidfile).strip_edges()
	if not text.is_valid_int():
		return 0
	return int(text) if p.machine.get_process(int(text)) != null else 0
