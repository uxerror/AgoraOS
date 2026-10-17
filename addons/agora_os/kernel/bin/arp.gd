extends AgoraProgram
## net-tools arp: prints the neighbour table from /proc/net/arp, adds
## permanent entries (-s) and deletes entries (-d).

const ATF_COM := 0x2
const ATF_PERM := 0x4


func summary() -> String:
	return "show or change the ARP cache"


func usage() -> String:
	return """Usage:
  arp [-vn]  [<HW>] [-i <if>] [-a] [<hostname>]             <-Display ARP cache
  arp [-v]          [-i <if>] -d  <host> [pub]               <-Delete ARP entry
  arp [-v]   [<HW>] [-i <if>] -s  <host> <hwaddr> [temp]            <-Add entry"""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "iHtds")
	if not a.error.is_empty():
		p.errln(usage())
		return 255
	var dev := a.value("i")
	if a.has("d"):
		return _delete(p, a.value("d"), dev)
	if a.has("s"):
		if a.operands.is_empty():
			p.errln(usage())
			return 255
		return _add_entry(p, a.value("s"), a.operands[0], dev, a.operands.has("temp"))
	return _show(p, a.has("a"), dev, a.operands[0] if not a.operands.is_empty() else "")


func _show(p: AgoraProcess, bsd: bool, dev: String, host: String) -> int:
	var lines := p.read_text("/proc/net/arp").split("\n", false)
	var shown := 0
	var header_done := false
	for k in range(1, lines.size()):
		var f := lines[k].split(" ", false)
		if f.size() < 6:
			continue
		var ip := f[0]
		var flags := f[2].hex_to_int()
		var mac := f[3]
		var iface := f[5]
		if (not dev.is_empty() and iface != dev) or (not host.is_empty() and ip != host):
			continue
		shown += 1
		if bsd:
			if flags & ATF_COM:
				p.outln("? (%s) at %s [ether] %son %s" % [ip, mac, "PERM " if flags & ATF_PERM else "", iface])
			else:
				p.outln("? (%s) at <incomplete> on %s" % [ip, iface])
			continue
		if not header_done:
			p.outln("Address                  HWtype  HWaddress           Flags Mask            Iface")
			header_done = true
		var flag_text := ("C" if flags & ATF_COM else "") + ("M" if flags & ATF_PERM else "")
		if flags & ATF_COM:
			p.outln("%-23s  %-8s%-20s%-6s%-15s %s" % [ip, "ether", mac, flag_text, "", iface])
		else:
			p.outln("%-23s  %-8s%-20s%-6s%-15s %s" % [ip, "", "(incomplete)", flag_text, "", iface])
	if shown == 0 and not host.is_empty():
		p.outln("%s (%s) -- no entry" % [host, host])
		return 1
	if shown == 0 and not dev.is_empty():
		p.outln("arp: in %d entries no match found." % (lines.size() - 1))
	return 0


## The interface ARP would use for [param ip]: the -i one, or the one the
## route points at.
func _iface_for(p: AgoraProcess, ip: int, dev: String) -> String:
	if not dev.is_empty():
		return dev
	var r := p.machine.net.lookup(ip)
	return r.dev if not r.is_empty() and r.type == "unicast" else ""


func _delete(p: AgoraProcess, host: String, dev: String) -> int:
	var ip := AgoraInet.parse(host)
	if ip < 0:
		p.errln("%s: Unknown host" % host)
		return 255
	if not p.cred.is_root():
		p.errln("SIOCDARP(dontpub): Operation not permitted")
		return 255
	var name := _iface_for(p, ip, dev)
	if name.is_empty() or not p.machine.net.neigh.remove(name, ip):
		p.errln("No ARP entry for %s" % host)
		return 255
	return 0


func _add_entry(p: AgoraProcess, host: String, mac: String, dev: String, temp: bool) -> int:
	var ip := AgoraInet.parse(host)
	if ip < 0:
		p.errln("%s: Unknown host" % host)
		return 255
	if not AgoraNetStack.is_valid_mac(mac):
		p.errln("arp: invalid hardware address")
		return 255
	if not p.cred.is_root():
		p.errln("SIOCSARP: Operation not permitted")
		return 255
	var name := _iface_for(p, ip, dev)
	if name.is_empty():
		p.errln("SIOCSARP: Network is unreachable")
		return 255
	p.machine.net.neigh.add(name, ip, mac.to_lower(), "REACHABLE" if temp else "PERMANENT")
	return 0
