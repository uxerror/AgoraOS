extends AgoraProgram
## iproute2's bridge: shows bridge ports and the forwarding database.


func summary() -> String:
	return "show bridge ports and forwarding database"


func usage() -> String:
	return "Usage: bridge [ OPTIONS ] OBJECT { COMMAND | help }\nwhere  OBJECT := { link | fdb }"


static func _matches(word: String, full: String) -> bool:
	return not word.is_empty() and full.begins_with(word)


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	if args.is_empty():
		p.errln(usage())
		return 255
	var net := p.machine.net
	var rest := args.slice(1)
	if rest.size() > 0 and (_matches(rest[0], "show") or _matches(rest[0], "list")):
		rest = rest.slice(1)
	var dev := ""
	var master := ""
	for k in rest.size() - 1:
		if rest[k] == "dev":
			dev = rest[k + 1]
		elif rest[k] == "br":
			master = rest[k + 1]
	if _matches(args[0], "link"):
		for i in net.interfaces:
			if i.master.is_empty() or (not dev.is_empty() and i.name != dev):
				continue
			p.outln("%d: %s: <%s> mtu %d master %s state %s priority 32 cost %d " % [
				i.index, i.name, _flags(i), i.mtu, i.master, i.port_state, _cost(i)])
		return 0
	if _matches(args[0], "fdb"):
		for b in net.interfaces:
			if not b.is_bridge() or (not master.is_empty() and b.name != master):
				continue
			for e in net.bridge.entries(b):
				if dev.is_empty() or e.port == dev:
					p.outln("%s dev %s master %s " % [e.mac, e.port, b.name])
			for port in b.ports:
				var i := net.iface(port)
				if i and (dev.is_empty() or port == dev):
					p.outln("%s dev %s master %s permanent" % [i.mac, port, b.name])
		return 0
	p.errln('Object "%s" is unknown, try "bridge help".' % args[0])
	return 255


static func _flags(i: AgoraNetStack.Iface) -> String:
	var f := i.link_flags()
	var names: PackedStringArray = []
	if f & AgoraNetStack.IFF_UP and not f & AgoraNetStack.IFF_RUNNING:
		names.append("NO-CARRIER")
	for pair: Array in [[AgoraNetStack.IFF_BROADCAST, "BROADCAST"], [AgoraNetStack.IFF_MULTICAST, "MULTICAST"],
			[AgoraNetStack.IFF_UP, "UP"], [AgoraNetStack.IFF_LOWER_UP, "LOWER_UP"]]:
		if f & pair[0]:
			names.append(pair[1])
	return ",".join(names)


## STP path cost of a port by its speed, as the kernel's bridge sets it.
func _cost(i: AgoraNetStack.Iface) -> int:
	var speed := i.nic.link_speed if i.nic else 0
	return 100 if speed <= 10 else 19 if speed <= 100 else 4
