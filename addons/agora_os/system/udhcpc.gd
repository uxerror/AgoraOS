extends AgoraProgram
## udhcpc, busybox's small DHCP client (as in busybox 1.1.3).
##
## Gets a lease for one interface and hands it to a script
## (/usr/share/udhcpc/default.script) with "deconfig", "bound", "renew",
## "nak" or "leasefail", the details in environment variables (ip, subnet,
## router, dns, domain, lease, serverid, ...). Then it goes into the
## background and renews the lease at half time (T1), rebinds at 7/8 (T2)
## and starts over if it runs out. Lease times run on the machine's clock.
##
## Signals: SIGUSR1 renews now, SIGUSR2 releases the lease, SIGTERM quits.

const VERSION := "1.1.3"
const SCRIPT := "/usr/share/udhcpc/default.script"

enum State { INIT_SELECTING, REQUESTING, BOUND, RENEWING, REBINDING, RELEASED }

var p: AgoraProcess
var iface := "eth0"
var script_path := SCRIPT
var state := State.INIT_SELECTING
var _sock: AgoraUdp.Socket
var _mac := ""
var _xid := 0
var _packet_num := 0
var _requested := 0
var _server := 0
var _lease := 0
var _start := 0.0
var _t1 := 0.0
var _t2 := 0.0
## Real-time deadline while selecting or requesting, game time otherwise.
var _timeout := 0.0
var _signal := 0
var _hostname := ""
var _background_if_no_lease := false
var _abort_if_no_lease := false
var _quit_after_lease := false
var _foreground := false


func summary() -> String:
	return "very small DHCP client"


func usage() -> String:
	return """Usage: udhcpc [-fbnqv] [-c CLIENTID] [-H HOSTNAME] [-i INTERFACE]
	[-p pidfile] [-r IP] [-s script]

  -b    Background if lease cannot be immediately negotiated
  -f    Do not fork after getting lease
  -i    Interface to use (default: eth0)
  -n    Exit with failure if lease cannot be immediately negotiated
  -p    Store process ID of daemon in file
  -q    Quit after obtaining lease
  -r    IP address to request (default: none)
  -s    Run file at dhcp events (default: /usr/share/udhcpc/default.script)
  -H    Hostname to send to the server
  -v    Display version"""


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "cHhiprsV", ["interface", "pidfile", "request", "script", "hostname", "clientid"])
	if not a.error.is_empty():
		p.errln(usage())
		return 1
	if a.has("v"):
		p.outln("udhcpcd, version %s" % VERSION)
		return 0
	iface = a.value("i", a.value("interface", "eth0"))
	script_path = a.value("s", a.value("script", SCRIPT))
	_hostname = a.value("H", a.value("h", a.value("hostname")))
	_background_if_no_lease = a.has("b")
	_abort_if_no_lease = a.has("n")
	_quit_after_lease = a.has("q")
	_foreground = a.has("f")
	if a.has("r"):
		_requested = maxi(0, AgoraInet.parse(a.value("r")))
	var net := p.machine.net
	var i := net.iface(iface)
	if i == null:
		p.errln("udhcpc: SIOCGIFINDEX failed!: No such device")
		return 1
	_mac = i.mac
	_sock = net.udp.open(p, AgoraDhcp.CLIENT_PORT, {"device": iface, "any_dst": true, "broadcast": true})
	if _sock == null:
		p.errln("udhcpc: bind: " + AgoraErrno.describe(net.udp.last_error))
		return 1
	var pidfile := a.value("p", a.value("pidfile"))
	if not pidfile.is_empty():
		p.write_text(pidfile, "%d\n" % p.pid)
	_info("udhcp client (v%s) started" % VERSION)
	p.signal_handler = func(sig: int) -> bool:
		if sig in [AgoraProcess.SIGUSR1, AgoraProcess.SIGUSR2, AgoraProcess.SIGTERM]:
			_signal = sig
			return true
		return false
	await _run_script("deconfig")
	var code: int = await _loop()
	if _sock:
		_sock.close()
	return code


func _info(message: String) -> void:
	p.errln(message)
	if p.tty == null:
		p.machine.log_event("daemon", "udhcpc[%d]" % p.pid, message)


