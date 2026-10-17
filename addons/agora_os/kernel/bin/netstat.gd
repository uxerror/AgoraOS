extends AgoraProgram
## net-tools netstat: network connections from /proc/net/tcp and udp,
## the routing table (-r) and interface counters (-i).

const STATES := ["", "ESTABLISHED", "SYN_SENT", "SYN_RECV", "FIN_WAIT1", "FIN_WAIT2", "TIME_WAIT",
	"CLOSE", "CLOSE_WAIT", "LAST_ACK", "LISTEN", "CLOSING"]
const SERVICES := {
	21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "domain", 67: "bootps", 68: "bootpc",
	80: "www", 110: "pop3", 143: "imap2", 443: "https", 3306: "mysql", 6667: "ircd",
}


func summary() -> String:
	return "print network connections, routing tables and interface statistics"


func usage() -> String:
	return """usage: netstat [-veenNcCF] [<Af>] -r         netstat {-V|--version|-h|--help}
       netstat [-vnNcaeol] [<Socket> ...]
       netstat { [-veenNac] -i | [-cnNe] -M | -s }

        -r, --route              display routing table
        -i, --interfaces         display interface table
        -n, --numeric            don't resolve names
        -p, --programs           display PID/Program name for sockets
        -l, --listening          display listening server sockets
        -a, --all, --listening   display all sockets (default: connected)
        -t, --tcp                tcp sockets
		-u, --udp                udp sockets"""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.has("h") or a.has("help"):
		p.outln(usage())
		return 0
	var numeric := a.has("n") or a.has("numeric")
	if a.has("r") or a.has("route"):
		return _routes(p, numeric)
	if a.has("i") or a.has("interfaces"):
		return _interfaces(p)
	var tcp := a.has("t") or a.has("tcp")
	var udp := a.has("u") or a.has("udp")
	if not tcp and not udp:
		tcp = true
		udp = true
	var listening := a.has("l") or a.has("listening")
	var all := a.has("a") or a.has("all")
	var programs := a.has("p") or a.has("programs")
	if programs and not p.cred.is_root():
		p.errln("(Not all processes could be identified, non-owned process info\n will not be shown, you would have to be root to see it all.)")
	p.outln("Active Internet connections (%s)" % ("servers and established" if all else "only servers" if listening else "w/o servers"))
	p.outln("Proto Recv-Q Send-Q Local Address           Foreign Address         State      " + (" PID/Program name" if programs else ""))
	for proto in ["tcp", "udp"]:
		if (proto == "tcp" and not tcp) or (proto == "udp" and not udp):
			continue
		var lines := p.read_text("/proc/net/" + proto).split("\n", false)
		for k in range(1, lines.size()):
			var f := lines[k].strip_edges().split(" ", false)
			if f.size() < 8:
				continue
			var local := _endpoint(f[1], numeric, proto, true)
			var remote := _endpoint(f[2], numeric, proto, false)
			var st := f[3].hex_to_int()
			var state: String = STATES[st] if proto == "tcp" and st < STATES.size() else ""
			var is_server: bool = state == "LISTEN" or (proto == "udp" and f[2].ends_with(":0000"))
			if (is_server and not (listening or all)) or (not is_server and listening and not all):
				continue
			var queues := f[4].split(":")
			var line := "%-5s %6d %6d %-23s %-23s %-11s" % [proto, queues[1].hex_to_int(), queues[0].hex_to_int(), local, remote, state]
			if programs:
				line += " " + ("-" if state == "TIME_WAIT" else _owner(p, proto, f[1], f[2], int(f[7])))
			p.outln(line)
	return 0


static func _hex_addr(text: String) -> int:
	var v := text.hex_to_int()
	return ((v & 255) << 24) | (((v >> 8) & 255) << 16) | (((v >> 16) & 255) << 8) | ((v >> 24) & 255)


