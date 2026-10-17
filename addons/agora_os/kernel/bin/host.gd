extends AgoraProgram
## host (BIND 9.16): a short DNS lookup. DNS only, /etc/hosts is not read.


func summary() -> String:
	return "DNS lookup utility"


func usage() -> String:
	return "Usage: host [-t type] hostname [server]"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "tW")
	if a.operands.is_empty():
		p.errln(usage())
		return 1
	var c := AgoraResolver.config(p)
	if a.has("W") and a.value("W").is_valid_float():
		c.timeout = float(a.value("W"))
	if a.operands.size() > 1:
		var server: int = await AgoraResolver.lookup(p, a.operands[1])
		if server < 0:
			p.errln("host: couldn't get address for '%s': not found" % a.operands[1])
			return 1
		c.nameservers = [server]
		p.outln("Using domain server:")
		p.outln("Name: %s" % a.operands[1])
		p.outln("Address: %s#53" % AgoraInet.to_str(server))
		p.outln("Aliases: ")
		p.outln("")
	var name := a.operands[0]
	var addr := AgoraInet.parse(name)
	var type := a.value("t", "PTR" if addr >= 0 else "A").to_upper()
	var qname := AgoraDns.ptr_name(addr) if addr >= 0 else name
	var candidates: PackedStringArray = [qname]
	if addr < 0 and not name.ends_with(".") and name.count(".") < c.ndots:
		candidates.clear()
		for d: String in c.search:
			candidates.append("%s.%s" % [name, d])
		candidates.append(name)
	var r := {}
	for candidate in candidates:
		r = await AgoraResolver.query(p, candidate, type, c)
		if not r.has("error") or r.get("reply", {}).get("rcode", "") != "NXDOMAIN":
			break
	var reply: Dictionary = r.get("reply", r)
	if not reply.has("server"):
		p.outln(";; connection timed out; no servers could be reached")
		return 1
	if reply.rcode != "NOERROR":
		p.outln("Host %s not found: %d(%s)" % [qname, AgoraDns.RCODES.get(reply.rcode, 2), reply.rcode])
		return 1
	for rr: Dictionary in reply.answer:
		match rr.type:
			"A": p.outln("%s has address %s" % [rr.name, rr.data])
			"CNAME": p.outln("%s is an alias for %s." % [rr.name, rr.data])
			"PTR": p.outln("%s domain name pointer %s." % [rr.name, rr.data])
	if (reply.answer as Array).is_empty():
		p.outln("%s has no %s record" % [qname, type])
	return 0
