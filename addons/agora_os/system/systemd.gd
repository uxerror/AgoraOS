extends AgoraProgram
## systemd-style service manager, run as pid 1 through /sbin/init.
##
## - Units: *.service and *.target files (see [AgoraUnits]).
## - Starting a unit pulls in Requires= and Wants= (plus .wants/ links),
##   orders the set by After=/Before= and starts it.
## - Services run in their own session, so stopping one kills everything it
##   spawned (a stand-in for cgroups). Restart= is honored, with a limit of
##   5 restarts in 10 seconds.
## - Output of services goes to the journal, /var/log/journal/system.journal.
## - State of each unit is written to /run/systemd/units/<unit>.
## - Requests come through /dev/initctl (see [AgoraInitCtl]).

const VERSION := "agora-systemd 0.1"
const RESTART_BURST := 5
const RESTART_INTERVAL := 10.0
const RUNLEVEL_TARGETS := {
	"2": "multi-user.target", "3": "multi-user.target", "4": "multi-user.target", "5": "graphical.target",
}
## Kernel command line words that pick the target to boot.
const BOOT_TARGETS := {
	"single": "rescue.target", "s": "rescue.target", "S": "rescue.target", "1": "rescue.target",
	"emergency": "emergency.target", "-b": "emergency.target",
}


## Turns a service's output into journal lines.
class JournalPipe:
	var stream := AgoraStream.new()
	var ident: String
	var pid := 0
	var sink: Callable
	var _partial := ""

	func _init(p_sink: Callable, p_ident: String) -> void:
		sink = p_sink
		ident = p_ident
		stream.add_reader()
		stream.changed.connect(_drain)

	func _drain() -> void:
		var lines := (_partial + stream.read_available()).split("\n")
		_partial = lines[-1]
		for i in lines.size() - 1:
			sink.call(ident, pid, lines[i])


var p: AgoraProcess
var units := {} # name -> runtime state
var _active_order: PackedStringArray = []
var _reply := ""
var _jobs := {} # unit -> result of its last request, "pending" while it runs
var _shutting_down := false


func summary() -> String:
	return "system and service manager (pid 1)"


func main(proc: AgoraProcess) -> int:
	p = proc
	if p.pid != 1:
		if p.argv.has("--version"):
			p.outln(VERSION)
			return 0
		# "init 3" typed by root: behave like telinit.
		if p.argv.size() > 1:
			var reply: String = await AgoraInitCtl.send(p, "runlevel " + p.argv[1])
			return p.fail(AgoraInitCtl.message(reply)) if AgoraInitCtl.is_error(reply) else 0
		return p.fail("this program runs as process 1; use systemctl")
	p.signal_handler = _ignore_signal
	p.make_dirs("/run/systemd/system") # marks "booted with systemd" for systemctl
	p.make_dirs(AgoraUnits.STATE_DIR)
	p.machine.dev.add_device("initctl", _read_reply, _on_request, 384) # 0o600
	var target := _boot_target()
	if target != "emergency.target":
		_remount_root()
	_journal("systemd", 1, "%s running in system mode." % VERSION)
	var result: String = await start(target)
	if AgoraInitCtl.is_error(result):
		_journal("systemd", 1, "Failed to start default target: %s" % AgoraInitCtl.message(result))
	p.write_text("/run/runlevel", "N %s\n" % _runlevel_of(target))
	while p.is_running():
		await p.sleep(3600.0)
	return 0


func _ignore_signal(_sig: int) -> bool:
	return true


func _default_target() -> String:
	var path := AgoraUnits.find(p, "default.target")
	if path.is_empty():
		return "multi-user.target"
	return AgoraPath.basename(p.realpath(path))


## The target to boot: "systemd.unit=" from the kernel command line, a
## runlevel or "single" given to init, else default.target.
func _boot_target() -> String:
	var unit: String = p.env.get("systemd.unit", "")
	if not unit.is_empty():
		return AgoraUnits.normalize(unit)
	var target := ""
	for arg in p.argv.slice(1):
		target = BOOT_TARGETS.get(arg, RUNLEVEL_TARGETS.get(arg, target))
	return target if not target.is_empty() else _default_target()


