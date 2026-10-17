extends AgoraProgram
## iptables (1.8.7, legacy): edits the kernel's filter and nat tables.
## Also iptables-save and iptables-restore, chosen by the name it runs as.

const VERSION := "v1.8.7 (legacy)"
const PROTOS := {"tcp": 6, "udp": 17, "icmp": 1, "all": 0}
const STATES: PackedStringArray = ["INVALID", "NEW", "RELATED", "ESTABLISHED", "UNTRACKED"]
const SERVICES := {
	20: "ftp-data", 21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "domain", 67: "bootps",
	68: "bootpc", 69: "tftp", 80: "http", 110: "pop3", 123: "ntp", 143: "imap2", 161: "snmp",
	443: "https", 993: "imaps", 995: "pop3s", 3306: "mysql", 6667: "ircd",
}
const ICMP_TYPES := {
	"any": [-1, -1], "echo-reply": [0, -1], "pong": [0, -1], "destination-unreachable": [3, -1],
	"network-unreachable": [3, 0], "host-unreachable": [3, 1], "protocol-unreachable": [3, 2],
	"port-unreachable": [3, 3], "source-quench": [4, -1], "redirect": [5, -1],
	"echo-request": [8, -1], "ping": [8, -1], "time-exceeded": [11, -1], "ttl-exceeded": [11, -1],
	"parameter-problem": [12, -1], "timestamp-request": [13, -1], "timestamp-reply": [14, -1],
}
const COMMANDS := {
	"-A": "append", "--append": "append", "-I": "insert", "--insert": "insert",
	"-D": "delete", "--delete": "delete", "-R": "replace", "--replace": "replace",
	"-F": "flush", "--flush": "flush", "-Z": "zero", "--zero": "zero", "-L": "list", "--list": "list",
	"-S": "list-rules", "--list-rules": "list-rules", "-N": "new", "--new-chain": "new",
	"-X": "delete-chain", "--delete-chain": "delete-chain", "-P": "policy", "--policy": "policy",
	"-E": "rename", "--rename-chain": "rename",
}

var p: AgoraProcess
var nf: AgoraNetfilter
var _numeric := false
var _verbose := false
var _exact := false
var _line_numbers := false


func summary() -> String:
	return "administration tool for IPv4 packet filtering and NAT"


func usage() -> String:
	return """iptables %s

Usage: iptables -[ACD] chain rule-specification [options]
       iptables -I chain [rulenum] rule-specification [options]
       iptables -R chain rulenum rule-specification [options]
       iptables -D chain rulenum [options]
       iptables -[LS] [chain [rulenum]] [options]
       iptables -[FZ] [chain] [options]
       iptables -[NX] chain
       iptables -E old-chain-name new-chain-name
       iptables -P chain target [options]
       iptables -h (print this help information)""" % VERSION


func _fail(message: String, code: int = 1) -> int:
	p.errln(message)
	return code


func _bad_arg(message: String) -> int:
	p.errln("iptables %s: %s\nTry `iptables -h' or 'iptables --help' for more information." % [VERSION, message])
	return 2


func main(proc: AgoraProcess) -> int:
	p = proc
	nf = p.machine.net.netfilter
	var me := AgoraPath.basename(p.argv[0])
	if me == "iptables-save":
		return _save()
	if me == "iptables-restore":
		return await _restore()
	return _command(_expand(p.argv.slice(1)), true)


## Splits bundled short flags like "-nvL".
static func _expand(args: PackedStringArray) -> PackedStringArray:
	var out: PackedStringArray = []
	for a in args:
		if a.length() > 2 and a.begins_with("-") and not a.begins_with("--"):
			var ok := true
			for c in a.substr(1):
				if not "nvxLFZSX".contains(c):
					ok = false
			if ok:
				for c in a.substr(1):
					out.append("-" + c)
				continue
		out.append(a)
	return out


func _check_table(table: String, as_root: bool) -> int:
	if as_root and not p.cred.is_root():
		return _fail("iptables %s: can't initialize iptables table `%s': Permission denied (you must be root)\nPerhaps iptables or your kernel needs to be upgraded." % [VERSION, table], 3)
	if not nf.tables.has(table):
		return _fail("iptables %s: can't initialize iptables table `%s': Table does not exist (do you need to insmod?)\nPerhaps iptables or your kernel needs to be upgraded." % [VERSION, table], 3)
	return 0