func _endpoint(field: String, numeric: bool, _proto: String, local: bool) -> String:
	var addr := _hex_addr(field.get_slice(":", 0))
	var port := field.get_slice(":", 1).hex_to_int()
	var host := AgoraInet.to_str(addr)
	var port_text := str(port)
	if port == 0 and not local:
		port_text = "*"
	if not numeric:
		if addr == 0:
			host = "*"
		if SERVICES.has(port):
			port_text = SERVICES[port]
	return "%s:%s" % [host, port_text]


## "pid/name" for a socket, or "-" if it isn't ours to see.
func _owner(p: AgoraProcess, proto: String, local: String, remote: String, uid: int) -> String:
	if not p.cred.is_root() and uid != p.cred.uid:
		return "-"
	var net := p.machine.net
	var lport := local.get_slice(":", 1).hex_to_int()
	var rport := remote.get_slice(":", 1).hex_to_int()
	var raddr := _hex_addr(remote.get_slice(":", 0))
	var pid := 0
	if proto == "udp":
		for s in net.udp.sockets:
			if s.port == lport:
				pid = s.pid
	else:
		if rport == 0:
			var l := net.tcp.listener_on(lport)
			pid = l.pid if l else 0
		else:
			for c: AgoraTcp.Conn in net.tcp.conns.values():
				if c.local_port == lport and c.remote_port == rport and c.remote_addr == raddr:
					pid = c.pid
	var owner := p.machine.get_process(pid)
	return "%d/%s" % [pid, owner.name] if owner else "-"


func _routes(p: AgoraProcess, numeric: bool) -> int:
	p.outln("Kernel IP routing table")
	p.outln("Destination     Gateway         Genmask         Flags   MSS Window  irtt Iface")
	var lines := p.read_text("/proc/net/route").split("\n", false)
	for k in range(1, lines.size()):
		var f := lines[k].strip_edges().split("\t")
		if f.size() < 8:
			continue
		var dst := _hex_addr(f[1])
		var gw := _hex_addr(f[2])
		var flags := f[3].hex_to_int()
		var letters := ("U" if flags & 1 else "") + ("G" if flags & 2 else "") + ("H" if flags & 4 else "") + ("!" if flags & 0x200 else "")
		var dst_text := "default" if not numeric and dst == 0 else AgoraInet.to_str(dst)
		var gw_text := "*" if not numeric and gw == 0 else AgoraInet.to_str(gw)
		p.outln("%-15s %-15s %-15s %-5s %5d %-6d %4d %s" % [dst_text, gw_text, AgoraInet.to_str(_hex_addr(f[7])), letters, 0, 0, 0, f[0]])
	return 0


func _interfaces(p: AgoraProcess) -> int:
	p.outln("Kernel Interface table")
	p.outln("Iface   MTU Met   RX-OK RX-ERR RX-DRP RX-OVR    TX-OK TX-ERR TX-DRP TX-OVR Flg")
	var names: Array = []
	for i in p.machine.net.interfaces:
		names.append(i)
	names.sort_custom(func(x: AgoraNetStack.Iface, y: AgoraNetStack.Iface) -> bool: return x.name < y.name)
	for i: AgoraNetStack.Iface in names:
		if not i.admin_up:
			continue
		var st := i.stats
		var f := i.link_flags()
		var flags := ("B" if f & AgoraNetStack.IFF_BROADCAST else "") + ("L" if f & AgoraNetStack.IFF_LOOPBACK else "") + \
			("M" if f & AgoraNetStack.IFF_MULTICAST else "") + ("R" if f & AgoraNetStack.IFF_RUNNING else "") + "U"
		p.outln("%-5s %5d %3d %7d %6d %6d %6d %8d %6d %6d %6d %s" % [i.name, i.mtu, 0, st.rx_packets, st.rx_errors, st.rx_dropped, 0,
			st.tx_packets, st.tx_errors, st.tx_dropped, 0, flags])
	return 0