## systemd-remount-fs: the kernel mounted / read-only ("ro"); make it
## writable unless the medium itself is read-only.
func _remount_root() -> void:
	var fs := p.machine.vfs.get_mount("/")
	if fs and fs.read_only and not p.machine.root_disk.read_only:
		fs.read_only = false


func _runlevel_of(target: String) -> String:
	match target:
		"graphical.target": return "5"
		"rescue.target": return "1"
		"emergency.target": return "S"
	return "3"


# --- control channel ----------------------------------------------------------

func _read_reply() -> PackedByteArray:
	var r := _reply
	_reply = ""
	return r.to_utf8_buffer()


func _on_request(data: PackedByteArray) -> void:
	for line in data.get_string_from_utf8().split("\n", false):
		_reply += _handle(line.strip_edges()) + "\n"


func _handle(line: String) -> String:
	var words := line.split(" ", false)
	if words.is_empty():
		return "error: empty request"
	var verb := words[0]
	var unit := AgoraUnits.normalize(words[1]) if words.size() > 1 else ""
	match verb:
		"start", "stop", "restart":
			return _job(verb, unit)
		"job":
			var r: String = _jobs.get(unit, "error: no job for %s" % unit)
			if r != "pending":
				_jobs.erase(unit)
			return r if r != "pending" else "wait " + unit
		"daemon-reload":
			for name in units:
				units[name].cfg = AgoraUnits.read_unit(p, name)
			return "ok"
		"poweroff", "halt", "reboot":
			_power_later(verb)
			return "ok"
		"runlevel":
			var level := words[1] if words.size() > 1 else ""
			match level:
				"0": _power_later("poweroff")
				"6": _power_later("reboot")
				_:
					if not RUNLEVEL_TARGETS.has(level):
						return "error: runlevel %s is not supported" % level
					p.write_text("/run/runlevel", "N %s\n" % level)
					return _job("start", RUNLEVEL_TARGETS[level])
			return "ok"
	return "error: unknown request '%s'" % verb


# --- starting -----------------------------------------------------------------

func _unit(name: String) -> Dictionary:
	if not units.has(name):
		var cfg := AgoraUnits.read_unit(p, name)
		if cfg.is_empty():
			return {}
		units[name] = {
			"name": name, "cfg": cfg, "state": "inactive", "sub": "dead", "proc": null,
			"pid": 0, "since": 0, "result": "", "restarts": [], "stopping": false, "pipe": null,
		}
	return units[name]


## Runs a start/stop/restart request. Returns its result, or "wait UNIT"
## if it is still going; the client then polls with "job UNIT".
func _job(verb: String, unit: String) -> String:
	_jobs[unit] = "pending"
	_run_job(verb, unit)
	var r: String = _jobs[unit]
	if r == "pending":
		return "wait " + unit
	_jobs.erase(unit)
	return r


func _run_job(verb: String, unit: String) -> void:
	var r := ""
	match verb:
		"start":
			r = await start(unit)
		"stop":
			r = await stop(unit)
		"restart":
			await stop(unit)
			r = await start(unit)
	_jobs[unit] = r


## Starts [param name] and everything it requires or wants. Units ordered
## after a oneshot service wait until it has finished.
func start(name: String) -> String:
	var order: Array[String] = []
	var err := _collect(name, true, order, {})
	if not err.is_empty():
		return "error: " + err
	var sorted := _sorted(order)
	var after := {}
	for u in sorted:
		after[u] = []
	for u in sorted:
		for a in AgoraUnits.list(units[u].cfg, "Unit", "After"):
			if after.has(a):
				after[u].append(a)
		for b in AgoraUnits.list(units[u].cfg, "Unit", "Before"):
			if after.has(b):
				after[b].append(u)
	var done := {}
	var results := {}
	for u in sorted:
		_bring_up(u, after[u], done, results)
	while done.size() < sorted.size() and p.is_running() and not _shutting_down:
		await p.sleep(0.05)
	var failed: String = results.get(name, "")
	if failed.is_empty() and units[name].state == "failed":
		failed = "Job for %s failed because the control process exited with error code.\nSee \"systemctl status %s\" and \"journalctl -xe\" for details." % [name, name]
	return "ok" if failed.is_empty() else "error: " + failed