## Runs one iptables command line. [param check_root] is false when
## iptables-restore already checked.
func _command(args: PackedStringArray, check_root: bool) -> int:
	if args.is_empty():
		return _bad_arg("no command specified")
	if args[0] in ["-h", "--help"]:
		p.outln(usage())
		return 0
	if args[0] in ["-V", "--version"]:
		p.outln("iptables " + VERSION)
		return 0
	var table := "filter"
	var command := ""
	var chain_name := ""
	var extra: PackedStringArray = []
	var spec: PackedStringArray = []
	var i := 0
	while i < args.size():
		var a := args[i]
		if a in ["-t", "--table"]:
			if i + 1 >= args.size():
				return _bad_arg("option \"%s\" requires an argument" % a)
			table = args[i + 1]
			i += 2
			continue
		if COMMANDS.has(a):
			if not command.is_empty():
				return _bad_arg("Cannot use -%s with -%s" % [a.trim_prefix("-")[0].to_upper(), command[0].to_upper()])
			command = COMMANDS[a]
			# The chain and the numbers after it.
			while i + 1 < args.size() and not args[i + 1].begins_with("-") and args[i + 1] != "!":
				if chain_name.is_empty():
					chain_name = args[i + 1]
				else:
					extra.append(args[i + 1])
				i += 1
			i += 1
			continue
		match a:
			"-n", "--numeric": _numeric = true
			"-v", "--verbose": _verbose = true
			"-x", "--exact": _exact = true
			"--line-numbers": _line_numbers = true
			_: spec.append(a)
		i += 1
	if command.is_empty():
		return _bad_arg("no command specified")
	var code := _check_table(table, check_root)
	if code != 0:
		return code
	var builtin_only := command == "policy"
	if not chain_name.is_empty() and command != "new" and nf.chain(table, chain_name).is_empty():
		if builtin_only:
			return _fail("iptables: Bad built-in chain name.")
		return _fail("iptables: No chain/target/match by that name.")
	match command:
		"list":
			return _list(table, chain_name)
		"list-rules":
			return _list_rules(table, chain_name)
		"flush", "zero":
			for c: String in ([chain_name] if not chain_name.is_empty() else nf.tables[table].keys()):
				if command == "flush":
					nf.tables[table][c].rules.clear()
				else:
					_zero(nf.tables[table][c])
			if command == "flush" and table == "nat":
				nf.conntrack.flush()
			return 0
		"new":
			if chain_name.is_empty():
				return _bad_arg("-N requires a chain name")
			if nf.tables[table].has(chain_name):
				return _fail("iptables: Chain already exists.")
			if chain_name.length() > 28 or AgoraNetfilter.VERDICTS.has(chain_name):
				return _fail("iptables: Invalid argument. Run `dmesg' for more information.")
			nf.tables[table][chain_name] = {"policy": "", "rules": [], "pkts": 0, "bytes": 0}
			return 0
		"delete-chain":
			var names: Array = [chain_name] if not chain_name.is_empty() else nf.tables[table].keys().filter(func(c: String) -> bool: return not nf.is_builtin(table, c))
			for c: String in names:
				if nf.is_builtin(table, c):
					return _fail("iptables: Invalid argument. Run `dmesg' for more information.")
				if nf.references(table, c) > 0:
					return _fail("iptables: Too many links.")
				if not nf.tables[table][c].rules.is_empty():
					return _fail("iptables: Directory not empty.")
				nf.tables[table].erase(c)
			return 0
		"rename":
			if extra.is_empty():
				return _bad_arg("-E requires old-chain-name and new-chain-name")
			if nf.is_builtin(table, chain_name):
				return _fail("iptables: Invalid argument. Run `dmesg' for more information.")
			if nf.tables[table].has(extra[0]):
				return _fail("iptables: File exists.")
			nf.tables[table][extra[0]] = nf.tables[table][chain_name]
			nf.tables[table].erase(chain_name)
			for c: String in nf.tables[table]:
				for r: Dictionary in nf.tables[table][c].rules:
					if r.target == chain_name:
						r.target = extra[0]
			return 0
		"policy":
			if not nf.is_builtin(table, chain_name):
				return _fail("iptables: Bad built-in chain name.")
			if extra.is_empty() or not extra[0] in ["ACCEPT", "DROP"]:
				return _fail("iptables: Bad policy name. Run `dmesg' for more information.")
			nf.tables[table][chain_name].policy = extra[0]
			return 0
	# Commands with a rule.
	if chain_name.is_empty():
		return _bad_arg("-%s requires a chain name" % command[0].to_upper())
	var rules: Array = nf.tables[table][chain_name].rules
	var num := -1
	if not extra.is_empty():
		if not extra[0].is_valid_int() or int(extra[0]) < 1:
			return _bad_arg("Invalid rule number `%s'" % extra[0])
		num = int(extra[0])
	if command == "delete" and num > 0 and spec.is_empty():
		if num > rules.size():
			return _fail("iptables: Index of deletion too big.")
		rules.remove_at(num - 1)
		return 0
	var parsed: Variant = _parse_rule(spec, table)
	if parsed is int:
		return parsed
	var rule: Dictionary = parsed
	match command:
		"append":
			rules.append(rule)
		"insert":
			if num > rules.size() + 1:
				return _fail("iptables: Index of insertion too big.")
			rules.insert(maxi(0, num - 1) if num > 0 else 0, rule)
		"replace":
			if num < 1 or num > rules.size():
				return _fail("iptables: Index of replacement too big.")
			rules[num - 1] = rule
		"delete":
			for k in rules.size():
				if _same(rules[k], rule):
					rules.remove_at(k)
					return 0
			return _fail("iptables: Bad rule (does a matching rule exist in that chain?).")
	return 0


