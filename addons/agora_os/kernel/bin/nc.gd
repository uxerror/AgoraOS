extends AgoraProgram
## netcat (traditional): opens a TCP connection, or listens for one (-l),
## and copies stdin to it and what arrives to stdout. When stdin ends it
## closes its side of the connection and waits for the other end to close
## too. -z scans ports without sending anything, -v tells what happened.

const SERVICES := {
	21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "domain", 80: "www", 110: "pop3",
	143: "imap2", 443: "https", 3306: "mysql", 6667: "ircd",
}
const TICK := 0.016


func summary() -> String:
	return "TCP/IP swiss army knife"


func usage() -> String:
	return """[v1.10-41]
connect to somewhere:	nc [-options] hostname port[s] [ports] ...
listen for inbound:	nc -l -p port [-options] [hostname] [port]
options:
	-l			listen mode, for inbound connects
	-n			numeric-only IP addresses, no DNS
	-p port			local port number
	-v			verbose [use twice to be more verbose]
	-w secs			timeout for connects and final net reads
	-z			zero-I/O mode [used for scanning]
port numbers can be individual or ranges: lo-hi [inclusive]"""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "pw")
	if not a.error.is_empty() or a.has("h"):
		p.errln(usage())
		return 1
	var verbose := a.has("v")
	var numeric := a.has("n")
	var net := p.machine.net
	if a.has("l"):
		var port := int(a.value("p", a.operands[1] if a.operands.size() > 1 else "0"))
		var l := net.tcp.listen(p, port)
		if l == null:
			p.errln("Can't grab 0.0.0.0:%d with bind : %s" % [port, AgoraErrno.describe(net.tcp.last_error)])
			return 1
		if verbose:
			p.errln("listening on [any] %d ..." % port)
		var conn: AgoraTcp.Conn = await l.accept(p.is_dead)
		l.close()
		if conn == null:
			return 1
		conn.pid = p.pid
		if verbose:
			var who: String = await _name(p, conn.remote_addr, numeric)
			p.errln("connect to [%s] from %s [%s] %d" % [AgoraInet.to_str(conn.local_addr), who, AgoraInet.to_str(conn.remote_addr), conn.remote_port])
		return await _relay(p, conn)
	if a.operands.size() < 2:
		p.errln("no destination" if a.operands.is_empty() else "no port[s] to connect to")
		return 1
	var host := a.operands[0]
	var found: Dictionary = await AgoraResolver.resolve(p, host)
	var addr: int = found.get("addr", -1)
	if addr < 0:
		p.errln("%s: forward host lookup failed: %s" % [host, "Unknown host" if found.error == "NOTFOUND" else "Host name lookup failure"])
		return 1
	var shown := ("%s [%s]" % [host if AgoraInet.parse(host) < 0 else await _name(p, addr, numeric), AgoraInet.to_str(addr)])
	var ports: Array[int] = []
	for spec in a.operands.slice(1):
		var lo := int(spec.get_slice("-", 0))
		var hi := int(spec.get_slice("-", 1)) if spec.contains("-") else lo
		for port in range(hi, lo - 1, -1) if a.has("z") else range(lo, hi + 1):
			ports.append(port)
	var status := 1
	for port in ports:
		var r: Dictionary = await net.tcp.open_connection(p, addr, port)
		var service := " (%s)" % SERVICES[port] if SERVICES.has(port) else ""
		if r.has("error"):
			if verbose:
				p.errln("%s %d%s : %s" % [shown, port, service, AgoraErrno.describe(r.error)])
			continue
		status = 0
		var conn: AgoraTcp.Conn = r.conn
		conn.pid = p.pid
		if verbose:
			p.errln("%s %d%s open" % [shown, port, service])
		if a.has("z"):
			conn.close()
			continue
		return await _relay(p, conn)
	return status


func _name(p: AgoraProcess, addr: int, numeric: bool) -> String:
	if numeric:
		return "(UNKNOWN)"
	var name: String = await AgoraResolver.reverse(p, addr)
	return name if not name.is_empty() else "(UNKNOWN)"


## Copies stdin to the connection and the connection to stdout.
func _relay(p: AgoraProcess, conn: AgoraTcp.Conn) -> int:
	var finished := [false]
	_send_stdin(p, conn, finished)
	var tree := Engine.get_main_loop() as SceneTree
	while not p.is_dead():
		var text := conn.input.read_available()
		if not text.is_empty() and not p.out(text):
			break
		if conn.input.is_eof() and conn.input.available() == 0:
			break
		await tree.create_timer(TICK).timeout
	finished[0] = true
	conn.close()
	return 0


func _send_stdin(p: AgoraProcess, conn: AgoraTcp.Conn, finished: Array) -> void:
	var stop := func() -> bool: return finished[0] or p.is_dead()
	while not finished[0] and not p.is_dead():
		var line: Variant = await p.stdin.read_line(stop)
		if finished[0] or p.is_dead():
			return
		if line == null:
			conn.shutdown_write()
			return
		conn.output.write(str(line) + "\n")