func _real() -> float:
	return Time.get_ticks_msec() / 1000.0


func _now() -> float:
	return p.machine.clock.now()


func _loop() -> int:
	_timeout = _real()
	while p.is_running():
		if _signal != 0:
			var sig := _signal
			_signal = 0
			match sig:
				AgoraProcess.SIGUSR1:
					await _perform_renew()
				AgoraProcess.SIGUSR2:
					await _perform_release()
				AgoraProcess.SIGTERM:
					_info("Received SIGTERM")
					return 0
		var real_wait := state in [State.INIT_SELECTING, State.REQUESTING]
		if (real_wait and _real() >= _timeout) or (not real_wait and state != State.RELEASED and _now() >= _timeout):
			var r: int = await _on_timeout()
			if r >= 0:
				return r
		while _sock and not _sock.inbox.is_empty():
			var dgram: Dictionary = _sock.inbox.pop_front()
			var msg: Variant = dgram.data
			if not AgoraDhcp.is_valid(msg, AgoraDhcp.BOOTREPLY) or msg.xid != _xid or msg.chaddr != _mac:
				continue
			var r: int = await _on_message(msg)
			if r >= 0:
				return r
		await p.sleep(0.05)
	return 0


## Returns an exit code to stop, or -1 to go on.
func _on_timeout() -> int:
	match state:
		State.INIT_SELECTING:
			if _packet_num < 3:
				if _packet_num == 0:
					_xid = AgoraDhcp.random_xid()
				_send_discover()
				_timeout = _real() + (4.0 if _packet_num == 2 else 2.0)
				_packet_num += 1
			else:
				await _run_script("leasefail")
				if _background_if_no_lease:
					_info("No lease, forking to background.")
					_background()
				elif _abort_if_no_lease:
					_info("No lease, failing.")
					return 1
				_packet_num = 0
				_timeout = _real() + 60.0
		State.REQUESTING:
			if _packet_num < 3:
				_send_select()
				_timeout = _real() + 2.0
				_packet_num += 1
			else:
				# Nobody acknowledged: start over.
				state = State.INIT_SELECTING
				_timeout = _real()
				_requested = 0
				_packet_num = 0
		State.BOUND, State.RENEWING:
			if state == State.BOUND:
				state = State.RENEWING
			if _t2 - _t1 <= _lease / 14400.0 + 1.0:
				state = State.REBINDING
				_timeout = _now() + (_t2 - _t1)
			else:
				_send_renew(_server)
				_t1 = (_t2 - _t1) / 2.0 + _t1
				_timeout = _start + _t1
		State.REBINDING:
			if _lease - _t2 <= _lease / 14400.0 + 1.0:
				_info("Lease lost, entering init state")
				await _run_script("deconfig")
				state = State.INIT_SELECTING
				_timeout = _real()
				_requested = 0
				_packet_num = 0
			else:
				_send_renew(0)
				_t2 = (_lease - _t2) / 2.0 + _t2
				_timeout = _start + _t2
	return -1


func _on_message(msg: Dictionary) -> int:
	match state:
		State.INIT_SELECTING:
			if msg.type == "OFFER" and msg.options.has("server_id"):
				_server = msg.options.server_id
				_requested = msg.yiaddr
				state = State.REQUESTING
				_timeout = _real()
				_packet_num = 0
		State.REQUESTING, State.RENEWING, State.REBINDING:
			if msg.type == "ACK":
				var lease: int = msg.options.get("lease", 0)
				if lease == 0:
					_info("No lease time with ACK, using 1 hour lease")
					lease = 3600
				var renewing := state != State.REQUESTING
				_lease = lease
				_start = _now()
				_t1 = lease / 2.0
				_t2 = lease * 0.875
				_timeout = _start + _t1
				_requested = msg.yiaddr
				_info("Lease of %s obtained, lease time %d" % [AgoraInet.to_str(msg.yiaddr), lease])
				await _run_script("renew" if renewing else "bound", msg)
				state = State.BOUND
				if _quit_after_lease:
					return 0
				if not _foreground:
					_background()
			elif msg.type == "NAK":
				_info("Received DHCP NAK")
				await _run_script("nak", msg)
				if state != State.REQUESTING:
					await _run_script("deconfig")
				state = State.INIT_SELECTING
				_requested = 0
				_packet_num = 0
				await p.sleep(3.0)
				_timeout = _real()
	return -1


