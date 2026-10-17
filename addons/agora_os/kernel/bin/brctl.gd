extends AgoraProgram
## bridge-utils brctl: creates Ethernet bridges and adds ports to them.


func summary() -> String:
	return "ethernet bridge administration"


func usage() -> String:
	return """Usage: brctl [commands]
commands:
	addbr     	<bridge>		add bridge
	delbr     	<bridge>		delete bridge
	addif     	<bridge> <device>	add interface to bridge
	delif     	<bridge> <device>	delete interface from bridge
	setageing 	<bridge> <time>		set ageing time
	stp       	<bridge> {on|off}	turn stp on/off
	show      	[ <bridge> ]		show a list of bridges
	showmacs  	<bridge>		show a list of mac addrs"""


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	if args.is_empty() or args[0] in ["-h", "--help", "help"]:
		p.outln(usage())
		return 0 if not args.is_empty() else 1
	var net := p.machine.net
	var cmd := args[0]
	var need := {"addbr": 1, "delbr": 1, "addif": 2, "delif": 2, "setageing": 2, "stp": 2, "showmacs": 1, "show": 0}
	if not need.has(cmd):
		p.errln("never heard of command [%s]" % cmd)
		p.outln(usage())
		return 1
	if args.size() - 1 < need[cmd]:
		p.errln("Incorrect number of arguments for command")
		p.outln(usage())
		return 1
	var br_name := args[1] if args.size() > 1 else ""
	var br := net.iface(br_name)
	if cmd == "show":
		return _show(p, net, br_name)
	if cmd == "showmacs":
		if br == null or not br.is_bridge():
			p.errln("read of forward table failed: No such device")
			return 1
		return _showmacs(p, net, br)
	if not p.cred.is_root():
		var verb := {"addbr": "add bridge", "delbr": "delete bridge", "addif": "can't add %s to bridge %s" % [args[-1], br_name],
			"delif": "can't delete %s from %s" % [args[-1], br_name], "setageing": "set ageing time", "stp": "set stp status"}
		p.errln("%s failed: Operation not permitted" % verb[cmd] if cmd in ["addbr", "delbr", "setageing", "stp"] else "%s: Operation not permitted" % verb[cmd])
		return 1
	match cmd:
		"addbr":
			if net.add_bridge(br_name) == AgoraErrno.EEXIST:
				p.errln("device %s already exists; can't create bridge with the same name" % br_name)
				return 1
		"delbr":
			if br == null or not br.is_bridge():
				p.errln("bridge %s doesn't exist; can't delete it" % br_name)
				return 1
			if br.admin_up:
				p.errln("bridge %s is still up; can't delete it" % br_name)
				return 1
			net.del_link(br_name)
		"addif", "delif":
			if br == null or not br.is_bridge():
				p.errln("bridge %s does not exist!" % br_name)
				return 1
			var dev := args[2]
			var port := net.iface(dev)
			if port == null:
				p.errln("interface %s does not exist!" % dev)
				return 1
			if cmd == "delif":
				if port.master != br_name:
					p.errln("device %s is not a slave of %s" % [dev, br_name])
					return 1
				net.set_master(dev, "")
				return 0
			# The ioctl refuses ports of any bridge, this one included.
			var code := AgoraErrno.EBUSY if not port.master.is_empty() else net.set_master(dev, br_name)
			if code == AgoraErrno.EBUSY:
				p.errln("device %s is already a member of a bridge; can't enslave it to bridge %s." % [dev, br_name])
				return 1
			if code == AgoraErrno.ELOOP:
				p.errln("device %s is a bridge device itself; can't enslave a bridge device to a bridge device." % dev)
				return 1
			if code != AgoraErrno.OK:
				p.errln("can't add %s to bridge %s: %s" % [dev, br_name, AgoraErrno.describe(code)])
				return 1
		"setageing", "stp":
			if br == null or not br.is_bridge():
				p.errln("bridge %s does not exist!" % br_name)
				return 1
			if cmd == "stp":
				br.stp = args[2] in ["on", "yes", "1"]
			elif args[2].is_valid_float():
				br.ageing_time = float(args[2])
	return 0


func _show(p: AgoraProcess, net: AgoraNetStack, only: String) -> int:
	if not only.is_empty():
		var b := net.iface(only)
		if b == null or not b.is_bridge():
			p.errln("bridge %s does not exist!" % only)
			return 1
	p.outln("bridge name\tbridge id\t\tSTP enabled\tinterfaces")
	for b in net.interfaces:
		if not b.is_bridge() or (not only.is_empty() and b.name != only):
			continue
		var ports := b.ports.duplicate()
		ports.sort()
		var line := "%s\t\t8000.%s\t%s\t\t%s" % [b.name, b.mac.replace(":", ""), "yes" if b.stp else "no", ports[0] if not ports.is_empty() else ""]
		p.outln(line)
		for k in range(1, ports.size()):
			p.outln("\t\t\t\t\t\t\t" + ports[k])
	return 0


func _showmacs(p: AgoraProcess, net: AgoraNetStack, br: AgoraNetStack.Iface) -> int:
	var rows: Array = []
	for port in br.ports:
		var i := net.iface(port)
		if i:
			rows.append([i.port_no, i.mac, true, 0.0])
	for e in net.bridge.entries(br):
		var i := net.iface(e.port)
		rows.append([i.port_no if i else 0, e.mac, false, e.age])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[1] < b[1])
	p.outln("port no\tmac addr\t\tis local?\tageing timer")
	for r: Array in rows:
		var age: float = r[3]
		p.outln("%3d\t%s\t%s\t\t%4d.%02d" % [r[0], r[1], "yes" if r[2] else "no", int(age), int(age * 100.0) % 100])
	return 0
