extends AgoraProgram
## ifup and ifdown (Debian ifupdown 0.8): bring interfaces up or down as
## /etc/network/interfaces describes them. Like the real tool it runs ip(8)
## and the up/down hooks through /bin/sh, and records what is up in
## /run/network/ifstate.
##
##   auto eth0
##   iface eth0 inet static
##       address 192.168.1.10
##       netmask 255.255.255.0
##       gateway 192.168.1.1
##
## Methods: loopback, static, dhcp (udhcpc) and manual.

const INTERFACES := "/etc/network/interfaces"
const STATE := "/run/network/ifstate"
const METHODS: PackedStringArray = ["loopback", "static", "dhcp", "manual"]

var _p: AgoraProcess
var _verbose := false
var _no_act := false
var _down := false
var _me := "ifup"


func summary() -> String:
	return "bring a network interface up" if _me == "ifup" else "take a network interface down"


func usage() -> String:
	return "Usage: %s <options> <ifaces...>\n\n\t-h, --help\t\tthis help\n\t-a, --all\t\tprocess all interfaces marked \"auto\"\n\t-i, --interfaces FILE\tuse FILE for interface definitions\n\t-n, --no-act\t\tprint out what would happen, but don't do it\n\t-v, --verbose\t\tprint out what would happen before doing it\n\t--exclude=PATTERN\texclude interfaces from the list\n\t-f, --force\t\tforce de/configuration" % _me


func main(p: AgoraProcess) -> int:
	_p = p
	_me = AgoraPath.basename(p.argv[0]).trim_prefix("-")
	_down = _me == "ifdown"
	var a := AgoraArgs.parse(p.argv, "i", ["interfaces", "exclude"])
	if not a.error.is_empty() or a.has("h") or a.has("help"):
		p.errln(usage())
		return 1 if not a.error.is_empty() else 0
	_verbose = a.has("v") or a.has("verbose")
	_no_act = a.has("n") or a.has("no-act")
	var force := a.has("f") or a.has("force")
	var file := a.value("i", a.value("interfaces", INTERFACES))
	var exclude := a.value("exclude")
	var all := a.has("a") or a.has("all")
	if not all and a.operands.is_empty():
		p.errln("%s: no interface(s) specified" % _me)
		p.errln(usage())
		return 1
	if not p.exists(file):
		p.errln("%s: couldn't open interfaces file \"%s\": No such file or directory" % [_me, file])
		return 1
	var config := _parse(p.read_text(file))
	if not _no_act and not p.cred.is_root():
		p.errln("%s: failed to open statefile %s: Permission denied" % [_me, STATE])
		return 1
	var state := _read_state()
	var names: PackedStringArray = []
	if all:
		names = state.keys() if _down else config.auto
		if _down:
			names.reverse()
	else:
		names = a.operands
	var status := 0
	for spec in names:
		var dev := spec.get_slice("=", 0)
		var logical := spec.get_slice("=", 1) if spec.contains("=") else dev
		if not exclude.is_empty() and dev.match(exclude):
			continue
		if _down:
			if not state.has(dev) and not force:
				p.errln("ifdown: interface %s not configured" % dev)
				continue
			logical = state.get(dev, logical)
		elif state.has(dev) and not force:
			p.errln("ifup: interface %s already configured" % dev)
			continue
		var stanza: Dictionary = config.ifaces.get(logical, {})
		if stanza.is_empty():
			p.errln("%s: unknown interface %s" % [_me, logical])
			status = 1
			continue
		if p.machine.net.iface(dev) == null and not (stanza.options as Dictionary).has("bridge_ports"):
			p.errln("Cannot find device \"%s\"" % dev)
			status = 1
			continue
		var ok: bool = await _run_stanza(dev, logical, stanza)
		if not ok:
			p.errln("Failed to %s %s." % ["bring down" if _down else "bring up", dev])
			status = 1
			continue
		if not _no_act:
			if _down:
				state.erase(dev)
			else:
				state[dev] = logical
			_write_state(state)
	return status


## {auto: [names], ifaces: {name: {method, options: {key: value}, hooks: {key: [cmds]}}}}
static func _parse(text: String) -> Dictionary:
	var auto: PackedStringArray = []
	var ifaces := {}
	var current: Dictionary = {}
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var words := line.replace("\t", " ").split(" ", false)
		match words[0]:
			"auto", "allow-auto", "allow-hotplug":
				for w in words.slice(1):
					if not auto.has(w):
						auto.append(w)
				current = {}
			"iface":
				if words.size() < 4:
					current = {}
					continue
				current = {"family": words[2], "method": words[3], "options": {}, "hooks": {}}
				if words[2] == "inet":
					ifaces[words[1]] = current
			"mapping", "source", "source-directory":
				current = {}
			_:
				if current.is_empty():
					continue
				var key := words[0]
				var value := line.substr(key.length()).strip_edges()
				if key in ["pre-up", "up", "post-up", "down", "pre-down", "post-down"]:
					if key == "post-up":
						key = "up"
					if key == "pre-down":
						key = "down"
					if not current.hooks.has(key):
						current.hooks[key] = []
					current.hooks[key].append(value)
				else:
					current.options[key] = value
	return {"auto": auto, "ifaces": ifaces}


func _read_state() -> Dictionary:
	var state := {}
	for line in _p.read_text(STATE).split("\n", false):
		state[line.get_slice("=", 0)] = line.get_slice("=", 1)
	return state


