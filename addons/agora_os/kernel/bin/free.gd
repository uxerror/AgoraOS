extends AgoraProgram


func summary() -> String:
	return "show memory usage"


func main(p: AgoraProcess) -> int:
	var info := {}
	for line in lines_of(p.read_text("/proc/meminfo")):
		var words := line.replace("\t", " ").split(" ", false)
		if words.size() >= 2:
			info[words[0].trim_suffix(":")] = int(words[1])
	var total: int = info.get("MemTotal", 0)
	var free: int = info.get("MemFree", 0)
	p.outln("%15s %11s %11s" % ["total", "used", "free"])
	p.outln("Mem: %10d %11d %11d" % [total, total - free, free])
	return 0