func _zero(c: Dictionary) -> void:
	c.pkts = 0
	c.bytes = 0
	for r: Dictionary in c.rules:
		r.pkts = 0
		r.bytes = 0


static func _same(a: Dictionary, b: Dictionary) -> bool:
	for k: String in a:
		if k in ["pkts", "bytes"]:
			continue
		if not b.has(k) or str(a[k]) != str(b[k]):
			return false
	return true


# --- parsing --------------------------------------------------------------------

static func new_rule() -> Dictionary:
	return {
		"proto": "", "proto_inv": false, "src": [], "src_inv": false, "dst": [], "dst_inv": false,
		"in": "", "in_inv": false, "out": "", "out_inv": false, "sport": [], "sport_inv": false,
		"dport": [], "dport_inv": false, "icmp_type": -1, "icmp_code": -1, "states": [],
		"state_match": "", "comment": "", "target": "", "target_opts": {}, "pkts": 0, "bytes": 0,
	}


func _parse_rule(spec: PackedStringArray, table: String) -> Variant:
	var r := new_rule()
	var matches: PackedStringArray = []
	var inv := false
	var i := 0
	while i < spec.size():
		var a := spec[i]
		if a == "!":
			inv = true
			i += 1
			continue
		var v := spec[i + 1] if i + 1 < spec.size() else ""
		if v.is_empty():
			return _bad_arg("option \"%s\" requires an argument" % a)
		match a:
			"-p", "--protocol":
				var name := v.to_lower()
				if PROTOS.has(name):
					r.proto = PROTOS[name] if name != "all" else ""
				elif v.is_valid_int():
					r.proto = int(v) if int(v) != 0 else ""
				else:
					return _bad_arg("unknown protocol \"%s\" specified" % v)
				r.proto_inv = inv
			"-s", "--source", "--src", "-d", "--destination", "--dst":
				var cidr := AgoraInet.parse_cidr(v)
				if cidr.is_empty():
					var host := AgoraResolver.lookup(p, v)
					if host < 0:
						return _bad_arg("host/network `%s' not found" % v)
					cidr = [host, 32]
				var key := "src" if a in ["-s", "--source", "--src"] else "dst"
				r[key] = [AgoraInet.network(cidr[0], cidr[1]), cidr[1]]
				r[key + "_inv"] = inv
			"-i", "--in-interface", "-o", "--out-interface":
				var key := "in" if a in ["-i", "--in-interface"] else "out"
				r[key] = v
				r[key + "_inv"] = inv
			"-m", "--match":
				if not v in ["state", "conntrack", "tcp", "udp", "icmp", "comment"]:
					return _fail("iptables %s: Couldn't load match `%s':No such file or directory\n\nTry `iptables -h' or 'iptables --help' for more information." % [VERSION, v], 2)
				matches.append(v)
			"--state", "--ctstate":
				var need := "state" if a == "--state" else "conntrack"
				if not matches.has(need):
					return _bad_arg("unknown option \"%s\"" % a)
				var states: Array = []
				for s in v.split(","):
					if not STATES.has(s.to_upper()):
						return _bad_arg("Bad %s \"%s\"" % ["state" if need == "state" else "ctstate", s])
					states.append(s.to_upper())
				r.states = states
				r.state_match = need
			"--sport", "--source-port", "--dport", "--destination-port":
				if not r.proto in [6, 17]:
					return _bad_arg("unknown option \"%s\"" % a)
				var range_ := _port_range(v)
				if range_.is_empty():
					return _bad_arg("invalid port/service `%s' specified" % v)
				var key := "sport" if a in ["--sport", "--source-port"] else "dport"
				r[key] = range_
				r[key + "_inv"] = inv
			"--icmp-type":
				if r.proto != 1:
					return _bad_arg("unknown option \"--icmp-type\"")
				var tc := _icmp_type(v)
				if tc.is_empty():
					return _bad_arg("Invalid ICMP type `%s'" % v)
				r.icmp_type = tc[0]
				r.icmp_code = tc[1]
			"--comment":
				if not matches.has("comment"):
					return _bad_arg("unknown option \"--comment\"")
				r.comment = v
			"-j", "--jump":
				r.target = v
			"--reject-with":
				if r.target != "REJECT":
					return _bad_arg("unknown option \"--reject-with\"")
				var with := v if v.begins_with("icmp-") or v == "tcp-reset" else "icmp-" + v
				if not AgoraNetfilter.REJECT_CODES.has(with) and with != "tcp-reset":
					return _bad_arg("unknown reject type \"%s\"" % v)
				r.target_opts.with = with
			"--to-source", "--to-destination", "--to":
				var to := _nat_to(v, r.target == "SNAT")
				if to.is_empty():
					return _bad_arg("Bad IP address \"%s\"" % v)
				r.target_opts.to = to
			"--to-ports":
				var range_ := _port_range(v.replace("-", ":"))
				if range_.is_empty():
					return _bad_arg("Port `%s' not valid" % v)
				r.target_opts.ports = range_
			"--log-prefix":
				r.target_opts.prefix = v
			"--log-level":
				r.target_opts.level = v
			_:
				return _bad_arg("unknown option \"%s\"" % a)
		inv = false
		i += 2
	var target: String = r.target
	if target.is_empty():
		return r
	if not AgoraNetfilter.VERDICTS.has(target) and nf.chain(table, target).is_empty():
		return _fail("iptables %s: Couldn't load target `%s':No such file or directory\n\nTry `iptables -h' or 'iptables --help' for more information." % [VERSION, target], 2)
	if target in ["MASQUERADE", "SNAT", "DNAT"] and table != "nat":
		p.machine.klog("x_tables: ip_tables: %s target: only valid in nat table, not %s" % [target, table])
		return _fail("iptables: Invalid argument. Run `dmesg' for more information.")
	if target in ["SNAT", "DNAT"] and not r.target_opts.has("to"):
		return _bad_arg("You must specify --to-%s" % ("source" if target == "SNAT" else "destination"))
	if target == "REJECT" and table != "filter":
		p.machine.klog("x_tables: ip_tables: REJECT target: only valid in filter table, not %s" % table)
		return _fail("iptables: Invalid argument. Run `dmesg' for more information.")
	return r


