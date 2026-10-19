extends AgoraProgram
## Controls the systemd-style service manager. Read-only commands (status,
## list-units, is-active) read files in /run/systemd and work for everyone;
## changes go through /dev/initctl and need root.


func summary() -> String:
	return "control the systemd service manager"


func usage() -> String:
	return """usage: systemctl COMMAND [UNIT...]
  status, start, stop, restart, is-active, is-enabled, is-failed,
  enable [--now], disable [--now], cat, list-units [--all], list-unit-files,
  daemon-reload, get-default, set-default TARGET, default, poweroff, reboot, halt"""


func main(p: AgoraProcess) -> int:
	if not p.exists("/run/systemd/system"):
		p.errln("System has not been booted with systemd as init system (PID 1). Can't operate.")
		p.errln("Failed to connect to bus: Host is down")
		return 1
	var a := AgoraArgs.parse(p.argv)
	var verb := a.operands[0] if not a.operands.is_empty() else "list-units"
	var names: PackedStringArray = []
	for n in a.operands.slice(1):
		names.append(AgoraUnits.normalize(n))
	match verb:
		"default":
			var reply: String = await AgoraInitCtl.send(p, "start " + AgoraPath.basename(p.realpath("/etc/systemd/system/default.target")))
			return p.fail("Failed to start default target: " + AgoraInitCtl.message(reply)) if AgoraInitCtl.is_error(reply) else 0
		"start", "stop", "restart", "try-restart", "reload":
			if names.is_empty():
				return p.fail("Too few arguments.")
			var status := 0
			for n in names:
				var reply: String = await AgoraInitCtl.send(p, "%s %s" % ["restart" if verb in ["try-restart", "reload"] else verb, n])
				if AgoraInitCtl.is_error(reply):
					p.errln("Failed to %s %s: %s" % [verb, n, AgoraInitCtl.message(reply)])
					if verb == "start":
						p.errln("See \"systemctl status %s\" and \"journalctl -u %s\" for details." % [n, n.trim_suffix(".service")])
					status = 1
			return status
		"status":
			var status := 0
			for i in names.size():
				if i > 0:
					p.outln()
				status = maxi(status, _status(p, names[i]))
			return status
		"is-active", "is-failed":
			var status := 1
			for n in names:
				var st := AgoraUnits.state(p, n).get("ActiveState", "inactive")
				p.outln(st)
				if (verb == "is-active" and st == "active") or (verb == "is-failed" and st == "failed"):
					status = 0
			return status
		"is-enabled":
			var status := 1
			for n in names:
				var unit := AgoraUnits.read_unit(p, n)
				if unit.is_empty():
					p.errln("Failed to get unit file state for %s: No such file or directory" % n)
					continue
				var e := AgoraUnits.enablement(p, unit)
				p.outln(e)
				if e == "enabled" or e == "static":
					status = 0
			return status
		"enable", "disable":
			return await _enable(p, names, verb == "enable", a.has("now"))
		"cat":
			for n in names:
				var path := AgoraUnits.find(p, n)
				if path.is_empty():
					p.errln("No files found for %s." % n)
					return 1
				p.outln("# " + path)
				p.out(p.read_text(path))
			return 0
		"list-units":
			return _list_units(p, a.has("all") or a.has("a"))
		"list-unit-files":
			return _list_unit_files(p)
		"daemon-reload":
			var reply: String = await AgoraInitCtl.send(p, "daemon-reload")
			return p.fail(AgoraInitCtl.message(reply)) if AgoraInitCtl.is_error(reply) else 0
		"get-default":
			p.outln(AgoraPath.basename(p.realpath(AgoraUnits.ADMIN_DIR + "/default.target")))
			return 0
		"set-default":
			if names.is_empty():
				return p.fail("Too few arguments.")
			var target := AgoraUnits.find(p, names[0])
			if target.is_empty():
				return p.fail("Unit %s not found." % names[0])
			var link := AgoraUnits.ADMIN_DIR + "/default.target"
			p.unlink(link)
			if p.symlink(target, link) != AgoraErrno.OK:
				return p.fail("Failed to set default target: %s" % AgoraErrno.describe(p.errno))
			p.outln("Created symlink %s → %s." % [link, target])
			return 0
		"poweroff", "reboot", "halt":
			var reply: String = await AgoraInitCtl.send(p, verb)
			return p.fail("Failed to %s system: %s" % [verb, AgoraInitCtl.message(reply)]) if AgoraInitCtl.is_error(reply) else 0
	return p.fail("Unknown command verb %s." % verb)


