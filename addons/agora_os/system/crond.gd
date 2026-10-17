extends AgoraProgram
## Runs scheduled commands. Reads /etc/crontab ("m h dom mon dow user cmd")
## and the per-user tables in /var/spool/cron/crontabs/<user>
## ("m h dom mon dow cmd") every minute of game time, so a sped-up game
## clock makes cron fire faster too.
##
## Fields: "*", numbers, lists "1,5", ranges "1-5", steps "*/10".
## Shortcuts: @hourly, @daily, @weekly, @monthly, @yearly.

const SPOOL := "/var/spool/cron/crontabs"
const SHORTCUTS := {
	"@hourly": "0 * * * *", "@daily": "0 0 * * *", "@midnight": "0 0 * * *",
	"@weekly": "0 0 * * 0", "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *", "@annually": "0 0 1 1 *",
}

var p: AgoraProcess


func summary() -> String:
	return "daemon to run scheduled commands"


func usage() -> String:
	return "usage: crond [-n]"


func main(proc: AgoraProcess) -> int:
	p = proc
	if not p.cred.is_root():
		return p.fail("must be root")
	p.machine.log_event("cron", "cron[%d]" % p.pid, "(CRON) INFO (crond started)")
	var clock := p.machine.clock
	var last_minute := int(clock.now() / 60.0)
	while p.is_running():
		var now := clock.now()
		var minute := int(now / 60.0)
		if minute != last_minute:
			last_minute = minute
			_run_due(clock.local_datetime(minute * 60.0))
		# Wake at the next minute, but at least every second, so changes to
		# the game clock (jumps, speed) are noticed quickly.
		var left := 60.0 - fmod(now, 60.0)
		await p.sleep(clampf(left / maxf(clock.speed, 0.001), 0.05, 1.0))
	return 0


func _run_due(dt: Dictionary) -> void:
	for line in p.read_text("/etc/crontab").split("\n", false):
		var job := _parse(line, true)
		if not job.is_empty() and _matches(job.when, dt):
			_run(job.user, job.command)
	for user in p.list_dir(SPOOL):
		for line in p.read_text(SPOOL + "/" + user).split("\n", false):
			var job := _parse(line, false)
			if not job.is_empty() and _matches(job.when, dt):
				_run(user, job.command)


static func _parse(raw: String, with_user: bool) -> Dictionary:
	var line := raw.strip_edges()
	if line.is_empty() or line.begins_with("#"):
		return {}
	var words := line.replace("\t", " ").split(" ", false)
	if SHORTCUTS.has(words[0]):
		var expanded := (SHORTCUTS[words[0]] as String).split(" ")
		expanded.append_array(words.slice(1))
		words = expanded
	var need := 7 if with_user else 6
	if words.size() < need or words[0].contains("="):
		return {}
	return {
		"when": words.slice(0, 5),
		"user": words[5] if with_user else "",
		"command": " ".join(words.slice(need - 1)),
	}


static func _matches(when: PackedStringArray, dt: Dictionary) -> bool:
	var weekday: int = dt.weekday
	return _field(when[0], dt.minute, 0) and _field(when[1], dt.hour, 0) \
		and _field(when[2], dt.day, 1) and _field(when[3], dt.month, 1) \
		and (_field(when[4], weekday, 0) or (weekday == 0 and _field(when[4], 7, 0)))


static func _field(spec: String, value: int, low: int) -> bool:
	for part in spec.split(","):
		var step := 1
		var range_part := part
		if part.contains("/"):
			step = maxi(1, int(part.get_slice("/", 1)))
			range_part = part.get_slice("/", 0)
		var lo := low
		var hi := 59
		if range_part == "*":
			pass
		elif range_part.contains("-"):
			lo = int(range_part.get_slice("-", 0))
			hi = int(range_part.get_slice("-", 1))
		elif range_part.is_valid_int():
			lo = int(range_part)
			hi = lo if not part.contains("/") else 59
		else:
			continue
		if value >= lo and value <= hi and (value - lo) % step == 0:
			return true
	return false


func _run(user: String, command: String) -> void:
	var u := p.machine.users.find(user)
	if u.is_empty():
		return
	var child := p.machine.spawn(PackedStringArray(["/bin/sh", "-c", command]), {
		"cred": p.machine.users.cred_for(user), "cwd": u.home,
		"env": {"HOME": u.home, "USER": user, "LOGNAME": user, "SHELL": u.shell, "PATH": AgoraMachine.DEFAULT_PATH},
		"parent": p, "new_session": true,
	})
	if child:
		p.machine.log_event("cron", "CRON[%d]" % child.pid, "(%s) CMD (%s)" % [user, command])