func _port_range(v: String) -> Array:
	var parts := v.split(":")
	var lo := _port(parts[0]) if not parts[0].is_empty() else 0
	var hi := lo if parts.size() == 1 else (_port(parts[1]) if not parts[1].is_empty() else 65535)
	if lo < 0 or hi < 0 or lo > hi:
		return []
	return [lo, hi]


static func _port(v: String) -> int:
	if v.is_valid_int():
		return int(v) if int(v) >= 0 and int(v) <= 65535 else -1
	var n: Variant = SERVICES.find_key(v)
	return n if n != null else -1


static func _icmp_type(v: String) -> Array:
	if ICMP_TYPES.has(v):
		return ICMP_TYPES[v]
	var parts := v.split("/")
	if parts[0].is_valid_int():
		return [int(parts[0]), int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else -1]
	return []


## "1.2.3.4", "1.2.3.4:80" or "1.2.3.4:1024-2000" -> [address, low, high].
static func _nat_to(v: String, ranges: bool) -> Array:
	var addr := AgoraInet.parse(v.get_slice(":", 0))
	if addr < 0:
		return []
	if not v.contains(":"):
		return [addr, 0, 0]
	var ports := v.get_slice(":", 1).split("-")
	if not ports[0].is_valid_int():
		return []
	var lo := int(ports[0])
	var hi := int(ports[1]) if ports.size() > 1 and ports[1].is_valid_int() else lo
	return [addr, lo, hi] if ranges else [addr, lo]


