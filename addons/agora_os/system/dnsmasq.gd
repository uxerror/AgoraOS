extends AgoraProgram
## dnsmasq (DNS only): a small caching DNS forwarder.
##
## Answers from /etc/hosts (and addn-hosts), address= and cname= lines,
## keeps names of local= domains to itself (NXDOMAIN when unknown), and
## forwards everything else to the servers of server= lines or of
## resolv-file (re-read when it changes), caching the answers. Options come
## from /etc/dnsmasq.conf (-C), conf-dir= files and the command line:
##
##   domain=lan  expand-hosts  local=/lan/  server=1.2.3.4
##   server=/corp/10.0.0.53  address=/ads.example/127.0.0.1
##   cname=www.lan,gw.lan  no-resolv  resolv-file=FILE  no-hosts
##   addn-hosts=FILE  domain-needed  bogus-priv  interface=br-lan
##   listen-address=IP  port=53  cache-size=150  local-ttl=0  log-queries
##
## -k / --keep-in-foreground, -d / --no-daemon, -q / --log-queries.

const VERSION := "2.85"
const FORWARD_TIMEOUT := 2.0
const TICK := 0.016

var p: AgoraProcess
var opts := {}
var _sock: AgoraUdp.Socket
var _hosts: Array = [] # [[address, [names]]]
var _upstream: Array = [] # [[domain or "", address]]
var _resolv_mtime := -1
var _cache := {} # "name|type" -> {expires, answer}
var _stop := false


func summary() -> String:
	return "a lightweight caching DNS server"


func usage() -> String:
	return "Usage: dnsmasq [options]\n\n  -C, --conf-file=path   Specify configuration file (defaults to /etc/dnsmasq.conf).\n  -k, --keep-in-foreground  Do NOT fork into the background.\n  -d, --no-daemon        Do NOT fork into the background: run in debug mode.\n  -q, --log-queries      Log DNS queries."


func main(proc: AgoraProcess) -> int:
	p = proc
	opts = {
		"port": 53, "domain": "", "local": [], "server": [], "address": [], "cname": {},
		"no-resolv": false, "resolv-file": "/etc/resolv.conf", "no-hosts": false, "addn-hosts": [],
		"expand-hosts": false, "domain-needed": false, "bogus-priv": false, "interface": [],
		"listen-address": [], "cache-size": 150, "local-ttl": 0, "log-queries": false,
	}
	var conf := "/etc/dnsmasq.conf"
	var foreground := false
	var cmdline: PackedStringArray = []
	var args := p.argv.slice(1)
	var i := 0
	while i < args.size():
		var a := args[i]
		match a:
			"-C":
				conf = args[i + 1] if i + 1 < args.size() else conf
				i += 1
			"-k", "--keep-in-foreground", "-d", "--no-daemon":
				foreground = true
			"-q":
				cmdline.append("log-queries")
			_:
				if a.begins_with("--conf-file="):
					conf = a.get_slice("=", 1)
				elif a.begins_with("--"):
					cmdline.append(a.substr(2))
				else:
					p.errln("dnsmasq: bad command line options: try --help")
					return 1
		i += 1
	if p.exists(conf):
		var err := _read_conf(conf)
		if not err.is_empty():
			p.errln("dnsmasq: " + err)
			return 1
	for line in cmdline:
		_option(line, "command line")
	if not p.cred.is_root():
		p.errln("dnsmasq: failed to create listening socket for port %d: Permission denied" % opts.port)
		return 2
	if opts.port == 0:
		_log("started, version %s DNS disabled" % VERSION)
		return 0
	_sock = p.machine.net.udp.open(p, opts.port)
	if _sock == null:
		var msg := "failed to create listening socket for port %d: %s" % [opts.port, AgoraErrno.describe(p.machine.net.udp.last_error)]
		p.errln("dnsmasq: " + msg)
		_log(msg)
		return 2
	_log("started, version %s cachesize %d" % [VERSION, opts["cache-size"]])
	_log("compile time options: IPv6 GNU-getopt no-DBus no-UBus no-i18n no-IDN no-DHCP no-Lua TFTP no-conntrack no-ipset no-auth no-DNSSEC loop-detect inotify dumpfile")
	for d: String in opts.local:
		_log("using only locally-known addresses for domain %s" % d)
	_read_upstream(true)
	_read_hosts()
	p.signal_handler = func(sig: int) -> bool:
		if sig == AgoraProcess.SIGHUP:
			_read_hosts()
			_cache.clear()
			return true
		if sig == AgoraProcess.SIGTERM:
			_log("exiting on receipt of SIGTERM")
			_stop = true
			return true
		return false
	if not foreground:
		p.daemonize()
	while not _stop and p.is_running():
		while not _sock.inbox.is_empty():
			var d: Dictionary = _sock.inbox.pop_front()
			if AgoraDns.is_valid(d.data) and not d.data.qr and _serves(d):
				_answer(d) # in parallel: forwarding waits for upstream
		await p.sleep(0.02)
	_sock.close()
	return 0


