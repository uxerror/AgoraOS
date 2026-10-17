extends AgoraProgram
## udhcpd, busybox's small DHCP server (as in busybox 1.1.3).
##
## Reads /etc/udhcpd.conf (or the file given), hands out addresses from
## start..end on one interface, checks with an ARP probe that nobody uses
## an address before offering it, and keeps its leases in a binary file
## (see dumpleases) that it writes every auto_time seconds and on SIGUSR1.
## Lease times run on the machine's clock.

const VERSION := "1.1.3"
const CONFIG := "/etc/udhcpd.conf"

var p: AgoraProcess
var cfg := {}
## {chaddr, yiaddr, expires, kind ("offer", "lease" or "conflict")}
var leases: Array[Dictionary] = []
var _server := 0
var _iface: AgoraNetStack.Iface
var _sock: AgoraUdp.Socket
var _stop := false
var _write_now := false


func summary() -> String:
	return "small DHCP server"


func usage() -> String:
	return "Usage: udhcpd [-f] [configfile]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv)
	var foreground := a.has("f")
	var file := a.operands[0] if not a.operands.is_empty() else CONFIG
	cfg = _read_config(p.read_text(file))
	var net := p.machine.net
	_iface = net.iface(cfg.interface)
	if _iface == null:
		return _die("SIOCGIFINDEX failed!: No such device")
	var primary := _iface.primary_addrs()
	if primary.is_empty():
		return _die("SIOCGIFADDR failed, is the interface up and configured?: Cannot assign requested address")
	_server = primary[0].address
	_sock = net.udp.open(p, AgoraDhcp.SERVER_PORT, {"device": cfg.interface, "broadcast": true})
	if _sock == null:
		return _die("bind: " + AgoraErrno.describe(net.udp.last_error))
	_log("udhcp server (v%s) started" % VERSION)
	_read_leases()
	p.write_text(cfg.pidfile, "%d\n" % p.pid)
	p.signal_handler = _on_signal
	if not foreground:
		p.daemonize()
	var next_write: float = p.machine.clock.now() + cfg.auto_time
	while not _stop and p.is_running():
		while not _sock.inbox.is_empty() and not _stop:
			var dgram: Dictionary = _sock.inbox.pop_front()
			if AgoraDhcp.is_valid(dgram.data, AgoraDhcp.BOOTREQUEST):
				await _handle(dgram.data)
		var now := p.machine.clock.now()
		if _write_now or (cfg.auto_time > 0 and now >= next_write):
			_write_now = false
			_write_leases()
			next_write = now + cfg.auto_time
		await p.sleep(0.05)
	_sock.close()
	return 0


func _die(message: String) -> int:
	p.errln("udhcpd: " + message)
	_log(message)
	return 1


func _log(message: String) -> void:
	p.machine.log_event("daemon", "udhcpd[%d]" % p.pid, message)


func _on_signal(sig: int) -> bool:
	match sig:
		AgoraProcess.SIGUSR1:
			_write_now = true
			return true
		AgoraProcess.SIGTERM:
			_log("Received a SIGTERM")
			_stop = true
			return true
	return false


# --- configuration --------------------------------------------------------------

static func _read_config(text: String) -> Dictionary:
	var c := {
		"start": AgoraInet.parse("192.168.0.20"), "end": AgoraInet.parse("192.168.0.254"),
		"interface": "eth0", "max_leases": 254, "remaining": true, "auto_time": 7200,
		"decline_time": 3600, "conflict_time": 3600, "offer_time": 60, "min_lease": 60,
		"lease_file": "/var/lib/misc/udhcpd.leases", "pidfile": "/var/run/udhcpd.pid",
		"siaddr": 0, "options": {"lease": 864000}, "static": {},
	}
	for raw in text.split("\n"):
		var line := raw.get_slice("#", 0).strip_edges().replace("\t", " ")
		var words := line.split(" ", false)
		if words.size() < 2:
			continue
		var key := words[0]
		var value := words[1]
		match key:
			"start", "end", "siaddr":
				var addr := AgoraInet.parse(value)
				if addr >= 0:
					c[key] = addr
			"interface", "lease_file", "pidfile", "notify_file", "sname", "boot_file":
				c[key] = value
			"max_leases", "auto_time", "decline_time", "conflict_time", "offer_time", "min_lease":
				if value.is_valid_int():
					c[key] = int(value)
			"remaining":
				c.remaining = value in ["yes", "1", "true", "on"]
			"option", "opt":
				if words.size() >= 3:
					_set_option(c.options, value, words.slice(2))
			"static_lease":
				if words.size() >= 3 and AgoraInet.parse(words[2]) >= 0:
					c.static[value.to_lower()] = AgoraInet.parse(words[2])
	return c


