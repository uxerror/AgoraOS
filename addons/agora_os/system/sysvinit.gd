extends AgoraProgram
## SysV-style init, the classic of the 2000s. Run as pid 1 through
## /sbin/init, it reads /etc/inittab:
##
##   id:runlevels:action:process
##
## Actions: initdefault, sysinit (run once at boot and wait), wait (run when
## entering the runlevel and wait), once (run, don't wait), respawn (keep it
## running). Runlevel scripts live in /etc/rcN.d as S##name / K##name links
## to /etc/init.d. Runlevel 0 powers off, 6 reboots.
##
## Not running as pid 1 (as telinit, or "init N" typed by root), it asks the
## running init to switch runlevel.

const RESPAWN_LIMIT := 10
const RESPAWN_WINDOW := 120.0
const RESPAWN_PAUSE := 300.0

var p: AgoraProcess
var entries: Array[Dictionary] = []
var runlevel := "N"
var _reply := ""
var _switching := false
var _pending := ""
var _console_out := AgoraStream.new()


func summary() -> String:
	return "SysV init (pid 1) and telinit"


func usage() -> String:
	return "usage: telinit RUNLEVEL\nRunlevels: 0 halt, 1 single user, 2-4 multi-user, 5 graphical, 6 reboot"


func main(proc: AgoraProcess) -> int:
	p = proc
	if p.pid != 1:
		if p.argv.size() < 2:
			return p.fail(usage(), 1)
		var reply: String = await AgoraInitCtl.send(p, "runlevel " + p.argv[1])
		return p.fail(AgoraInitCtl.message(reply)) if AgoraInitCtl.is_error(reply) else 0
	p.signal_handler = _ignore_signal
	p.machine.dev.add_device("initctl", _read_reply, _on_request, 384) # 0o600
	_console_out.add_reader()
	_console_out.changed.connect(_console_drain)
	_console("INIT: version 2.88 booting")
	entries = _parse_inittab(p.read_text("/etc/inittab"))
	var default_level := "3"
	for e in entries:
		if e.action == "initdefault" and not e.levels.is_empty():
			default_level = e.levels[0]
	for e in entries:
		if e.action == "sysinit":
			await _run(e, true)
	await switch_to(default_level)
	while p.is_running():
		await p.sleep(3600.0)
	return 0


func _ignore_signal(_sig: int) -> bool:
	return true


static func _parse_inittab(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in text.split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split(":", true, 3)
		if parts.size() < 4:
			continue
		out.append({"id": parts[0], "levels": parts[1], "action": parts[2], "process": parts[3],
			"proc": null, "spawns": [], "disabled_until": 0.0})
	return out


# --- control channel ----------------------------------------------------------

func _read_reply() -> PackedByteArray:
	var r := _reply
	_reply = ""
	return r.to_utf8_buffer()


func _on_request(data: PackedByteArray) -> void:
	for line in data.get_string_from_utf8().split("\n", false):
		var words := line.strip_edges().split(" ", false)
		if words.is_empty():
			continue
		var level := ""
		match words[0]:
			"poweroff", "halt": level = "0"
			"reboot": level = "6"
			"runlevel": level = words[1] if words.size() > 1 else ""
		if level.length() != 1 or not "0123456Ss".contains(level):
			_reply += "error: invalid runlevel '%s'\n" % level
			continue
		_reply += "ok\n"
		_switch_later("1" if level in ["S", "s"] else level)


func _switch_later(level: String) -> void:
	# Answer the caller first, switch on the next frame.
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.process_frame
	await switch_to(level)


# --- runlevels ----------------------------------------------------------------

func switch_to(level: String) -> void:
	if _switching:
		_pending = level
		return
	_switching = true
	var previous := runlevel
	runlevel = level
	_console("INIT: Entering runlevel: %s" % level)
	p.write_text("/run/runlevel", "%s %s\n" % [previous, level])
	# Processes from entries that don't belong to the new runlevel go away.
	for e in entries:
		if e.proc and not e.levels.contains(level):
			_stop(e)
	for e in entries:
		if not e.levels.contains(level) or not p.is_running():
			continue
		match e.action:
			"wait":
				await _run(e, true)
			"once":
				_run(e, false)
			"respawn":
				if e.proc == null:
					_respawn(e)
	_switching = false
	if level == "0" or level == "6":
		p.machine.power("reboot" if level == "6" else "poweroff", p)
		return
	if not _pending.is_empty():
		var next := _pending
		_pending = ""
		await switch_to(next)


func _spawn(e: Dictionary) -> AgoraProcess:
	return p.machine.spawn(PackedStringArray(["/bin/sh", "-c", e.process]), {
		"env": {"PATH": AgoraMachine.DEFAULT_PATH, "RUNLEVEL": runlevel, "HOME": "/root"},
		"stdin": AgoraStream.empty(), "stdout": _console_out, "stderr": _console_out,
		"parent": p, "new_session": true,
	})


func _run(e: Dictionary, wait: bool) -> void:
	var child := _spawn(e)
	if child and wait:
		await child.wait()


func _respawn(e: Dictionary) -> void:
	var now := p.machine.clock.now()
	if now < e.disabled_until or not e.levels.contains(runlevel) or not p.is_running():
		return
	e.spawns = (e.spawns as Array).filter(func(t: float) -> bool: return t > now - RESPAWN_WINDOW)
	if e.spawns.size() >= RESPAWN_LIMIT:
		_console("INIT: Id \"%s\" respawning too fast: disabled for 5 minutes" % e.id)
		e.disabled_until = now + RESPAWN_PAUSE
		_retry_later(e)
		return
	e.spawns.append(now)
	var child := _spawn(e)
	e.proc = child
	if child:
		child.exited.connect(_on_respawn_exit.bind(e, child), CONNECT_ONE_SHOT)


func _on_respawn_exit(_code: int, e: Dictionary, child: AgoraProcess) -> void:
	if e.proc != child:
		return
	e.proc = null
	if p.is_running():
		_respawn(e)


func _retry_later(e: Dictionary) -> void:
	await p.sleep(RESPAWN_PAUSE / maxf(p.machine.clock.speed, 0.001))
	if e.proc == null:
		_respawn(e)


func _stop(e: Dictionary) -> void:
	var child: AgoraProcess = e.proc
	e.proc = null
	if child and child.is_running():
		p.machine.kill_session(child.sid, AgoraProcess.SIGTERM)
		p.machine.kill_session(child.sid, AgoraProcess.SIGKILL)


# --- console ------------------------------------------------------------------

## Output of init scripts goes to the console, which here is the kernel log
## (see dmesg), where boot messages belong.
func _console_drain() -> void:
	for line in _console_out.read_available().split("\n", false):
		p.machine.klog(line)


func _console(message: String) -> void:
	p.machine.klog(message)
