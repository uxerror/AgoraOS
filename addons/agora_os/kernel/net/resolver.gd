class_name AgoraResolver
extends RefCounted
## Host name lookups for programs, like the C library's resolver: a dotted
## quad as is, then /etc/hosts, then the machine's name service.


## Address of [param name], or -1 if it can't be found.
static func lookup(p: AgoraProcess, name: String) -> int:
	var addr := AgoraInet.parse(name)
	if addr >= 0:
		return addr
	for entry in _hosts(p):
		if entry[1].has(name):
			return entry[0]
	if name == "localhost":
		return AgoraInet.parse("127.0.0.1")
	var legacy := p.machine.network
	if legacy:
		var ip := AgoraInet.parse(legacy.resolve(name))
		if ip >= 0:
			return ip
	return -1


## The first name /etc/hosts gives [param addr], or "".
static func reverse(p: AgoraProcess, addr: int) -> String:
	for entry in _hosts(p):
		if entry[0] == addr:
			return entry[1][0]
	return ""


## [[address, [names]]] from /etc/hosts.
static func _hosts(p: AgoraProcess) -> Array:
	var out: Array = []
	for line in p.read_text("/etc/hosts").split("\n", false):
		var words := line.get_slice("#", 0).strip_edges().replace("\t", " ").split(" ", false)
		if words.size() < 2:
			continue
		var addr := AgoraInet.parse(words[0])
		if addr >= 0:
			out.append([addr, words.slice(1)])
	return out