func _log(message: String) -> void:
	p.machine.log_event("daemon", "dnsmasq[%d]" % p.pid, message)


# --- configuration ------------------------------------------------------------------

func _read_conf(path: String) -> String:
	var n := 0
	for raw in p.read_text(path).split("\n"):
		n += 1
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var err := _option(line, path)
		if not err.is_empty():
			return "%s at line %d of %s" % [err, n, path]
	return ""


func _option(line: String, _where: String) -> String:
	var key := line.get_slice("=", 0).strip_edges()
	var value := line.substr(line.find("=") + 1).strip_edges() if line.contains("=") else ""
	match key:
		"port", "cache-size", "local-ttl":
			if not value.is_valid_int():
				return "bad number"
			opts[key] = int(value)
		"domain", "resolv-file":
			opts[key] = value
		"local", "interface", "addn-hosts":
			opts[key].append(value.trim_prefix("/").trim_suffix("/") if key == "local" else value)
		"listen-address":
			opts[key].append(AgoraInet.parse(value))
		"server":
			# server=1.2.3.4 or server=/domain/1.2.3.4
			if value.begins_with("/"):
				var parts := value.split("/")
				opts.server.append([AgoraDns.normalize(parts[1]), AgoraInet.parse(parts[2].get_slice("#", 0))])
			else:
				opts.server.append(["", AgoraInet.parse(value.get_slice("#", 0))])
		"address":
			var parts := value.split("/")
			if parts.size() < 3:
				return "bad address"
			opts.address.append([AgoraDns.normalize(parts[1]), parts[2]])
		"cname":
			opts.cname[AgoraDns.normalize(value.get_slice(",", 0))] = AgoraDns.normalize(value.get_slice(",", 1))
		"no-resolv", "no-hosts", "expand-hosts", "domain-needed", "bogus-priv", "log-queries":
			opts[key] = true
		"conf-dir":
			var dir := value.get_slice(",", 0)
			var pattern := value.get_slice(",", 1) if value.contains(",") else "*"
			for name in p.list_dir(dir):
				if name.match(pattern) and not name.ends_with("~"):
					var err := _read_conf(dir.trim_suffix("/") + "/" + name)
					if not err.is_empty():
						return err
		"conf-file":
			return _read_conf(value)
		"user", "group", "bind-interfaces", "strict-order", "no-negcache", "keep-in-foreground", "no-daemon", "except-interface", "pid-file":
			pass
		_:
			return "bad option"
	return ""


func _read_hosts() -> void:
	_hosts.clear()
	var files: Array = [] if opts["no-hosts"] else ["/etc/hosts"]
	files.append_array(opts["addn-hosts"])
	for file: String in files:
		var count := 0
		for line in p.read_text(file).split("\n", false):
			var words := line.get_slice("#", 0).strip_edges().replace("\t", " ").split(" ", false)
			var addr := AgoraInet.parse(words[0]) if words.size() >= 2 else -1
			if addr < 0:
				continue
			var names: Array = []
			for w in words.slice(1):
				var name := AgoraDns.normalize(w)
				if opts["expand-hosts"] and not name.contains(".") and not (opts.domain as String).is_empty():
					names.append("%s.%s" % [name, opts.domain])
				names.append(name)
			_hosts.append([addr, names])
			count += 1
		_log("read %s - %d addresses" % [file, count])


