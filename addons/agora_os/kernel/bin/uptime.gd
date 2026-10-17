extends AgoraProgram


func summary() -> String:
	return "show how long the system has been running"


func main(p: AgoraProcess) -> int:
	var up := int(p.read_text("/proc/uptime").to_float())
	var d := p.machine.clock.local_datetime()
	var text := "%d min" % (up / 60) if up < 3600 else "%d:%02d" % [up / 3600, (up % 3600) / 60]
	if up >= 86400:
		text = "%d days, %s" % [up / 86400, "%d:%02d" % [(up % 86400) / 3600, (up % 3600) / 60]]
	p.outln(" %02d:%02d:%02d up %s" % [d.hour, d.minute, d.second, text])
	return 0