# --- listing --------------------------------------------------------------------

func _chains(table: String) -> PackedStringArray:
	var out := PackedStringArray(AgoraNetfilter.BUILTIN[table])
	for c: String in nf.tables[table]:
		if not out.has(c):
			out.append(c)
	return out


func _num(n: int) -> String:
	if _exact or n < 100000:
		return str(n)
	for unit: Array in [[1000000000000, "T"], [1000000000, "G"], [1000000, "M"], [1000, "K"]]:
		if n >= int(unit[0]) * 100:
			return "%d%s" % [n / int(unit[0]), unit[1]]
	return "%dK" % (n / 1000)


func _list(table: String, only: String) -> int:
	var first := true
	for c in _chains(table):
		if not only.is_empty() and c != only:
			continue
		var ch: Dictionary = nf.tables[table][c]
		if not first:
			p.outln("")
		first = false
		if ch.policy.is_empty():
			p.outln("Chain %s (%d references)" % [c, nf.references(table, c)])
		elif _verbose:
			p.outln("Chain %s (policy %s %s packets, %s bytes)" % [c, ch.policy, _num(ch.pkts), _num(ch.bytes)])
		else:
			p.outln("Chain %s (policy %s)" % [c, ch.policy])
		var head := "num  " if _line_numbers else ""
		if _verbose:
			head += ("%8s %10s " % ["pkts", "bytes"]) if _exact else ("%5s %5s " % ["pkts", "bytes"])
			head += "target     prot opt in     out     source               destination         "
		else:
			head += "target     prot opt source               destination         "
		p.outln(head)
		var n := 0
		for r: Dictionary in ch.rules:
			n += 1
			p.outln(("%-4d " % n if _line_numbers else "") + _rule_line(r))
	return 0


func _addr_text(a: Array) -> String:
	if a.is_empty():
		return "0.0.0.0/0" if _numeric else "anywhere"
	if a[1] == 32:
		if not _numeric:
			var name := AgoraResolver.reverse(p, a[0])
			if not name.is_empty():
				return name
		return AgoraInet.to_str(a[0])
	return "%s/%d" % [AgoraInet.to_str(a[0]), a[1]]


func _proto_text(r: Dictionary) -> String:
	if r.proto is String:
		return "all"
	var name: Variant = PROTOS.find_key(r.proto)
	return name if name != null else str(r.proto)


func _port_text(range_: Array) -> String:
	if range_[0] == range_[1]:
		return str(range_[0]) if _numeric or not SERVICES.has(range_[0]) else SERVICES[range_[0]]
	return "%d:%d" % range_