## Upstream servers: server= lines, and resolv-file unless no-resolv. The
## machine's own addresses are left out.
func _read_upstream(always: bool = false) -> void:
	var file: String = opts["resolv-file"]
	var st := p.stat(file)
	var mtime := st.mtime if st else 0
	if not always and mtime == _resolv_mtime:
		return
	_resolv_mtime = mtime
	_upstream = (opts.server as Array).duplicate()
	if not opts["no-resolv"]:
		if st:
			_log("reading %s" % file)
		for line in p.read_text(file).split("\n"):
			var words := line.strip_edges().split(" ", false)
			if words.size() >= 2 and words[0] == "nameserver":
				var ns := AgoraInet.parse(words[1])
				if ns >= 0 and not p.machine.net.is_local(ns):
					_upstream.append(["", ns])
	for u: Array in _upstream:
		if (u[0] as String).is_empty():
			_log("using nameserver %s#53" % AgoraInet.to_str(u[1]))
		else:
			_log("using nameserver %s#53 for domain %s" % [AgoraInet.to_str(u[1]), u[0]])


## Only on the interfaces and addresses we were told to use (lo always).
func _serves(d: Dictionary) -> bool:
	if not (opts.interface as Array).is_empty() and d.iface != "lo" and not (opts.interface as Array).has(d.iface):
		return false
	if not (opts["listen-address"] as Array).is_empty() and not (opts["listen-address"] as Array).has(d.dst):
		return false
	return true


# --- answering ----------------------------------------------------------------------

static func _in_domain(name: String, domain: String) -> bool:
	return name == domain or name.ends_with("." + domain)


func _answer(d: Dictionary) -> void:
	var q: Dictionary = d.data
	var question: Dictionary = (q.question as Array)[0] if not (q.question as Array).is_empty() else {}
	if question.is_empty():
		return
	var name: String = AgoraDns.normalize(question.name)
	var type: String = question.type
	if opts["log-queries"]:
		_log("query[%s] %s from %s" % [type, name, AgoraInet.to_str(d.src)])
	var r := _local(q, name, type)
	if r.is_empty():
		r = await _forward(q, name, type)
	if r.is_empty():
		return
	r.id = q.id
	_sock.sendto(d.src, d.sport, r, AgoraDns.size(r), {"src": d.dst})


## An answer from what dnsmasq knows itself, or {} to forward.
func _local(q: Dictionary, name: String, type: String) -> Dictionary:
	var ttl: int = opts["local-ttl"]
	if type == "PTR":
		var addr := AgoraDns.ptr_address(name)
		for h: Array in _hosts:
			if h[0] == addr:
				var r := AgoraDns.reply(q)
				r.aa = true
				r.answer.append(AgoraDns.record(name, "PTR", ttl, h[1][0]))
				_logged("/etc/hosts %s is %s" % [AgoraInet.to_str(addr), h[1][0]])
				return r
		if addr >= 0 and opts["bogus-priv"] and AgoraDns.is_private(addr):
			_logged("config %s is NXDOMAIN" % AgoraInet.to_str(addr))
			return AgoraDns.reply(q, "NXDOMAIN")
		return {}
	for a: Array in opts.address:
		if _in_domain(name, a[0]):
			var r := AgoraDns.reply(q)
			if type == "A" or type == "ANY":
				r.answer.append(AgoraDns.record(name, "A", ttl, a[1]))
			_logged("config %s is %s" % [name, a[1]])
			return r
	if opts.cname.has(name):
		var target: String = opts.cname[name]
		var r := AgoraDns.reply(q)
		r.aa = true
		r.answer.append(AgoraDns.record(name, "CNAME", ttl, target))
		for h: Array in _hosts:
			if (h[1] as Array).has(target) and (type == "A" or type == "ANY"):
				r.answer.append(AgoraDns.record(target, "A", ttl, AgoraInet.to_str(h[0])))
		_logged("config %s is <CNAME>" % name)
		return r
	var known := false
	var r := AgoraDns.reply(q)
	r.aa = true
	for h: Array in _hosts:
		if (h[1] as Array).has(name):
			known = true
			if type == "A" or type == "ANY":
				r.answer.append(AgoraDns.record(name, "A", ttl, AgoraInet.to_str(h[0])))
				_logged("/etc/hosts %s is %s" % [name, AgoraInet.to_str(h[0])])
	if known:
		return r # a name we know, maybe without records of this type
	for d: String in opts.local:
		if _in_domain(name, d):
			_logged("config %s is NXDOMAIN" % name)
			return AgoraDns.reply(q, "NXDOMAIN")
	if opts["domain-needed"] and not name.contains(".") and type in ["A", "AAAA", "ANY"]:
		_logged("config %s is NXDOMAIN" % name)
		return AgoraDns.reply(q, "NXDOMAIN")
	var hit: Dictionary = _cache.get(name + "|" + type, {})
	if not hit.is_empty() and hit.expires > _now():
		var cached := AgoraDns.reply(q)
		var left := int(hit.expires - _now())
		for rr: Dictionary in hit.answer:
			var copy := rr.duplicate()
			copy.ttl = mini(int(rr.ttl), left)
			cached.answer.append(copy)
		_logged("cached %s is %s" % [name, _summary(cached)])
		return cached
	return {}


