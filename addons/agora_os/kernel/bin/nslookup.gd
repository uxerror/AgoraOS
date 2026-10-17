extends AgoraProgram
## nslookup (BIND 9.16): asks the DNS server from /etc/resolv.conf, or the
## one given, about a name or an address. It talks DNS only: /etc/hosts
## is not consulted. As a busybox applet it prints busybox's format and
## uses the system resolver, /etc/hosts included.


func summary() -> String:
	return "query Internet name servers"


func usage() -> String:
	return "Usage: nslookup [-type=A|PTR] host [server]"


func main(p: AgoraProcess) -> int:
	var args: PackedStringArray = []
	var type := ""
	for a in p.argv.slice(1):
		if a.begins_with("-type=") or a.begins_with("-query=") or a.begins_with("-q="):
			type = a.get_slice("=", 1).to_upper()
		elif not a.begins_with("-"):
			args.append(a)
	if args.is_empty():
		p.errln(usage())
		return 1
	if multicall == "busybox":
		return await _busybox(p, args[0])
	var c := AgoraResolver.config(p)
	if args.size() > 1:
		var server: int = await AgoraResolver.lookup(p, args[1])
		if server < 0:
			p.errln(";; couldn't get address for '%s': not found" % args[1])
			return 1
		c.nameservers = [server]
	var name := args[0]
	var addr := AgoraInet.parse(name)
	if type.is_empty():
		type = "PTR" if addr >= 0 else "A"
	var qname := AgoraDns.ptr_name(addr) if type == "PTR" and addr >= 0 else name
	var r := {}
	var candidates: PackedStringArray = [qname]
	if type == "A" and not name.ends_with(".") and name.count(".") < c.ndots:
		candidates.clear()
		for d: String in c.search:
			candidates.append("%s.%s" % [name, d])
		candidates.append(name)
	for candidate in candidates:
		r = await AgoraResolver.query(p, candidate, type, c)
		if not r.has("error") or r.get("reply", {}).get("rcode", "") != "NXDOMAIN":
			break
	var reply: Dictionary = r.get("reply", r)
	if not reply.has("server"):
		p.outln(";; connection timed out; no servers could be reached")
		p.outln("")
		return 1
	var server_text := AgoraInet.to_str(reply.server)
	p.outln("Server:\t\t%s" % server_text)
	p.outln("Address:\t%s#53" % server_text)
	p.outln("")
	if reply.rcode != "NOERROR":
		p.outln("** server can't find %s: %s" % [name if type != "PTR" else qname, reply.rcode])
		p.outln("")
		return 1
	if (reply.answer as Array).is_empty():
		p.outln("*** Can't find %s: No answer" % name)
		p.outln("")
		return 0
	if not reply.aa:
		p.outln("Non-authoritative answer:")
	for rr: Dictionary in reply.answer:
		match rr.type:
			"A":
				p.outln("Name:\t%s" % rr.name)
				p.outln("Address: %s" % rr.data)
			"CNAME":
				p.outln("%s\tcanonical name = %s." % [rr.name, rr.data])
			"PTR":
				p.outln("%s\tname = %s." % [rr.name, rr.data])
	p.outln("")
	if type == "PTR":
		p.outln("Authoritative answers can be found from:")
		p.outln("")
	return 0


## busybox 1.1.3: resolves through the C library and names the addresses.
func _busybox(p: AgoraProcess, name: String) -> int:
	var c := AgoraResolver.config(p)
	var server: int = c.nameservers[0]
	var server_name: String = await AgoraResolver.reverse(p, server)
	p.outln("Server:    %s" % AgoraInet.to_str(server))
	p.outln("Address 1: %s%s" % [AgoraInet.to_str(server), " " + server_name if not server_name.is_empty() else ""])
	p.outln("")
	var addr := AgoraInet.parse(name)
	if addr < 0:
		var r: Dictionary = await AgoraResolver.resolve(p, name)
		if r.has("error"):
			p.errln("nslookup: can't resolve '%s'" % name)
			return 1
		addr = r.addr
	var back: String = await AgoraResolver.reverse(p, addr)
	p.outln("Name:      %s" % name)
	p.outln("Address 1: %s%s" % [AgoraInet.to_str(addr), " " + back if not back.is_empty() else ""])
	return 0
