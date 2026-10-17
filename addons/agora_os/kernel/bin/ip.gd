extends AgoraProgram
## Network configuration. For now only links (ports) exist; addresses and
## routes arrive with the network layer.


func summary() -> String:
	return "show network interfaces"


func usage() -> String:
	return "usage: ip link [show [DEV]]"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	if args.is_empty() or not args[0] in ["link", "l", "addr", "a", "address"]:
		return p.fail(usage(), 1)
	var only := args[2] if args.size() > 2 else ""
	var net := p.machine.net
	for i in net.interfaces:
		if not only.is_empty() and i.name != only:
			continue
		var f := i.link_flags()
		var names: PackedStringArray = []
		if f & AgoraNetStack.IFF_UP and not f & AgoraNetStack.IFF_RUNNING:
			names.append("NO-CARRIER")
		for pair in [[AgoraNetStack.IFF_LOOPBACK, "LOOPBACK"], [AgoraNetStack.IFF_BROADCAST, "BROADCAST"],
				[AgoraNetStack.IFF_MULTICAST, "MULTICAST"], [AgoraNetStack.IFF_UP, "UP"], [AgoraNetStack.IFF_LOWER_UP, "LOWER_UP"]]:
			if f & pair[0]:
				names.append(pair[1])
		var qdisc := "noop" if not i.admin_up else "noqueue" if i.is_loopback() else "pfifo_fast"
		p.outln("%d: %s: <%s> mtu %d qdisc %s state %s mode DEFAULT group default qlen %d" % [
			i.index, i.name, ",".join(names), i.mtu, qdisc, i.operstate().to_upper(), i.tx_queue_len])
		p.outln("    link/%s %s brd %s" % ["loopback" if i.is_loopback() else "ether", i.mac,
			"00:00:00:00:00:00" if i.is_loopback() else "ff:ff:ff:ff:ff:ff"])
	return 0