func _rule_line(r: Dictionary) -> String:
	var text := ""
	if _verbose:
		text += ("%8s %10s " if _exact else "%5s %5s ") % [_num(r.pkts), _num(r.bytes)]
	var target: String = r.target
	text += "%-9s " % target + ("!" if r.proto_inv else " ") + "%-5s" % _proto_text(r) + "-- "
	if _verbose:
		var in_text: String = ("!" if r.in_inv else "") + (r.in if not r.in.is_empty() else "*")
		var out_text: String = ("!" if r.out_inv else "") + (r.out if not r.out.is_empty() else "*")
		text += " %-6s %-6s " % [in_text, out_text]
	text += ("!" if r.src_inv else " ") + "%-19s " % _addr_text(r.src)
	text += ("!" if r.dst_inv else " ") + "%-19s " % _addr_text(r.dst)
	var extras: PackedStringArray = []
	var proto_name := _proto_text(r)
	for which in ["sport", "dport"]:
		var range_: Array = r[which]
		if not range_.is_empty():
			var label: String = ("spt" if which == "sport" else "dpt") + ("s" if range_[0] != range_[1] else "")
			extras.append("%s %s:%s%s" % [proto_name, label, "!" if r[which + "_inv"] else "", _port_text(range_)])
	if r.icmp_type >= 0:
		if _numeric or ICMP_TYPES.find_key([r.icmp_type, r.icmp_code]) == null:
			extras.append("icmptype %d%s" % [r.icmp_type, " code %d" % r.icmp_code if r.icmp_code >= 0 else ""])
		else:
			extras.append("icmp " + ICMP_TYPES.find_key([r.icmp_type, r.icmp_code]))
	if not r.states.is_empty():
		extras.append("%s %s" % ["state" if r.state_match == "state" else "ctstate", ",".join(_ordered_states(r.states))])
	if not r.comment.is_empty():
		extras.append("/* %s */" % r.comment)
	var o: Dictionary = r.target_opts
	match target:
		"REJECT": extras.append("reject-with " + o.get("with", "icmp-port-unreachable"))
		"SNAT", "DNAT":
			var to: Array = o.to
			var ports := ""
			if to.size() > 1 and to[1] > 0:
				ports = ":%d" % to[1] if to.size() < 3 or to[1] == to[2] else ":%d-%d" % [to[1], to[2]]
			extras.append("to:%s%s" % [AgoraInet.to_str(to[0]), ports])
		"MASQUERADE":
			if o.has("ports"):
				extras.append("masq ports: %d-%d" % o.ports)
		"LOG":
			extras.append("LOG flags 0 level %s%s" % [o.get("level", "4"), " prefix \"%s\"" % o.prefix if o.has("prefix") else ""])
	if not extras.is_empty():
		text += " " + " ".join(extras)
	return text


static func _ordered_states(states: Array) -> PackedStringArray:
	var out: PackedStringArray = []
	for s in STATES:
		if states.has(s):
			out.append(s)
	return out


## A rule as iptables -S and iptables-save write it.
func _rule_spec(chain_name: String, r: Dictionary) -> String:
	var parts: PackedStringArray = ["-A", chain_name]
	for pair: Array in [["src", "-s"], ["dst", "-d"]]:
		var a: Array = r[pair[0]]
		if not a.is_empty():
			if r[pair[0] + "_inv"]:
				parts.append("!")
			parts.append_array([pair[1], "%s/%d" % [AgoraInet.to_str(a[0]), a[1]]])
	for pair: Array in [["in", "-i"], ["out", "-o"]]:
		if not (r[pair[0]] as String).is_empty():
			if r[pair[0] + "_inv"]:
				parts.append("!")
			parts.append_array([pair[1], r[pair[0]]])
	if r.proto is int:
		if r.proto_inv:
			parts.append("!")
		parts.append_array(["-p", _proto_text(r)])
	if r.proto is int and (not r.sport.is_empty() or not r.dport.is_empty()):
		parts.append_array(["-m", _proto_text(r)])
		for pair: Array in [["sport", "--sport"], ["dport", "--dport"]]:
			var range_: Array = r[pair[0]]
			if not range_.is_empty():
				if r[pair[0] + "_inv"]:
					parts.append("!")
				parts.append_array([pair[1], str(range_[0]) if range_[0] == range_[1] else "%d:%d" % range_])
	if r.icmp_type >= 0:
		parts.append_array(["-m", "icmp", "--icmp-type", str(r.icmp_type) + ("/%d" % r.icmp_code if r.icmp_code >= 0 else "")])
	if not r.states.is_empty():
		var opt := "--state" if r.state_match == "state" else "--ctstate"
		parts.append_array(["-m", r.state_match, opt, ",".join(_ordered_states(r.states))])
	if not r.comment.is_empty():
		parts.append_array(["-m", "comment", "--comment", "\"%s\"" % r.comment])
	if not (r.target as String).is_empty():
		parts.append_array(["-j", r.target])
		var o: Dictionary = r.target_opts
		match r.target:
			"REJECT": parts.append_array(["--reject-with", o.get("with", "icmp-port-unreachable")])
			"SNAT", "DNAT":
				var to: Array = o.to
				var text := AgoraInet.to_str(to[0])
				if to.size() > 1 and to[1] > 0:
					text += ":%d" % to[1] if to.size() < 3 or to[1] == to[2] else ":%d-%d" % [to[1], to[2]]
				parts.append_array(["--to-source" if r.target == "SNAT" else "--to-destination", text])
			"MASQUERADE":
				if o.has("ports"):
					parts.append_array(["--to-ports", "%d-%d" % o.ports])
			"LOG":
				if o.has("prefix"):
					parts.append_array(["--log-prefix", "\"%s\"" % o.prefix])
	return " ".join(parts)