## Activates [param name] once the units it is ordered after are up; a
## oneshot service counts as up when it has finished.
func _bring_up(name: String, deps: Array, done: Dictionary, results: Dictionary) -> void:
	for d: String in deps:
		while not done.has(d) and p.is_running() and not _shutting_down:
			await p.sleep(0.05)
	results[name] = _activate(name)
	var unit: Dictionary = units[name]
	while unit.state == "activating" and unit.sub == "start" and p.is_running() and not _shutting_down:
		await p.sleep(0.05)
	done[name] = true


func _collect(name: String, required: bool, order: Array[String], seen: Dictionary) -> String:
	if seen.has(name):
		return ""
	seen[name] = true
	var u := _unit(name)
	if u.is_empty():
		if required:
			return "Unit %s not found." % name
		_journal("systemd", 1, "Wanted unit %s not found, skipping." % name)
		return ""
	var requires := AgoraUnits.list(u.cfg, "Unit", "Requires")
	requires.append_array(AgoraUnits.linked(p, name, "requires"))
	for dep in requires:
		var e := _collect(dep, true, order, seen)
		if not e.is_empty():
			return e
	var wants := AgoraUnits.list(u.cfg, "Unit", "Wants")
	wants.append_array(AgoraUnits.linked(p, name, "wants"))
	for dep in wants:
		_collect(dep, false, order, seen)
	order.append(name)
	return ""


## Orders units so After=/Before= hold. Dependencies already come first;
## ties keep that order. A cycle falls back to dependency order.
func _sorted(order: Array[String]) -> Array[String]:
	var index := {}
	for i in order.size():
		index[order[i]] = i
	var edges := {}
	var indegree := {}
	for u in order:
		edges[u] = []
		indegree[u] = 0
	for u in order:
		var cfg: Dictionary = units[u].cfg
		for a in AgoraUnits.list(cfg, "Unit", "After"):
			if index.has(a):
				edges[a].append(u)
				indegree[u] += 1
		for b in AgoraUnits.list(cfg, "Unit", "Before"):
			if index.has(b):
				edges[u].append(b)
				indegree[b] += 1
	var out: Array[String] = []
	var ready: Array[String] = []
	for u in order:
		if indegree[u] == 0:
			ready.append(u)
	while not ready.is_empty():
		ready.sort_custom(func(a: String, b: String) -> bool: return index[a] < index[b])
		var u: String = ready.pop_front()
		out.append(u)
		for v: String in edges[u]:
			indegree[v] -= 1
			if indegree[v] == 0:
				ready.append(v)
	if out.size() < order.size():
		_journal("systemd", 1, "Ordering cycle found, using dependency order.")
		return order
	return out


func _activate(name: String) -> String:
	var u: Dictionary = units[name]
	if u.state in ["active", "activating"] or _shutting_down:
		return ""
	for cond in AgoraUnits.list(u.cfg, "Unit", "ConditionPathExists"):
		var negate := cond.begins_with("!")
		if p.exists(cond.trim_prefix("!")) == negate:
			u.state = "inactive"
			u.sub = "dead"
			u.result = "condition"
			_journal("systemd", 1, "%s was skipped because of an unmet condition check (ConditionPathExists=%s)." % [name, cond])
			_save(u)
			return ""
	if name.ends_with(".target"):
		u.state = "active"
		u.sub = "active"
		u.since = p.machine.clock.now_int()
		_mark_active(name)
		_journal("systemd", 1, "Reached target %s - %s." % [name, _description(u)])
		_save(u)
		return ""
	if name.ends_with(".service"):
		return _start_service(u)
	return "unit type of %s is not supported" % name