func _background() -> void:
	p.daemonize()


func _options() -> Dictionary:
	var o := {}
	if not _hostname.is_empty():
		o.hostname = _hostname
	o.client_id = _mac
	return o


func _send_discover() -> void:
	var msg := AgoraDhcp.message(AgoraDhcp.BOOTREQUEST, "DISCOVER", _xid, _mac, _options())
	if _requested != 0:
		msg.options.requested = _requested
	_info("Sending discover...")
	_sock.sendto(AgoraInet.BROADCAST, AgoraDhcp.SERVER_PORT, msg, AgoraDhcp.SIZE)


func _send_select() -> void:
	var msg := AgoraDhcp.message(AgoraDhcp.BOOTREQUEST, "REQUEST", _xid, _mac, _options())
	msg.options.requested = _requested
	msg.options.server_id = _server
	_info("Sending select for %s..." % AgoraInet.to_str(_requested))
	_sock.sendto(AgoraInet.BROADCAST, AgoraDhcp.SERVER_PORT, msg, AgoraDhcp.SIZE)


## Unicast to the server while renewing, broadcast while rebinding.
func _send_renew(server: int) -> void:
	var msg := AgoraDhcp.message(AgoraDhcp.BOOTREQUEST, "REQUEST", _xid, _mac, _options())
	msg.ciaddr = _requested
	_info("Sending renew...")
	if server != 0:
		_sock.sendto(server, AgoraDhcp.SERVER_PORT, msg, AgoraDhcp.SIZE, {"src": _requested})
	else:
		_sock.sendto(AgoraInet.BROADCAST, AgoraDhcp.SERVER_PORT, msg, AgoraDhcp.SIZE, {"src": _requested})


func _perform_renew() -> void:
	_info("Performing a DHCP renew")
	if _sock == null:
		_sock = p.machine.net.udp.open(p, AgoraDhcp.CLIENT_PORT, {"device": iface, "any_dst": true, "broadcast": true})
		if _sock == null:
			return
	match state:
		State.BOUND, State.RENEWING, State.REBINDING:
			state = State.RENEWING
			_timeout = _now()
		State.REQUESTING:
			await _run_script("deconfig")
			state = State.INIT_SELECTING
			_requested = 0
			_packet_num = 0
			_timeout = _real()
		_:
			state = State.INIT_SELECTING
			_packet_num = 0
			_timeout = _real()


func _perform_release() -> void:
	if state in [State.BOUND, State.RENEWING, State.REBINDING]:
		_info("Unicasting a release of %s to %s" % [AgoraInet.to_str(_requested), AgoraInet.to_str(_server)])
		var msg := AgoraDhcp.message(AgoraDhcp.BOOTREQUEST, "RELEASE", AgoraDhcp.random_xid(), _mac, {"server_id": _server})
		msg.ciaddr = _requested
		_sock.sendto(_server, AgoraDhcp.SERVER_PORT, msg, AgoraDhcp.SIZE, {"src": _requested})
		await _run_script("deconfig")
	_info("Entering released state")
	state = State.RELEASED
	# Released, udhcpc listens on nothing until told to renew.
	_sock.close()
	_sock = null


func _run_script(event: String, msg: Dictionary = {}) -> void:
	if not p.exists(script_path):
		return
	var env := {"interface": iface, "PATH": AgoraMachine.DEFAULT_PATH}
	if not msg.is_empty():
		if msg.yiaddr != 0:
			env.ip = AgoraInet.to_str(msg.yiaddr)
		if msg.siaddr != 0:
			env.siaddr = AgoraInet.to_str(msg.siaddr)
		for key: String in msg.options:
			if AgoraDhcp.SCRIPT_VARS.has(key):
				env[AgoraDhcp.SCRIPT_VARS[key]] = AgoraDhcp.option_text(key, msg.options[key])
		env.dhcptype = str(["", "DISCOVER", "OFFER", "REQUEST", "DECLINE", "ACK", "NAK", "RELEASE", "INFORM"].find(msg.type))
	await p.run(PackedStringArray([script_path, event]), {"env": env})
