extends AgoraProgram
## openbsd-inetd: the Internet super-server. It listens on the ports of the
## services in /etc/inetd.conf and, for each connection, starts the
## server named there with the connection on its standard input and
## output. SIGHUP rereads the file.
##
## inetd.conf lines: service socket-type protocol wait/nowait user
## server-program server-arguments (the first argument is argv[0]).
## Service names are looked up in /etc/services. Only TCP stream services
## with "nowait" are supported; lines starting with "#" are off.

const CONF := "/etc/inetd.conf"

var p: AgoraProcess
## "service/proto" -> {entry, listener}.
var _services := {}


func summary() -> String:
	return "the Internet super-server"


func usage() -> String:
	return "usage: inetd [-d] [-i] [-q queuelength] [configuration file]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "q")
	if not p.cred.is_root():
		return p.fail("inetd: must be run as root", 1)
	var conf := a.operands[0] if not a.operands.is_empty() else CONF
	p.signal_handler = func(sig: int) -> bool:
		if sig == AgoraProcess.SIGHUP:
			_load(conf)
			return true
		return false
	_load(conf)
	while p.is_running():
		await p.sleep(1.0)
	for key: String in _services:
		_services[key].listener.close()
	_services.clear()
	return 0


func _log(message: String) -> void:
	p.machine.log_event("daemon", "inetd[%d]" % p.pid, message)


## Reads the configuration: new services start listening, removed or
## changed ones stop.
func _load(conf: String) -> void:
	var wanted := {}
	if not p.exists(conf):
		_log("%s: No such file or directory" % conf)
	for line in p.read_text(conf).split("\n", false):
		var e := _parse(line)
		if e.is_empty():
			continue
		wanted["%s/%s" % [e.service, e.proto]] = e
	for key: String in _services.keys():
		if not wanted.has(key) or wanted[key].line != _services[key].entry.line:
			_services[key].listener.close()
			_services.erase(key)
	for key: String in wanted:
		if _services.has(key):
			continue
		var e: Dictionary = wanted[key]
		if e.proto != "tcp" or e.socktype != "stream" or e.wait != "nowait":
			_log("%s: %s/%s %s not supported" % [e.service, e.socktype, e.proto, e.wait])
			continue
		var port := _port(e.service)
		if port <= 0:
			_log("%s/%s: unknown service" % [e.service, e.proto])
			continue
		var listener := p.machine.net.tcp.listen(p, port)
		if listener == null:
			_log("%s/%s: bind: %s" % [e.service, e.proto, AgoraErrno.describe(p.machine.net.tcp.last_error)])
			continue
		_services[key] = {"entry": e, "listener": listener}
		_serve(key, listener, e)


## {service, socktype, proto, wait, user, program, argv, line} or {}.
static func _parse(line: String) -> Dictionary:
	line = line.strip_edges()
	if line.is_empty() or line.begins_with("#"):
		return {}
	var w := line.replace("\t", " ").split(" ", false)
	if w.size() < 6:
		return {}
	var argv := w.slice(6) if w.size() > 6 else PackedStringArray([AgoraPath.basename(w[5])])
	return {
		"service": w[0], "socktype": w[1], "proto": w[2], "wait": w[3].get_slice(".", 0),
		"user": w[4].get_slice(":", 0).get_slice(".", 0), "program": w[5], "argv": argv, "line": line,
	}


## The port of [param service], a name from /etc/services or a number.
func _port(service: String) -> int:
	if service.is_valid_int():
		return service.to_int()
	for line in p.read_text("/etc/services").split("\n", false):
		var w := line.get_slice("#", 0).replace("\t", " ").split(" ", false)
		if w.size() < 2 or not w[1].ends_with("/tcp"):
			continue
		if w[0] == service or w.slice(2).has(service):
			return w[1].get_slice("/", 0).to_int()
	return 0


func _serve(key: String, listener: AgoraTcp.Listener, e: Dictionary) -> void:
	var gone := func() -> bool: return p.is_dead() or _services.get(key, {}).get("listener") != listener
	while not gone.call():
		var conn: AgoraTcp.Conn = await listener.accept(gone)
		if conn:
			_start(conn, e)


func _start(conn: AgoraTcp.Conn, e: Dictionary) -> void:
	var users := p.machine.users
	if users.find(e.user).is_empty():
		_log("%s/%s: %s: No such user" % [e.service, e.proto, e.user])
		conn.close()
		return
	var argv := PackedStringArray([e.program])
	argv.append_array(e.argv.slice(1))
	var child := p.machine.spawn(argv, {
		"cred": users.cred_for(e.user), "env": {"PATH": AgoraMachine.DEFAULT_PATH},
		"stdin": conn.input, "stdout": conn.output, "stderr": conn.output,
		"parent": p, "new_session": true, "start": false,
	})
	if child == null:
		_log("%s/%s: %s: %s" % [e.service, e.proto, e.program, AgoraErrno.describe(p.machine.errno)])
		conn.close()
		return
	child.argv[0] = e.argv[0]
	child.name = AgoraPath.basename(e.argv[0])
	child.socket = conn
	conn.pid = child.pid
	child.start()
	await child.wait()
	conn.close()