func _start_service(u: Dictionary) -> String:
	var name: String = u.name
	var exec := AgoraUnits.value(u.cfg, "Service", "ExecStart")
	if exec.is_empty():
		return _fail_unit(u, "resources", "%s has no ExecStart= setting." % name)
	var user := AgoraUnits.value(u.cfg, "Service", "User", "root")
	var cred := p.machine.users.cred_for(user)
	if cred == null:
		return _fail_unit(u, "resources", "Failed to determine user credentials: %s" % user)
	var home: String = p.machine.users.find(user).get("home", "/")
	var env := {"PATH": AgoraMachine.DEFAULT_PATH, "HOME": home, "USER": user, "LOGNAME": user}
	for assignment in AgoraUnits.list(u.cfg, "Service", "Environment"):
		var eq := assignment.find("=")
		if eq > 0:
			env[assignment.substr(0, eq)] = assignment.substr(eq + 1)
	var pipe := JournalPipe.new(_journal, name.trim_suffix(".service"))
	var child := p.machine.spawn(AgoraUnits.split_command(exec), {
		"cred": cred, "env": env, "cwd": AgoraUnits.value(u.cfg, "Service", "WorkingDirectory", "/"),
		"stdin": AgoraStream.empty(), "stdout": pipe.stream, "stderr": pipe.stream,
		"parent": p, "new_session": true, "start": false,
	})
	if child == null:
		return _fail_unit(u, "exit-code", "Failed to execute %s: %s" % [exec, AgoraErrno.describe(p.machine.errno)])
	pipe.pid = child.pid
	u.proc = child
	u.pid = child.pid
	u.pipe = pipe
	u.stopping = false
	u.since = p.machine.clock.now_int()
	var oneshot := AgoraUnits.value(u.cfg, "Service", "Type", "simple") == "oneshot"
	u.state = "activating" if oneshot else "active"
	u.sub = "start" if oneshot else "running"
	_mark_active(name)
	if not oneshot:
		_journal("systemd", 1, "Started %s - %s." % [name, _description(u)])
	_save(u)
	child.exited.connect(_on_exit.bind(name, child), CONNECT_ONE_SHOT)
	child.start()
	return ""


func _fail_unit(u: Dictionary, result: String, message: String) -> String:
	u.state = "failed"
	u.sub = "failed"
	u.result = result
	_journal("systemd", 1, message)
	_journal("systemd", 1, "Failed to start %s - %s." % [u.name, _description(u)])
	_save(u)
	return message


func _on_exit(code: int, name: String, child: AgoraProcess) -> void:
	var u: Dictionary = units.get(name, {})
	if u.is_empty() or u.proc != child:
		return
	u.proc = null
	u.pid = 0
	u.pipe = null
	if u.stopping or _shutting_down:
		return
	if AgoraUnits.value(u.cfg, "Service", "Type", "simple") == "oneshot":
		if code == 0:
			var remain := AgoraUnits.value(u.cfg, "Service", "RemainAfterExit", "no") in ["yes", "true", "1"]
			u.state = "active" if remain else "inactive"
			u.sub = "exited" if remain else "dead"
			u.result = "success"
			_journal("systemd", 1, "Finished %s - %s." % [name, _description(u)])
			_save(u)
		else:
			_fail_unit(u, "exit-code", "%s: Main process exited, code=exited, status=%d" % [name, code])
		return
	u.result = "success" if code == 0 else "exit-code"
	if code != 0:
		_journal("systemd", 1, "%s: Main process exited, code=exited, status=%d" % [name, code])
	var policy := AgoraUnits.value(u.cfg, "Service", "Restart", "no")
	if policy == "always" or (policy == "on-failure" and code != 0):
		var now := p.machine.clock.now()
		u.restarts = (u.restarts as Array).filter(func(t: float) -> bool: return t > now - RESTART_INTERVAL)
		if u.restarts.size() >= RESTART_BURST:
			_fail_unit(u, "start-limit-hit", "%s: Start request repeated too quickly." % name)
			return
		u.restarts.append(now)
		u.state = "activating"
		u.sub = "auto-restart"
		_save(u)
		_restart_later(name, float(AgoraUnits.value(u.cfg, "Service", "RestartSec", "0.1")))
		return
	u.state = "failed" if code != 0 else "inactive"
	u.sub = "failed" if code != 0 else "dead"
	if code != 0:
		_journal("systemd", 1, "%s: Failed with result 'exit-code'." % name)
	_save(u)


