extends AgoraProgram
## getent: entries from the name service databases, the way programs see
## them (hosts: through nsswitch.conf, so /etc/hosts and DNS; passwd and
## group: the files).


func summary() -> String:
	return "get entries from Name Service Switch libraries"


func usage() -> String:
	return "Usage: getent [OPTION...] database [key ...]\nSupported databases: group hosts passwd"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	if args.is_empty():
		p.errln(usage())
		return 1
	var db := args[0]
	var keys := args.slice(1)
	match db:
		"hosts", "ahosts":
			if keys.is_empty():
				for line in p.read_text("/etc/hosts").split("\n", false):
					var words := line.get_slice("#", 0).strip_edges().replace("\t", " ").split(" ", false)
					if words.size() >= 2:
						p.outln("%-15s %s" % [words[0], " ".join(words.slice(1))])
				return 0
			var status := 0
			for key in keys:
				var addr := AgoraInet.parse(key)
				if addr >= 0:
					var name: String = await AgoraResolver.reverse(p, addr)
					if name.is_empty():
						status = 2
						continue
					p.outln("%-15s %s" % [key, name])
					continue
				var r: Dictionary = await AgoraResolver.resolve(p, key)
				if r.has("error"):
					status = 2
					continue
				p.outln("%-15s %s" % [AgoraInet.to_str(r.addr), r.get("name", key)])
			return status
		"passwd", "group":
			var lines := p.read_text("/etc/" + db).split("\n", false)
			if keys.is_empty():
				for line in lines:
					p.outln(line)
				return 0
			var status := 0
			for key in keys:
				var found := false
				for line in lines:
					var f := line.split(":")
					if f[0] == key or (f.size() > 2 and f[2] == key):
						p.outln(line)
						found = true
				if not found:
					status = 2
			return status
	p.errln("Unknown database: %s" % db)
	p.errln("Try `getent --help' or `getent --usage' for more information.")
	return 1
