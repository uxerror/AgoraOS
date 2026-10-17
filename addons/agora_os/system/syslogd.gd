extends AgoraProgram
## System logger. Creates /dev/log; programs (and the kernel's log_event)
## write "facility|tag|message" lines to it, and syslogd appends them to the
## files chosen in /etc/syslog.conf. Kill it and nothing gets logged
## anymore, which an intruder may well want. SIGHUP rereads the config.

var p: AgoraProcess
var _rules: Array[Dictionary] = [] # {facilities: {name: true/false}, file}


func summary() -> String:
	return "system logging daemon"


func usage() -> String:
	return "usage: syslogd [-n]\n  -n  stay in the foreground (it always does)"


func main(proc: AgoraProcess) -> int:
	p = proc
	if p.stat("/dev/log") != null:
		return p.fail("already running")
	if not p.cred.is_root():
		return p.fail("must be root")
	_load_config()
	p.signal_handler = _on_signal
	p.machine.dev.add_device("log", _no_read, _on_message, 438) # 0o666
	p.exited.connect(_cleanup)
	_write("syslog", "syslogd", "syslogd started: version 1.5")
	while p.is_running():
		await p.sleep(3600.0)
	return 0


func _on_signal(sig: int) -> bool:
	if sig == AgoraProcess.SIGHUP:
		_load_config()
		_write("syslog", "syslogd", "configuration reloaded")
		return true
	return false


func _cleanup(_code: int) -> void:
	p.machine.dev.remove_device("log")


func _no_read() -> PackedByteArray:
	return PackedByteArray()


## /etc/syslog.conf lines: "selector[;selector...]  file", where a selector is
## "facility[,facility].level". Level "none" excludes the facility.
func _load_config() -> void:
	_rules.clear()
	for raw in p.read_text("/etc/syslog.conf").split("\n", false):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var fields := line.replace("\t", " ").split(" ", false)
		if fields.size() < 2:
			continue
		var facilities := {}
		for selector in fields[0].split(";"):
			var level := selector.get_slice(".", 1)
			for f in selector.get_slice(".", 0).split(","):
				facilities[f] = level != "none"
		_rules.append({"facilities": facilities, "file": fields[1].trim_prefix("-")})


func _on_message(data: PackedByteArray) -> void:
	if not p.is_running():
		return
	for line in data.get_string_from_utf8().split("\n", false):
		var parts := line.split("|", true, 2)
		if parts.size() == 3:
			_write(parts[0], parts[1], parts[2])


func _write(facility: String, tag: String, message: String) -> void:
	var m := p.machine
	var text := "%s %s %s: %s\n" % [m.clock.format_log(), m.hostname, tag, message]
	for rule in _rules:
		var f: Dictionary = rule.facilities
		var wanted: bool = f.get(facility, f.get("*", false))
		if f.has("*") and f.has(facility) and not f[facility]:
			wanted = false
		if wanted:
			m.vfs.write_text(p.cred, rule.file, text, "/", true, 416) # 0o640
			var root := AgoraCred.root()
			var st := m.vfs.stat(root, rule.file)
			if st and st.gid == 0:
				m.vfs.chown(root, rule.file, -1, 4) # group adm may read logs
