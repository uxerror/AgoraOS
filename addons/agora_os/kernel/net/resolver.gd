class_name AgoraResolver
extends RefCounted
## Host name lookups for programs, like glibc's resolver.
##
## The order comes from the "hosts:" line of /etc/nsswitch.conf ("files
## dns" if there is none): /etc/hosts, then DNS. DNS reads
## /etc/resolv.conf: up to three nameservers, search (or domain), and
## options timeout:N (default 5 seconds), attempts:N (default 2), ndots:N
## (default 1). Names with fewer dots than ndots try the search list
## first.
##
## Lookups are coroutines. Results are {addr} or {name} on success, or
## {error}: "NOTFOUND" (the name doesn't exist) or "AGAIN" (no server
## answered); [method message] gives the text programs print.

const TICK := 0.016


static func message(error: String) -> String:
	return "Temporary failure in name resolution" if error == "AGAIN" else "Name or service not known"


## Address of [param name]: {addr} or {error}.
static func resolve(p: AgoraProcess, name: String) -> Dictionary:
	var addr := AgoraInet.parse(name)
	if addr >= 0:
		return {"addr": addr}
	var error := "NOTFOUND"
	for source in _sources(p):
		if source == "files":
			var found := _from_files(p, name)
			if found >= 0:
				return {"addr": found}
		elif source == "dns":
			var r: Dictionary = await _search(p, name)
			if r.has("addr"):
				return r
			if r.error == "AGAIN":
				error = "AGAIN"
	return {"error": error}


## Address of [param name], or -1. For callers that don't care why.
static func lookup(p: AgoraProcess, name: String) -> int:
	var r: Dictionary = await resolve(p, name)
	return r.get("addr", -1)


## The name of [param addr] ("" if none): /etc/hosts, then a PTR query.
static func reverse(p: AgoraProcess, addr: int) -> String:
	for source in _sources(p):
		if source == "files":
			var name := reverse_files(p, addr)
			if not name.is_empty():
				return name
		elif source == "dns":
			var r: Dictionary = await query(p, AgoraDns.ptr_name(addr), "PTR")
			for rr: Dictionary in r.get("answer", []):
				if rr.type == "PTR":
					return rr.data
	return ""


## The address /etc/hosts gives [param name], or -1 (no DNS).
static func lookup_files(p: AgoraProcess, name: String) -> int:
	var addr := AgoraInet.parse(name)
	return addr if addr >= 0 else _from_files(p, name)


## The first name /etc/hosts gives [param addr], or "" (no DNS).
static func reverse_files(p: AgoraProcess, addr: int) -> String:
	for entry in _hosts(p):
		if entry[0] == addr:
			return entry[1][0]
	return ""


static func _sources(p: AgoraProcess) -> PackedStringArray:
	for line in p.read_text("/etc/nsswitch.conf").split("\n"):
		var words := line.get_slice("#", 0).strip_edges().replace("\t", " ").split(" ", false)
		if words.size() >= 2 and words[0] == "hosts:":
			return words.slice(1)
	return ["files", "dns"]


static func _from_files(p: AgoraProcess, name: String) -> int:
	var wanted := AgoraDns.normalize(name)
	for entry in _hosts(p):
		for n: String in entry[1]:
			if n.to_lower() == wanted:
				return entry[0]
	if wanted == "localhost":
		return AgoraInet.parse("127.0.0.1")
	return -1


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


## /etc/resolv.conf: {nameservers, search, timeout, attempts, ndots}.
static func config(p: AgoraProcess) -> Dictionary:
	var c := {"nameservers": [], "search": [], "timeout": 5.0, "attempts": 2, "ndots": 1}
	for line in p.read_text("/etc/resolv.conf").split("\n"):
		var words := line.get_slice("#", 0).get_slice(";", 0).strip_edges().replace("\t", " ").split(" ", false)
		if words.size() < 2:
			continue
		match words[0]:
			"nameserver":
				var ns := AgoraInet.parse(words[1])
				if ns >= 0 and c.nameservers.size() < 3:
					c.nameservers.append(ns)
			"search", "domain":
				c.search = Array(words.slice(1))
			"options":
				for opt in words.slice(1):
					var key := opt.get_slice(":", 0)
					var value := opt.get_slice(":", 1)
					if key in ["timeout", "attempts", "ndots"] and value.is_valid_int():
						c[key] = int(value) if key != "timeout" else float(value)
	if c.nameservers.is_empty():
		c.nameservers.append(AgoraInet.parse("127.0.0.1")) # glibc's default
	return c


