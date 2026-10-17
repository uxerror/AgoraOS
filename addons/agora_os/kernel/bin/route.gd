extends AgoraProgram
## net-tools route: prints the kernel routing table from /proc/net/route
## and adds or deletes routes the old way (SIOCADDRT / SIOCDELRT).

const RTF_UP := 0x1
const RTF_GATEWAY := 0x2
const RTF_HOST := 0x4
const RTF_REJECT := 0x200

const E_SOCK := 7
const E_USAGE := 4
const E_OPTERR := 3
const E_LOOKUP := 6


func summary() -> String:
	return "show or change the IP routing table"


func usage() -> String:
	return """Usage: route [-nNvee] [-FC] [<AF>]           List kernel routing tables
       route [-v] [-FC] {add|del|flush} ...  Modify routing table for AF.

  inet_route [-vF] del {-host|-net} Target[/prefix] [gw Gw] [metric M] [[dev] If]
  inet_route [-vF] add {-host|-net} Target[/prefix] [gw Gw] [metric M]
                         [netmask N] [mss Mss] [window W] [irtt I]
                         [mod] [dyn] [reinstate] [[dev] If]
  inet_route [-vF] add {-host|-net} Target[/prefix] [metric M] reject"""


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var numeric := false
	while not args.is_empty() and args[0].begins_with("-") and not args[0] in ["-net", "-host"]:
		var opt := args[0]
		args = args.slice(1)
		if opt == "-A":
			if args.is_empty():
				p.errln(usage())
				return E_USAGE
			args = args.slice(1)
			continue
		for c in opt.substr(1):
			match c:
				"n": numeric = true
				"e", "v", "F", "C", "N": pass
				_:
					p.errln(usage())
					return E_USAGE
	if not args.is_empty() and args[0] == "inet":
		args = args.slice(1)
	if args.is_empty():
		return _show(p, numeric)
	match args[0]:
		"add", "del":
			return _change(p, args[0], args.slice(1))
		"flush":
			return 0
	p.errln(usage())
	return E_USAGE


func _show(p: AgoraProcess, numeric: bool) -> int:
	var text := p.read_text("/proc/net/route")
	if text.is_empty():
		return p.fail("/proc/net/route: No such file or directory", 1)
	p.outln("Kernel IP routing table")
	p.outln("Destination     Gateway         Genmask         Flags Metric Ref    Use Iface")
	var lines := text.split("\n", false)
	for k in range(1, lines.size()):
		var f := lines[k].strip_edges().split("\t")
		if f.size() < 8:
			continue
		var dst := _from_le_hex(f[1])
		var gw := _from_le_hex(f[2])
		var flags := f[3].hex_to_int()
		var mask := _from_le_hex(f[7])
		var letters := ""
		if flags & RTF_UP:
			letters += "U"
		if flags & RTF_GATEWAY:
			letters += "G"
		if flags & RTF_HOST:
			letters += "H"
		if flags & RTF_REJECT:
			letters += "!"
		var dst_text := AgoraInet.to_str(dst)
		var gw_text := AgoraInet.to_str(gw)
		if not numeric:
			if dst == 0 and mask == 0:
				dst_text = "default"
			if gw == 0:
				gw_text = "*"
		var iface := "-" if flags & RTF_REJECT else f[0]
		p.outln("%-15s %-15s %-15s %-5s %-6d %-3d %6d %s" % [dst_text, gw_text, AgoraInet.to_str(mask), letters, int(f[6]), 0, 0, iface])
	return 0


static func _from_le_hex(text: String) -> int:
	var v := text.hex_to_int()
	return ((v & 255) << 24) | (((v >> 8) & 255) << 16) | (((v >> 16) & 255) << 8) | ((v >> 24) & 255)


func _change(p: AgoraProcess, cmd: String, args: PackedStringArray) -> int:
	var kind := ""
	var target := -1
	var prefix := -1
	var opts := {}
	var i := 0
	while i < args.size():
		var a := args[i]
		var v := args[i + 1] if i + 1 < args.size() else ""
		match a:
			"-net", "-host":
				kind = a
			"gw", "netmask", "metric", "dev", "mss", "window", "irtt":
				if v.is_empty():
					p.errln(usage())
					return E_USAGE
				i += 1
				match a:
					"gw":
						var gw := AgoraInet.parse(v)
						if gw < 0:
							p.errln("%s: Unknown host" % v)
							return E_LOOKUP
						opts.gateway = gw
					"netmask":
						var m := AgoraInet.parse(v)
						prefix = AgoraInet.prefix_of_mask(m) if m >= 0 else -1
						if prefix < 0:
							p.errln("route: bogus netmask %s" % v)
							return E_OPTERR
					"metric":
						opts.metric = int(v)
					"dev":
						opts.dev = v
			"reject":
				opts.type = "unreachable"
			"mod", "dyn", "reinstate":
				pass
			_:
				if target < 0:
					if a == "default":
						target = 0
						prefix = 0
					else:
						var cidr := AgoraInet.parse_cidr(a, -1)
						if cidr.is_empty():
							p.errln("%s: Unknown host" % a)
							return E_LOOKUP
						target = cidr[0]
						if cidr[1] >= 0:
							prefix = cidr[1]
				else:
					opts.dev = a # a trailing interface name
		i += 1
	if target < 0:
		p.errln(usage())
		return E_USAGE
	if prefix < 0:
		prefix = 32 if kind != "-net" else _classful_prefix(target)
	if kind == "-host" and prefix != 32:
		p.errln("route: netmask doesn't make sense with host route")
		return E_OPTERR
	if AgoraInet.network(target, prefix) != target:
		p.errln("route: netmask %s doesn't match route address" % AgoraInet.to_str(AgoraInet.mask(prefix)))
		return E_OPTERR
	var call := "SIOCADDRT" if cmd == "add" else "SIOCDELRT"
	if not p.cred.is_root():
		p.errln("%s: Operation not permitted" % call)
		return E_SOCK
	var net := p.machine.net
	if opts.has("dev") and net.iface(opts.dev) == null:
		p.errln("%s: No such device" % call)
		return E_SOCK
	var code := net.add_route(target, prefix, opts) if cmd == "add" else net.del_route(target, prefix, opts)
	if code != AgoraErrno.OK:
		p.errln("%s: %s" % [call, AgoraErrno.describe(code)])
		return E_SOCK
	return 0


static func _classful_prefix(addr: int) -> int:
	var first := addr >> 24
	if addr == 0:
		return 0
	if first < 128:
		return 8
	if first < 192:
		return 16
	return 24