func _restart_later(name: String, delay: float) -> void:
	await p.sleep(delay)
	var u: Dictionary = units.get(name, {})
	if p.is_running() and not u.is_empty() and u.sub == "auto-restart":
		u.state = "inactive"
		_activate(name)


# --- stopping -----------------------------------------------------------------

func stop(name: String) -> String:
	var u: Dictionary = units.get(name, {})
	if u.is_empty():
		return "ok" if not AgoraUnits.find(p, name).is_empty() else "error: Unit %s not loaded." % name
	var exec_stop := AgoraUnits.value(u.cfg, "Service", "ExecStop")
	if not exec_stop.is_empty() and u.state == "active":
		_journal("systemd", 1, "Stopping %s - %s..." % [name, _description(u)])
		var pipe := JournalPipe.new(_journal, name.trim_suffix(".service"))
		var child := p.machine.spawn(AgoraUnits.split_command(exec_stop), {
			"env": {"PATH": AgoraMachine.DEFAULT_PATH}, "stdin": AgoraStream.empty(),
			"stdout": pipe.stream, "stderr": pipe.stream, "parent": p, "new_session": true,
		})
		if child:
			pipe.pid = child.pid
			await child.wait()
	if u.proc and (u.proc as AgoraProcess).is_running():
		u.stopping = true
		_journal("systemd", 1, "Stopping %s - %s..." % [name, _description(u)])
		var sid: int = u.proc.sid
		p.machine.kill_session(sid, AgoraProcess.SIGTERM)
		p.machine.kill_session(sid, AgoraProcess.SIGKILL)
	if u.state != "inactive" or u.sub != "dead":
		_journal("systemd", 1, "Stopped %s - %s." % [name, _description(u)])
	u.state = "inactive"
	u.sub = "dead"
	u.stopping = false
	if _active_order.has(name):
		_active_order.remove_at(_active_order.find(name))
	_save(u)
	return "ok"


func _power_later(verb: String) -> void:
	# Reply to the caller first; shut down on the next frame.
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.process_frame
	if _shutting_down or not p.is_running():
		return
	_shutting_down = true
	_journal("systemd", 1, "System is %s." % {"poweroff": "powering down", "halt": "halting", "reboot": "rebooting"}[verb])
	for i in range(_active_order.size() - 1, -1, -1):
		await stop(_active_order[i])
	p.machine.power(verb, p)


# --- bookkeeping --------------------------------------------------------------

func _mark_active(name: String) -> void:
	if not _active_order.has(name):
		_active_order.append(name)


func _description(u: Dictionary) -> String:
	return AgoraUnits.value(u.cfg, "Unit", "Description", u.name)


func _save(u: Dictionary) -> void:
	var lines: PackedStringArray = [
		"Id=" + u.name,
		"Description=" + _description(u),
		"FragmentPath=" + u.cfg.path,
		"ActiveState=" + u.state,
		"SubState=" + u.sub,
		"MainPID=%d" % u.pid,
		"ActiveEnterTimestamp=%d" % u.since,
		"Result=" + u.result,
	]
	p.write_text(AgoraUnits.STATE_DIR + "/" + u.name, "\n".join(lines) + "\n")


## Appends a line to the journal. Readable by root and group adm.
func _journal(ident: String, pid: int, message: String) -> void:
	var root := AgoraCred.root()
	var vfs := p.machine.vfs
	if not vfs.exists(root, AgoraUnits.JOURNAL):
		vfs.make_dirs(root, AgoraPath.dirname(AgoraUnits.JOURNAL))
		vfs.write_text(root, AgoraUnits.JOURNAL, "", "/", false, 416) # 0o640
		vfs.chown(root, AgoraUnits.JOURNAL, 0, 4)
	var line := "%s %s %s[%d]: %s\n" % [p.machine.clock.format_log(), p.machine.hostname, ident, pid, message]
	vfs.write_text(root, AgoraUnits.JOURNAL, line, "/", true)