static func _set_option(options: Dictionary, name: String, values: PackedStringArray) -> void:
	match name:
		"router", "dns", "wins", "ntpsrv":
			var list: Array = options.get(name, [])
			for v in values:
				if AgoraInet.parse(v) >= 0:
					list.append(AgoraInet.parse(v))
			options[name] = list
		"subnet", "broadcast":
			if AgoraInet.parse(values[0]) >= 0:
				options[name] = AgoraInet.parse(values[0])
		"lease", "mtu":
			if values[0].is_valid_int():
				options[name] = int(values[0])
		_:
			options[name] = " ".join(values)


# --- leases -----------------------------------------------------------------------

func _now() -> float:
	return p.machine.clock.now()


func _by_chaddr(mac: String) -> Dictionary:
	for l in leases:
		if l.chaddr == mac:
			return l
	return {}


func _by_yiaddr(addr: int) -> Dictionary:
	for l in leases:
		if l.yiaddr == addr:
			return l
	return {}


func _expired(l: Dictionary) -> bool:
	return l.expires <= _now()


## Records a lease, replacing any other one for the same client or address.
func _add_lease(mac: String, addr: int, seconds: float, kind: String) -> void:
	leases = leases.filter(func(l: Dictionary) -> bool: return l.chaddr != mac and l.yiaddr != addr) if not mac.is_empty() else leases.filter(func(l: Dictionary) -> bool: return l.yiaddr != addr)
	if leases.size() >= cfg.max_leases:
		# Make room by dropping the oldest expired lease.
		for l in leases:
			if _expired(l):
				leases.erase(l)
				break
	leases.append({"chaddr": mac, "yiaddr": addr, "expires": _now() + seconds, "kind": kind})


func _is_static_elsewhere(addr: int, mac: String) -> bool:
	for m: String in cfg.static:
		if cfg.static[m] == addr and m != mac:
			return true
	return false


func _in_range(addr: int) -> bool:
	return addr >= cfg.start and addr <= cfg.end


## The first free address of the pool. Every candidate is checked with an
## ARP probe; an address someone answers for is reserved as a conflict.
func _find_address() -> int:
	for addr in range(cfg.start, cfg.end + 1):
		if addr & 0xFF == 0 or addr & 0xFF == 0xFF or addr == _server:
			continue
		if _is_static_elsewhere(addr, ""):
			continue
		var l := _by_yiaddr(addr)
		if not l.is_empty() and not _expired(l):
			continue
		if not await _free_on_wire(addr):
			continue
		return addr
	return -1


## False (and the address reserved) if someone answers an ARP probe for it.
func _free_on_wire(addr: int) -> bool:
	var who: String = await p.machine.net.neigh.probe(_iface, addr, _server)
	if who.is_empty():
		return true
	_log("%s belongs to someone, reserving it for %d seconds" % [AgoraInet.to_str(addr), cfg.conflict_time])
	_add_lease("", addr, cfg.conflict_time, "conflict")
	return false


func _lease_time(msg: Dictionary) -> int:
	var wanted: int = msg.options.get("lease", 0)
	var lease: int = cfg.options.lease
	if wanted > 0 and wanted < lease:
		lease = maxi(wanted, cfg.min_lease)
	return lease


## Lease file: one 24-byte record per lease, as busybox writes it: the
## client's hardware address (16 bytes), the address and the remaining
## (or absolute) lease time, both big-endian.
func _write_leases() -> void:
	var data := PackedByteArray()
	var now := _now()
	for l in leases:
		if l.kind == "conflict" or l.chaddr.is_empty():
			continue
		var rec := PackedByteArray()
		rec.resize(24)
		var octets: PackedStringArray = l.chaddr.split(":")
		for k in octets.size():
			rec[k] = octets[k].hex_to_int()
		var expires := maxi(0, int(l.expires - now)) if cfg.remaining else int(l.expires)
		for k in 4:
			rec[16 + k] = (l.yiaddr >> (24 - 8 * k)) & 255
			rec[20 + k] = (expires >> (24 - 8 * k)) & 255
		data.append_array(rec)
	p.make_dirs(AgoraPath.dirname(cfg.lease_file))
	p.write_bytes(cfg.lease_file, data)


func _read_leases() -> void:
	var data := p.read_bytes(cfg.lease_file)
	var now := _now()
	for k in range(0, data.size() - 23, 24):
		var mac := "%02x:%02x:%02x:%02x:%02x:%02x" % [data[k], data[k + 1], data[k + 2], data[k + 3], data[k + 4], data[k + 5]]
		var addr := (data[k + 16] << 24) | (data[k + 17] << 16) | (data[k + 18] << 8) | data[k + 19]
		var expires := (data[k + 20] << 24) | (data[k + 21] << 16) | (data[k + 22] << 8) | data[k + 23]
		if _in_range(addr):
			leases.append({"chaddr": mac, "yiaddr": addr, "expires": now + expires if cfg.remaining else float(expires), "kind": "lease"})


# --- protocol -----------------------------------------------------------------------

