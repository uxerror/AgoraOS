extends AgoraProgram
## dig (BIND 9.16): sends one DNS query and prints the whole reply.
## dig [@server] name [type] [+short], dig -x address. No search list.

const VERSION := "9.16.37-Debian"


func summary() -> String:
	return "DNS lookup utility"


func usage() -> String:
	return "Usage:  dig [@global-server] [domain] [q-type] [q-class] {q-opt}\n            {global-d-opt} host [@local-server] {local-d-opt}\n            [ host [@local-server] {local-d-opt} [...]]"


## Tabs that bring [param text] to [param column] with 8-column stops.
static func _pad(text: String, column: int) -> String:
	var tabs := maxi(1, ceili(float(column - text.length()) / 8.0))
	return text + "\t".repeat(tabs)


func main(p: AgoraProcess) -> int:
	var server := ""
	var name := ""
	var type := "A"
	var short := false
	var args := p.argv.slice(1)
	var i := 0
	while i < args.size():
		var a := args[i]
		if a.begins_with("@"):
			server = a.substr(1)
		elif a == "-x" and i + 1 < args.size():
			var addr := AgoraInet.parse(args[i + 1])
			if addr < 0:
				p.errln("Invalid IP address %s" % args[i + 1])
				return 1
			name = AgoraDns.ptr_name(addr)
			type = "PTR"
			i += 1
		elif a == "+short":
			short = true
		elif a.begins_with("+") or a == "IN":
			pass
		elif AgoraDns.TYPES.has(a.to_upper()) and not name.is_empty():
			type = a.to_upper()
		elif a in ["-h", "--help"]:
			p.outln(usage())
			return 0
		else:
			name = a
		i += 1
	if name.is_empty():
		name = "."
		type = "NS"
	var c := AgoraResolver.config(p)
	c.attempts = 3 # dig: +tries=3 +time=5
	if not server.is_empty():
		var addr: int = await AgoraResolver.lookup(p, server)
		if addr < 0:
			p.errln("dig: couldn't get address for '%s': not found" % server)
			return 10
		c.nameservers = [addr]
	var command := " ".join(p.argv.slice(1))
	if not short:
		p.outln("")
		p.outln("; <<>> DiG %s <<>> %s" % [VERSION, command])
		p.outln(";; global options: +cmd")
	var started := Time.get_ticks_msec()
	var r: Dictionary = await AgoraResolver.query(p, name, type, c)
	var reply: Dictionary = r.get("reply", r)
	if not reply.has("server"):
		p.outln(";; connection timed out; no servers could be reached")
		return 9
	var elapsed := Time.get_ticks_msec() - started
	var answers: Array = reply.answer
	if short:
		for rr: Dictionary in answers:
			p.outln(rr.data if rr.type == "A" else rr.data + ".")
		return 0
	var flags: PackedStringArray = ["qr"]
	for f in ["aa", "tc", "rd", "ra"]:
		if reply.get(f, false):
			flags.append(f)
	p.outln(";; Got answer:")
	p.outln(";; ->>HEADER<<- opcode: QUERY, status: %s, id: %d" % [reply.rcode, reply.id])
	p.outln(";; flags: %s; QUERY: 1, ANSWER: %d, AUTHORITY: %d, ADDITIONAL: %d" % [" ".join(flags), answers.size(), (reply.authority as Array).size(), (reply.additional as Array).size()])
	p.outln("")
	p.outln(";; QUESTION SECTION:")
	p.outln(_pad(";%s." % AgoraDns.normalize(name), 32) + "IN\t%s" % type)
	p.outln("")
	if not answers.is_empty():
		p.outln(";; ANSWER SECTION:")
		for rr: Dictionary in answers:
			var data: String = rr.data if rr.type == "A" else rr.data + "."
			p.outln(_pad("%s." % rr.name, 24) + "%d\tIN\t%s\t%s" % [rr.ttl, rr.type, data])
		p.outln("")
	var ns := AgoraInet.to_str(reply.server)
	p.outln(";; Query time: %d msec" % elapsed)
	p.outln(";; SERVER: %s#53(%s)" % [ns, ns])
	p.outln(";; WHEN: %s" % _when(p.machine.clock))
	p.outln(";; MSG SIZE  rcvd: %d" % AgoraDns.size(reply))
	p.outln("")
	return 0


static func _when(clock: AgoraClock) -> String:
	var long := clock.format_long() # "Sat Oct 17 15:04:05 2026"
	var minutes := clock.tz_offset_minutes
	var zone := "UTC" if minutes == 0 else "%s%02d" % ["+" if minutes > 0 else "-", absi(minutes) / 60]
	return "%s %s %s" % [long.left(long.length() - 5), zone, long.right(4)]