func _logged(message: String) -> void:
	if opts["log-queries"]:
		_log(message)


static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0


static func _summary(r: Dictionary) -> String:
	if r.rcode != "NOERROR":
		return r.rcode
	for rr: Dictionary in r.answer:
		if rr.type in ["A", "PTR"]:
			return rr.data
	return "NODATA" if (r.answer as Array).is_empty() else "<CNAME>"


## Asks the upstream servers in turn; {} if none of them answers.
func _forward(q: Dictionary, name: String, type: String) -> Dictionary:
	_read_upstream()
	# server=/domain/ip wins for its domain (the longest match), then the rest.
	var servers: Array = []
	var best := ""
	for u: Array in _upstream:
		var domain: String = u[0]
		if not domain.is_empty() and _in_domain(name, domain) and domain.length() >= best.length():
			if domain.length() > best.length():
				servers.clear()
			best = domain
			servers.append(u[1])
	if best.is_empty():
		for u: Array in _upstream:
			if (u[0] as String).is_empty():
				servers.append(u[1])
	if servers.is_empty():
		return AgoraDns.reply(q, "REFUSED")
	var sock := p.machine.net.udp.open(p, 0)
	if sock == null:
		return {}
	var tree := Engine.get_main_loop() as SceneTree
	for ns: int in servers:
		var fq := AgoraDns.query(AgoraDns.random_id(), name, type, q.get("rd", true))
		if sock.sendto(ns, AgoraDns.PORT, fq, AgoraDns.size(fq)) != AgoraErrno.OK:
			continue
		_logged("forwarded %s to %s" % [name, AgoraInet.to_str(ns)])
		var deadline := _now() + FORWARD_TIMEOUT
		while _now() < deadline and p.is_running() and tree:
			var refused := false
			for e in sock.errors:
				refused = refused or e.dst == ns
			sock.errors.clear()
			if refused:
				break
			for dgram: Dictionary in sock.inbox:
				if dgram.src == ns and AgoraDns.is_valid(dgram.data) and dgram.data.id == fq.id and dgram.data.qr:
					sock.close()
					var r: Dictionary = dgram.data.duplicate(true)
					r.aa = false
					r.ra = true
					r.question = q.question
					_store(name, type, r)
					_logged("reply %s is %s" % [name, _summary(r)])
					return r
			sock.inbox.clear()
			await tree.create_timer(TICK).timeout
	sock.close()
	return {}


func _store(name: String, type: String, r: Dictionary) -> void:
	if r.rcode != "NOERROR" or (r.answer as Array).is_empty() or opts["cache-size"] == 0:
		return
	var ttl := 86400
	for rr: Dictionary in r.answer:
		ttl = mini(ttl, int(rr.ttl))
	if ttl <= 0:
		return
	if _cache.size() >= opts["cache-size"]:
		_cache.erase(_cache.keys()[0])
	_cache[name + "|" + type] = {"expires": _now() + ttl, "answer": (r.answer as Array).duplicate(true)}