func _handle(msg: Dictionary) -> void:
	var mac: String = msg.chaddr
	match msg.type:
		"DISCOVER":
			await _discover(msg, mac)
		"REQUEST":
			_request(msg, mac)
		"DECLINE":
			var l := _by_chaddr(mac)
			if not l.is_empty():
				l.chaddr = ""
				l.kind = "conflict"
				l.expires = _now() + cfg.decline_time
		"RELEASE":
			var l := _by_chaddr(mac)
			if not l.is_empty():
				l.expires = _now()
		"INFORM":
			var reply := _reply(msg, "ACK")
			_send(reply, msg)


func _discover(msg: Dictionary, mac: String) -> void:
	var addr := -1
	var lease := _by_chaddr(mac)
	if cfg.static.has(mac):
		addr = cfg.static[mac]
	elif not lease.is_empty() and lease.kind != "conflict":
		addr = lease.yiaddr
	else:
		var wanted: int = msg.options.get("requested", 0)
		if wanted != 0 and _in_range(wanted) and not _is_static_elsewhere(wanted, mac):
			var holder := _by_yiaddr(wanted)
			if (holder.is_empty() or _expired(holder)) and await _free_on_wire(wanted):
				addr = wanted
		if addr < 0:
			addr = await _find_address()
		if addr < 0:
			_log("no IP addresses to give -- OFFER abandoned")
			return
	if lease.is_empty() or lease.kind == "offer" or lease.yiaddr != addr or _expired(lease):
		_add_lease(mac, addr, cfg.offer_time, "offer")
	var reply := _reply(msg, "OFFER")
	reply.yiaddr = addr
	reply.options.lease = _lease_time(msg)
	_log("sending OFFER of %s" % AgoraInet.to_str(addr))
	_send(reply, msg)


func _request(msg: Dictionary, mac: String) -> void:
	var requested: int = msg.options.get("requested", 0)
	var server_id: int = msg.options.get("server_id", 0)
	var lease := _by_chaddr(mac)
	if cfg.static.has(mac) and lease.is_empty():
		lease = {"yiaddr": cfg.static[mac]}
	if not lease.is_empty():
		if server_id != 0:
			# SELECTING: the client picked one of our offers.
			if server_id == _server and requested == lease.yiaddr:
				_ack(msg, mac, lease.yiaddr)
		elif requested != 0:
			# INIT-REBOOT: the client remembers an address.
			if requested == lease.yiaddr:
				_ack(msg, mac, requested)
			else:
				_nak(msg)
		elif lease.yiaddr == msg.ciaddr:
			# RENEWING or REBINDING.
			_ack(msg, mac, lease.yiaddr)
		else:
			_nak(msg)
	elif server_id == 0 and requested != 0:
		var holder := _by_yiaddr(requested)
		if not holder.is_empty():
			if _expired(holder):
				leases.erase(holder)
			else:
				_nak(msg)
		elif not _in_range(requested):
			_nak(msg)


func _ack(msg: Dictionary, mac: String, addr: int) -> void:
	var reply := _reply(msg, "ACK")
	reply.yiaddr = addr
	var seconds := _lease_time(msg)
	reply.options.lease = seconds
	_add_lease(mac, addr, seconds, "lease")
	_log("sending ACK to %s" % AgoraInet.to_str(addr))
	_send(reply, msg)


func _nak(msg: Dictionary) -> void:
	_log("sending NAK")
	_send(AgoraDhcp.message(AgoraDhcp.BOOTREPLY, "NAK", msg.xid, msg.chaddr, {"server_id": _server}), msg, true)


func _reply(msg: Dictionary, type: String) -> Dictionary:
	var options := {"server_id": _server}
	for key: String in cfg.options:
		if key != "lease":
			options[key] = cfg.options[key]
	var reply := AgoraDhcp.message(AgoraDhcp.BOOTREPLY, type, msg.xid, msg.chaddr, options)
	reply.siaddr = cfg.siaddr
	reply.flags = msg.flags
	reply.ciaddr = msg.ciaddr
	return reply


## Where busybox sends a reply: broadcast for a NAK or when the client
## asks for it, to ciaddr if it has one, else straight to the offered
## address and the client's MAC (it can't answer ARP yet).
func _send(reply: Dictionary, msg: Dictionary, broadcast: bool = false) -> void:
	var dst: int = AgoraInet.BROADCAST
	var mac := AgoraNetStack.BROADCAST_MAC
	if broadcast:
		pass
	elif msg.ciaddr != 0:
		dst = msg.ciaddr
		mac = msg.chaddr
	elif msg.flags & AgoraDhcp.BROADCAST_FLAG == 0 and reply.yiaddr != 0:
		dst = reply.yiaddr
		mac = msg.chaddr
	_sock.sendto(dst, AgoraDhcp.CLIENT_PORT, reply, AgoraDhcp.SIZE, {"src": _server, "dst_mac": mac})