func _list_rules(table: String, only: String) -> int:
	for c in _chains(table):
		if not only.is_empty() and c != only:
			continue
		var ch: Dictionary = nf.tables[table][c]
		p.outln("-P %s %s" % [c, ch.policy] if not ch.policy.is_empty() else "-N " + c)
	for c in _chains(table):
		if not only.is_empty() and c != only:
			continue
		for r: Dictionary in nf.tables[table][c].rules:
			p.outln(_rule_spec(c, r))
	return 0


# --- save and restore ---------------------------------------------------------------

func _save() -> int:
	if not p.cred.is_root():
		return _check_table("filter", true)
	var when := p.machine.clock.format_long()
	for table in ["nat", "filter"]:
		p.outln("# Generated by iptables-save %s on %s" % [VERSION.get_slice(" ", 0), when])
		p.outln("*" + table)
		for c in _chains(table):
			var ch: Dictionary = nf.tables[table][c]
			p.outln(":%s %s [%d:%d]" % [c, ch.policy if not ch.policy.is_empty() else "-", ch.pkts, ch.bytes])
		for c in _chains(table):
			for r: Dictionary in nf.tables[table][c].rules:
				p.outln(_rule_spec(c, r))
		p.outln("COMMIT")
		p.outln("# Completed on %s" % when)
	return 0


func _restore() -> int:
	if not p.cred.is_root():
		return _check_table("filter", true)
	var text := ""
	var args := p.argv.slice(1)
	if not args.is_empty() and not args[-1].begins_with("-"):
		text = p.read_text(args[-1])
	else:
		while true:
			var line: Variant = await p.read_line()
			if line == null:
				break
			text += str(line) + "\n"
	var table := ""
	var n := 0
	for raw in text.split("\n"):
		n += 1
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("*"):
			table = line.substr(1)
			if not nf.tables.has(table):
				return _fail("iptables-restore: line %d failed" % n)
			for c: String in nf.tables[table].keys():
				if nf.is_builtin(table, c):
					nf.tables[table][c].rules.clear()
				else:
					nf.tables[table].erase(c)
			continue
		if line == "COMMIT":
			table = ""
			continue
		if line.begins_with(":"):
			var words := line.substr(1).split(" ", false)
			if nf.is_builtin(table, words[0]):
				if words.size() > 1 and words[1] in ["ACCEPT", "DROP"]:
					nf.tables[table][words[0]].policy = words[1]
			else:
				nf.tables[table][words[0]] = {"policy": "", "rules": [], "pkts": 0, "bytes": 0}
			continue
		var words := _split_quoted(line)
		words.insert(0, "-t")
		words.insert(1, table)
		if _command(words, false) != 0:
			return _fail("iptables-restore: line %d failed" % n)
	return 0


static func _split_quoted(line: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var word := ""
	var quoted := false
	for c in line:
		if c == "\"":
			quoted = not quoted
		elif c == " " and not quoted:
			if not word.is_empty():
				out.append(word)
			word = ""
		else:
			word += c
	if not word.is_empty():
		out.append(word)
	return out
