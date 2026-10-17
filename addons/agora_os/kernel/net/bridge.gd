class_name AgoraBridge
extends RefCounted
## The Ethernet bridge of one network stack (Linux's "bridge" module): a
## software switch over several ports. It learns which MAC address lives
## behind which port, forwards frames only where they need to go, floods
## broadcasts and unknown destinations, and passes frames for the bridge
## itself up to its IP stack. STP can be switched on but sends no BPDUs.

var _stack: WeakRef


func _init(stack: AgoraNetStack) -> void:
	_stack = weakref(stack)


func _net() -> AgoraNetStack:
	return _stack.get_ref() as AgoraNetStack


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func is_multicast(mac: String) -> bool:
	return mac.substr(0, 2).hex_to_int() & 1 == 1


func add_port(br: AgoraNetStack.Iface, port: AgoraNetStack.Iface) -> void:
	var next := 1
	for p: AgoraNetStack.Iface in br._port_ifaces():
		next = maxi(next, p.port_no + 1)
	port.master = br.name
	port.port_no = next
	port.port_state = "disabled"
	br.ports.append(port.name)
	_net().neigh.flush(port.name)
	_klog("device %s entered promiscuous mode" % port.name)
	update_ports(br)


func remove_port(br: AgoraNetStack.Iface, port: AgoraNetStack.Iface) -> void:
	if br == null:
		port.master = ""
		return
	if port.port_state == "forwarding":
		_klog("%s: port %d(%s) entered disabled state" % [br.name, port.port_no, port.name])
	flush_port(br, port.name)
	br.ports.remove_at(br.ports.find(port.name))
	port.master = ""
	port.port_no = 0
	port.port_state = "disabled"
	_klog("device %s left promiscuous mode" % port.name)


## Recomputes the state of every port of [param br]: a port forwards
## while it and the bridge are up and it has a link.
func update_ports(br: AgoraNetStack.Iface) -> void:
	if br == null:
		return
	for p: AgoraNetStack.Iface in br._port_ifaces():
		var state := "forwarding" if br.admin_up and p.admin_up and p.carrier else "disabled"
		if state != p.port_state:
			p.port_state = state
			if state == "disabled":
				flush_port(br, p.name)
			_klog("%s: port %d(%s) entered %s state" % [br.name, p.port_no, p.name, state])


func flush_port(br: AgoraNetStack.Iface, port: String) -> void:
	for mac in br.fdb.keys():
		if br.fdb[mac].port == port:
			br.fdb.erase(mac)


## True if [param mac] is the bridge's own or one of its ports'.
func is_local(br: AgoraNetStack.Iface, mac: String) -> bool:
	if mac == br.mac:
		return true
	for p: AgoraNetStack.Iface in br._port_ifaces():
		if p.mac == mac:
			return true
	return false


## A learned entry for [param mac], or {} (expired entries are dropped).
func lookup(br: AgoraNetStack.Iface, mac: String) -> Dictionary:
	var e: Dictionary = br.fdb.get(mac, {})
	if not e.is_empty() and _now() - e.updated > br.ageing_time:
		br.fdb.erase(mac)
		return {}
	return e


## Learned entries sorted by address, each {mac, port, age}.
func entries(br: AgoraNetStack.Iface) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for mac: String in br.fdb.keys():
		var e := lookup(br, mac)
		if not e.is_empty():
			out.append({"mac": mac, "port": e.port, "age": _now() - e.updated})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.mac < b.mac)
	return out


## A frame arrived on [param port].
func input(br: AgoraNetStack.Iface, port: AgoraNetStack.Iface, frame: Dictionary) -> void:
	var net := _net()
	if br == null or net == null or not br.admin_up or port.port_state != "forwarding":
		return
	var src: String = frame.src
	if not is_multicast(src) and not is_local(br, src):
		br.fdb[src] = {"port": port.name, "updated": _now()}
	var dst: String = frame.dst
	if is_multicast(dst):
		_flood(br, port, frame)
		_up(br, frame)
		return
	if is_local(br, dst):
		_up(br, frame)
		return
	var e := lookup(br, dst)
	if e.is_empty():
		_flood(br, port, frame)
	elif e.port != port.name:
		_forward(net.iface(e.port), frame)


## The bridge's own IP stack sends [param frame].
func output(br: AgoraNetStack.Iface, frame: Dictionary) -> void:
	var net := _net()
	if net == null:
		return
	var dst: String = frame.dst
	var e := {} if is_multicast(dst) else lookup(br, dst)
	if e.is_empty():
		_flood(br, null, frame)
	else:
		_forward(net.iface(e.port), frame)


func _up(br: AgoraNetStack.Iface, frame: Dictionary) -> void:
	br.stats.rx_packets += 1
	br.stats.rx_bytes += maxi(AgoraNetStack.ETH_ZLEN, AgoraNetStack.ETH_HLEN + int(frame.get("len", 0)))
	_net().deliver_frame(br, frame)


func _flood(br: AgoraNetStack.Iface, ingress: AgoraNetStack.Iface, frame: Dictionary) -> void:
	for p: AgoraNetStack.Iface in br._port_ifaces():
		if p != ingress:
			_forward(p, frame)


func _forward(p: AgoraNetStack.Iface, frame: Dictionary) -> void:
	if p and p.port_state == "forwarding":
		_net().xmit(p, frame)


func _klog(message: String) -> void:
	var net := _net()
	var m := net._m() if net else null
	if m:
		m.klog(message)
