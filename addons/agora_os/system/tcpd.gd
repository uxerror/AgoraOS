extends AgoraProgram
## tcpd (tcp_wrappers 7.6): inetd starts it in front of a server. It checks
## the client against /etc/hosts.allow and /etc/hosts.deny, logs the
## connection to auth, and runs the real server (argv[0], or
## /usr/sbin/<argv[0]>) on the same connection, or drops it.
##
## Rules: "daemons : clients", one per line. Daemons: names or ALL.
## Clients: ALL, an address, a prefix ending in "." ("192.168.1."), a
## network "addr/mask", LOCAL (a name without a dot), with EXCEPT to cut
## out of a list. hosts.allow is read first; a match there allows, a match
## in hosts.deny refuses, anything else is allowed.

const REAL_DAEMON_DIR := "/usr/sbin"


func summary() -> String:
	return "access control facility for internet services"


func main(p: AgoraProcess) -> int:
	var daemon := AgoraPath.basename(p.argv[0])
	var path := p.argv[0] if p.argv[0].begins_with("/") else REAL_DAEMON_DIR + "/" + p.argv[0]
	var client := AgoraInet.to_str(p.socket.remote_addr) if p.socket else "unknown"
	var tag := "%s[%d]" % [daemon, p.pid]
	if not allowed(p, daemon, client):
		p.machine.log_event("auth", tag, "refused connect from %s (%s)" % [client, client])
		return 0
	p.machine.log_event("auth", tag, "connect from %s (%s)" % [client, client])
	var argv := PackedStringArray([path])
	argv.append_array(p.argv.slice(1))
	var child := p.machine.spawn(argv, {
		"cred": p.cred, "env": p.env, "stdin": p.stdin, "stdout": p.stdout, "stderr": p.stderr,
		"parent": p, "start": false,
	})
	if child == null:
		p.machine.log_event("auth", tag, "error: cannot execute %s: %s" % [path, AgoraErrno.describe(p.machine.errno)])
		return 1
	child.argv[0] = p.argv[0]
	child.socket = p.socket
	if p.socket:
		p.socket.pid = child.pid
	child.start()
	return await child.wait()


## hosts_access(3): may [param client] use [param daemon]?
static func allowed(p: AgoraProcess, daemon: String, client: String) -> bool:
	if _table_matches(p, "/etc/hosts.allow", daemon, client):
		return true
	return not _table_matches(p, "/etc/hosts.deny", daemon, client)


static func _table_matches(p: AgoraProcess, file: String, daemon: String, client: String) -> bool:
	if not p.exists(file):
		return false
	var text := p.read_text(file).replace("\\\n", " ")
	for line in text.split("\n", false):
		line = line.get_slice("#", 0).strip_edges()
		var parts := line.split(":")
		if parts.size() < 2:
			continue
		if _list_matches(parts[0], func(pat: String) -> bool: return pat == "ALL" or pat == daemon) \
				and _list_matches(parts[1], func(pat: String) -> bool: return _client_matches(pat, client)):
			return true
	return false


## A list of patterns, with EXCEPT taking out what follows.
static func _list_matches(list: String, matches: Callable) -> bool:
	var words := list.replace(",", " ").split(" ", false)
	var cut := words.find("EXCEPT")
	var head := words.slice(0, cut) if cut >= 0 else words
	var hit := false
	for w in head:
		if matches.call(w):
			hit = true
			break
	if not hit:
		return false
	if cut >= 0:
		return not _list_matches(" ".join(words.slice(cut + 1)), matches)
	return true


static func _client_matches(pat: String, client: String) -> bool:
	if pat == "ALL":
		return true
	if pat == "LOCAL":
		return not client.contains(".")
	if pat.ends_with("."):
		return client.begins_with(pat)
	if pat.contains("/"):
		var net := AgoraInet.parse(pat.get_slice("/", 0))
		var mask_text := pat.get_slice("/", 1)
		var mask := AgoraInet.mask(mask_text.to_int()) if mask_text.is_valid_int() else AgoraInet.parse(mask_text)
		var addr := AgoraInet.parse(client)
		return net >= 0 and addr >= 0 and mask >= 0 and (addr & mask) == (net & mask)
	return pat == client