func _write_state(state: Dictionary) -> void:
	_p.make_dirs("/run/network")
	var text := ""
	for dev: String in state:
		text += "%s=%s\n" % [dev, state[dev]]
	_p.write_text(STATE, text)


## The commands for one interface, in ifupdown's order.
func _commands(dev: String, stanza: Dictionary) -> Variant:
	var o: Dictionary = stanza.options
	var cmds: PackedStringArray = []
	var link_opts := ""
	if o.has("mtu"):
		link_opts += " mtu " + o.mtu
	if o.has("hwaddress"):
		link_opts += " address " + (o.hwaddress as String).trim_prefix("ether ").strip_edges()
	match stanza.method:
		"loopback":
			cmds.append("ip link set dev %s down" % dev if _down else "ip link set dev %s up" % dev)
		"manual":
			cmds.append("ip link set dev %s down" % dev if _down else "ip link set dev %s%s up" % [dev, link_opts])
		"static":
			if not o.has("address"):
				_p.errln("%s: missing required variable: address" % _me)
				_p.errln("%s: missing required configuration variables for interface %s/inet" % [_me, dev])
				return null
			var addr: String = o.address
			if o.has("netmask") and not addr.contains("/"):
				addr += "/" + o.netmask
			if _down:
				if o.has("gateway"):
					cmds.append("ip route del default via %s%s dev %s 2>/dev/null || true" % [o.gateway, " metric " + o.metric if o.has("metric") else "", dev])
				cmds.append("ip -4 addr flush dev %s label %s" % [dev, dev])
				cmds.append("ip link set dev %s down" % dev)
			else:
				cmds.append("ip addr add %s broadcast %s dev %s label %s" % [addr, o.get("broadcast", "+"), dev, dev])
				cmds.append("ip link set dev %s%s up" % [dev, link_opts])
				if o.has("gateway"):
					cmds.append("ip route add default via %s%s dev %s onlink" % [o.gateway, " metric " + o.metric if o.has("metric") else "", dev])
		"dhcp":
			var pidfile := "/run/udhcpc.%s.pid" % dev
			if not _p.exists("/sbin/udhcpc"):
				_p.errln("No DHCP client software found!")
				return null
			if _down:
				cmds.append("kill $(cat %s) 2>/dev/null" % pidfile)
				cmds.append("ip link set dev %s down" % dev)
			else:
				if not link_opts.is_empty():
					cmds.append("ip link set dev %s%s" % [dev, link_opts])
				var hostname: String = " -x hostname:" + o.hostname if o.has("hostname") else ""
				cmds.append("udhcpc -n -p %s -i %s%s" % [pidfile, dev, hostname])
		_:
			_p.errln("%s: unknown method %s" % [_me, stanza.method])
			return null
	if o.has("bridge_ports"):
		# What bridge-utils' hook scripts do around the method.
		var ports := _bridge_ports(o.bridge_ports)
		var around: PackedStringArray = []
		if _down:
			cmds.append_array(_port_commands(ports, "down"))
			cmds.append("brctl delbr %s" % dev)
			return cmds
		around.append("brctl addbr %s" % dev)
		if o.has("bridge_stp"):
			around.append("brctl stp %s %s" % [dev, o.bridge_stp])
		for port in ports:
			around.append("brctl addif %s %s" % [dev, port])
		around.append_array(_port_commands(ports, "up"))
		around.append_array(cmds)
		return around
	return cmds


func _bridge_ports(spec: String) -> PackedStringArray:
	if spec == "none":
		return []
	if spec == "all":
		var out: PackedStringArray = []
		for i in _p.machine.net.interfaces:
			if i.nic:
				out.append(i.name)
		return out
	return spec.split(" ", false)


static func _port_commands(ports: PackedStringArray, verb: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for port in ports:
		out.append("ip link set dev %s %s" % [port, verb])
	return out


func _run_stanza(dev: String, logical: String, stanza: Dictionary) -> bool:
	var cmds: Variant = _commands(dev, stanza)
	if cmds == null:
		return false
	var hooks: Dictionary = stanza.hooks
	var env := {
		"IFACE": dev, "LOGICAL": logical, "ADDRFAM": "inet", "METHOD": stanza.method,
		"MODE": "stop" if _down else "start", "PATH": AgoraMachine.DEFAULT_PATH,
		"VERBOSITY": "1" if _verbose else "0",
	}
	for key: String in stanza.options:
		env["IF_" + key.to_upper().replace("-", "_")] = stanza.options[key]
	if _verbose:
		_p.errln("%s interface %s=%s (inet)" % ["Deconfiguring" if _down else "Configuring", dev, logical])
	# Hooks: pre-up, the method, up; down, the method, post-down.
	var phases: Array = []
	if _down:
		phases = [["pre-down", hooks.get("down", [])], ["", cmds], ["post-down", hooks.get("post-down", [])]]
	else:
		phases = [["pre-up", hooks.get("pre-up", [])], ["", cmds], ["post-up", hooks.get("up", [])]]
	for phase: Array in phases:
		env.PHASE = phase[0] if not (phase[0] as String).is_empty() else ("down" if _down else "up")
		for cmd: String in phase[1]:
			if _verbose or _no_act:
				_p.errln(cmd)
			if _no_act:
				continue
			var code: int = await _p.run(PackedStringArray(["/bin/sh", "-c", cmd]), {"env": env})
			# Taking an interface down carries on regardless, like ifupdown.
			if code != 0 and not _down:
				return false
	return true
