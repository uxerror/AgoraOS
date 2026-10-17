extends AgoraProgram
## dumpleases: prints udhcpd's binary lease file.


func summary() -> String:
	return "show the leases of udhcpd"


func usage() -> String:
	return "Usage: dumpleases -f <file> -[r|a]\n\n  -f, --file=FILENAME             Leases file to load\n  -r, --remaining                 Interpret lease times as time remaining\n  -a, --absolute                  Interpret lease times as expire time"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "f", ["file"])
	if a.has("h") or a.has("help") or not a.error.is_empty():
		p.outln(usage())
		return 0
	var file := a.value("f", a.value("file", "/var/lib/misc/udhcpd.leases"))
	var absolute := a.has("a") or a.has("absolute")
	if not p.exists(file):
		return p.fail("Unable to open %s for reading" % file, 1)
	var data := p.read_bytes(file)
	p.outln("Mac Address       IP-Address      Expires %s" % ("at" if absolute else "in"))
	for k in range(0, data.size() - 23, 24):
		var mac := "%02x:%02x:%02x:%02x:%02x:%02x" % [data[k], data[k + 1], data[k + 2], data[k + 3], data[k + 4], data[k + 5]]
		var addr := (data[k + 16] << 24) | (data[k + 17] << 16) | (data[k + 18] << 8) | data[k + 19]
		var expires := (data[k + 20] << 24) | (data[k + 21] << 16) | (data[k + 22] << 8) | data[k + 23]
		var line := "%s %-15s " % [mac, AgoraInet.to_str(addr)]
		if absolute:
			line += p.machine.clock.format_long(expires)
		elif expires == 0:
			line += "expired"
		else:
			if expires > 86400:
				line += "%d days, " % (expires / 86400)
				expires %= 86400
			if expires > 3600:
				line += "%d hours, " % (expires / 3600)
				expires %= 3600
			if expires > 60:
				line += "%d minutes, " % (expires / 60)
				expires %= 60
			line += "%d seconds" % expires
		p.outln(line)
	return 0
