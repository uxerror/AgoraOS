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
	var index := 1
	if only.is_empty() or only == "lo":
		p.outln("1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN")
		p.outln("    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00")
	for name in p.list_dir("/sys/class/net"):
		index += 1
		if not only.is_empty() and name != only:
			continue
		var base := "/sys/class/net/" + name
		var up := p.read_text(base + "/carrier").strip_edges() == "1"
		var flags := "BROADCAST,MULTICAST,UP,LOWER_UP" if up else "NO-CARRIER,BROADCAST,MULTICAST,UP"
		p.outln("%d: %s: <%s> mtu 1500 state %s" % [index, name, flags, "UP" if up else "DOWN"])
		p.outln("    link/ether %s brd ff:ff:ff:ff:ff:ff" % p.read_text(base + "/address").strip_edges())
	return 0
