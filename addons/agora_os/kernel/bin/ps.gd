extends AgoraProgram
## Reads everything from /proc, like the real ps.


func summary() -> String:
	return "list processes"


func usage() -> String:
	return "usage: ps [-e|aux]\nWithout options, shows your processes on this terminal. -e (or aux) shows all."


func main(p: AgoraProcess) -> int:
	var all := p.argv.size() > 1 and (p.argv[1] in ["-e", "-ef", "-A", "aux", "-aux", "ax"])
	var my_tty := p.tty.name if p.tty else "?"
	p.outln("%5s %-8s %-6s %-4s %s" % ["PID", "USER", "TTY", "STAT", "COMMAND"])
	var pids: Array[int] = []
	for entry in p.list_dir("/proc"):
		if entry.is_valid_int():
			pids.append(int(entry))
	pids.sort()
	for pid in pids:
		var name := str(pid)
		var status := _parse_status(p.read_text("/proc/%s/status" % name))
		if status.is_empty():
			continue
		var uid := int(status.get("Uid", "0").get_slice("\t", 1))
		var tty: String = status.get("Tty", "?")
		if not all and (tty != my_tty or uid != p.cred.uid):
			continue
		var cmd := p.read_text("/proc/%s/cmdline" % name).strip_edges()
		p.outln("%5s %-8s %-6s %-4s %s" % [name, p.machine.users.name_of(uid), tty, status.get("State", "?"), cmd])
	return 0


func _parse_status(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var idx := line.find(":")
		if idx > 0:
			out[line.substr(0, idx)] = line.substr(idx + 1).strip_edges()
	return out