func _status(p: AgoraProcess, name: String) -> int:
	var unit := AgoraUnits.read_unit(p, name)
	if unit.is_empty():
		p.errln("Unit %s could not be found." % name)
		return 4
	var st := AgoraUnits.state(p, name)
	var active: String = st.get("ActiveState", "inactive")
	var sub: String = st.get("SubState", "dead")
	var dot := "●" if active in ["active", "failed", "activating"] else "○"
	p.outln("%s %s - %s" % [dot, name, AgoraUnits.value(unit, "Unit", "Description", name)])
	p.outln("     Loaded: loaded (%s; %s)" % [unit.path, AgoraUnits.enablement(p, unit)])
	var line := "     Active: %s (%s)" % [active, sub]
	if int(st.get("ActiveEnterTimestamp", "0")) > 0 and active != "inactive":
		line += " since " + p.machine.clock.format_long(int(st.ActiveEnterTimestamp))
	if active == "failed" and st.has("Result"):
		line += "; result: " + st.Result
	p.outln(line)
	if int(st.get("MainPID", "0")) > 0:
		var pid := st.MainPID as String
		p.outln("   Main PID: %s (%s)" % [pid, p.read_text("/proc/%s/cmdline" % pid).strip_edges().get_slice(" ", 0).get_file()])
	var journal := p.read_text(AgoraUnits.JOURNAL)
	if p.errno == AgoraErrno.OK:
		var ident := name.trim_suffix(".service")
		var lines: PackedStringArray = []
		for l in lines_of(journal):
			if l.contains(" %s[" % ident) or l.contains(" " + name):
				lines.append(l)
		if not lines.is_empty():
			p.outln()
			for l in lines.slice(maxi(0, lines.size() - 8)):
				p.outln(l)
	else:
		p.outln()
		p.outln("Hint: You are currently not seeing messages from other users and the system.")
		p.outln("      Users in group 'adm' can see all messages.")
	return 0 if active == "active" else 3


func _enable(p: AgoraProcess, names: PackedStringArray, enable: bool, now: bool) -> int:
	var status := 0
	for n in names:
		var unit := AgoraUnits.read_unit(p, n)
		if unit.is_empty():
			p.errln("Failed to %s unit: Unit file %s does not exist." % ["enable" if enable else "disable", n])
			status = 1
			continue
		var targets := AgoraUnits.list(unit, "Install", "WantedBy")
		if targets.is_empty():
			p.outln("The unit files have no installation config (WantedBy=), so they are not meant to be enabled.")
			continue
		for t in targets:
			var dir := "%s/%s.wants" % [AgoraUnits.ADMIN_DIR, t]
			var link := dir + "/" + n
			if enable:
				if p.stat(link, false) != null:
					continue
				if p.make_dirs(dir) != AgoraErrno.OK or p.symlink(unit.path, link) != AgoraErrno.OK:
					p.errln("Failed to enable unit: %s" % AgoraErrno.describe(p.errno))
					status = 1
					continue
				p.outln("Created symlink %s → %s." % [link, unit.path])
			elif p.stat(link, false) != null:
				if p.unlink(link) != AgoraErrno.OK:
					p.errln("Failed to disable unit: %s" % AgoraErrno.describe(p.errno))
					status = 1
					continue
				p.outln("Removed \"%s\"." % link)
		if now and status == 0:
			var reply: String = await AgoraInitCtl.send(p, "%s %s" % ["start" if enable else "stop", n])
			if AgoraInitCtl.is_error(reply):
				p.errln("Failed to %s %s: %s" % ["start" if enable else "stop", n, AgoraInitCtl.message(reply)])
				status = 1
	return status


func _list_units(p: AgoraProcess, all: bool) -> int:
	var rows: Array = [["UNIT", "ACTIVE", "SUB", "DESCRIPTION"]]
	for name in p.list_dir(AgoraUnits.STATE_DIR):
		var st := AgoraUnits.state(p, name)
		if not all and st.get("ActiveState", "") in ["inactive", ""]:
			continue
		rows.append([name, st.get("ActiveState", "?"), st.get("SubState", "?"), st.get("Description", "")])
	_table(p, rows)
	p.outln()
	p.outln("%d loaded units listed." % (rows.size() - 1))
	return 0


func _list_unit_files(p: AgoraProcess) -> int:
	var seen := {}
	var rows: Array = [["UNIT FILE", "STATE"]]
	for dir in AgoraUnits.SEARCH_PATHS:
		for name in p.list_dir(dir):
			if seen.has(name) or not (name.ends_with(".service") or name.ends_with(".target")):
				continue
			seen[name] = true
			var unit := AgoraUnits.read_unit(p, name)
			if not unit.is_empty():
				rows.append([name, AgoraUnits.enablement(p, unit)])
	var header: Array = rows.pop_front()
	rows.sort_custom(func(x: Array, y: Array) -> bool: return x[0] < y[0])
	rows.push_front(header)
	_table(p, rows)
	p.outln()
	p.outln("%d unit files listed." % (rows.size() - 1))
	return 0


func _table(p: AgoraProcess, rows: Array) -> void:
	var widths: Array[int] = []
	for r: Array in rows:
		for i in r.size():
			if widths.size() <= i:
				widths.append(0)
			widths[i] = maxi(widths[i], (r[i] as String).length())
	for r: Array in rows:
		var cells: PackedStringArray = []
		for i in r.size():
			cells.append((r[i] as String).rpad(widths[i]) if i < r.size() - 1 else r[i])
		p.outln(" ".join(cells))