## res_search: the name as given and with each search domain, in glibc's
## order, until one has an address.
static func _search(p: AgoraProcess, name: String) -> Dictionary:
	var c := config(p)
	var candidates: PackedStringArray = []
	if name.ends_with("."):
		candidates.append(name)
	else:
		var with_domains: PackedStringArray = []
		for d: String in c.search:
			with_domains.append("%s.%s" % [name, d])
		if name.count(".") >= c.ndots:
			candidates.append(name)
			candidates.append_array(with_domains)
		else:
			candidates.append_array(with_domains)
			candidates.append(name)
	var error := "NOTFOUND"
	for candidate in candidates:
		var r: Dictionary = await query(p, candidate, "A", c)
		if r.has("error"):
			if r.error == "AGAIN":
				error = "AGAIN"
				break # glibc gives up when no server answers
			continue
		for rr: Dictionary in r.answer:
			if rr.type == "A":
				return {"addr": AgoraInet.parse(rr.data), "name": rr.name}
	return {"error": error}


## The mail exchangers of [param domain], best first: [[preference, host]].
## Empty when it has none (or no answer came).
static func mx(p: AgoraProcess, domain: String) -> Array:
	var r: Dictionary = await query(p, domain, "MX")
	var out: Array = []
	for rr: Dictionary in r.get("answer", []):
		if rr.type == "MX":
			out.append([str(rr.data).get_slice(" ", 0).to_int(), str(rr.data).get_slice(" ", 1)])
	out.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	return out


## res_query: asks the nameservers in turn, [code]attempts[/code] rounds,
## waiting [code]timeout[/code] seconds for each. Returns the reply, or
## {error} ("NOTFOUND" for NXDOMAIN or no records, "AGAIN" when nobody
## answered or every server failed).
static func query(p: AgoraProcess, name: String, type: String, c: Dictionary = {}) -> Dictionary:
	if c.is_empty():
		c = config(p)
	var net := p.machine.net
	var sock := net.udp.open(p, 0)
	if sock == null:
		return {"error": "AGAIN"}
	var tree := Engine.get_main_loop() as SceneTree
	var result := {"error": "AGAIN"}
	for attempt in c.attempts:
		for ns: int in c.nameservers:
			var q := AgoraDns.query(AgoraDns.random_id(), name, type)
			if sock.sendto(ns, AgoraDns.PORT, q, AgoraDns.size(q)) != AgoraErrno.OK:
				continue
			var deadline := Time.get_ticks_msec() + int(c.timeout * 1000.0)
			var answer: Dictionary = {}
			var refused := false
			while answer.is_empty() and not refused and Time.get_ticks_msec() < deadline and not p.is_dead() and tree:
				# Port unreachable means nobody serves DNS there: next server.
				for e in sock.errors:
					if e.dst == ns:
						refused = true
				sock.errors.clear()
				while not sock.inbox.is_empty():
					var d: Dictionary = sock.inbox.pop_front()
					if d.src == ns and AgoraDns.is_valid(d.data) and d.data.id == q.id:
						answer = d.data
				if answer.is_empty():
					await tree.create_timer(TICK).timeout
			if answer.is_empty():
				continue
			answer.server = ns
			match answer.rcode:
				"NOERROR":
					result = answer if not (answer.answer as Array).is_empty() else {"error": "NOTFOUND", "reply": answer}
				"NXDOMAIN":
					result = {"error": "NOTFOUND", "reply": answer}
				_:
					result = {"error": "AGAIN", "reply": answer}
					continue # SERVFAIL, REFUSED: the next server may do better
			sock.close()
			return result
	sock.close()
	return result
