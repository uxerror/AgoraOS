class_name AgoraProcFs
extends AgoraFs
## Read-only view of kernel state, mounted at /proc. Tools like ps read these
## files instead of calling into the kernel, as on Linux.

const PID_FILES: PackedStringArray = ["cmdline", "cwd", "environ", "status"]
const TOP_FILES: PackedStringArray = ["cpuinfo", "kmsg", "meminfo", "mounts", "uptime", "version"]
const NET_FILES: PackedStringArray = ["arp", "dev", "nf_conntrack", "route", "tcp", "udp"]
## Writable kernel settings under /proc/sys: path -> [min, max].
const SYSCTLS := {
	"net/ipv4/icmp_echo_ignore_all": [0, 1],
	"net/ipv4/icmp_echo_ignore_broadcasts": [0, 1],
	"net/ipv4/ip_default_ttl": [1, 255],
	"net/ipv4/ip_forward": [0, 1],
	"net/ipv4/tcp_retries2": [1, 255],
	"net/ipv4/tcp_syn_retries": [1, 127],
}

var _machine: WeakRef


func _init(machine: Object) -> void:
	_machine = weakref(machine)


func fs_type() -> String:
	return "proc"


func _m() -> AgoraMachine:
	return _machine.get_ref() as AgoraMachine


func _proc(name: String) -> AgoraProcess:
	if not name.is_valid_int():
		return null
	return _m().get_process(int(name))


func lstat(rel: String) -> AgoraStat:
	var parts := rel.split("/", false)
	var s := AgoraStat.new()
	s.mode = 292 # 0o444
	s.mtime = int(_m().clock.now())
	if parts.is_empty():
		s.type = AgoraStat.Type.DIR
		s.mode = 365 # 0o555
		return s
	if parts.size() == 1 and TOP_FILES.has(parts[0]):
		s.size = read_file(rel).size()
		return s
	if parts[0] == "sys" and _m().net:
		var rel_sys := "/".join(parts.slice(1))
		if SYSCTLS.has(rel_sys):
			s.mode = 420 # 0o644
			s.size = read_file(rel).size()
			return s
		if parts.size() == 1 or not _sys_children(rel_sys).is_empty():
			s.type = AgoraStat.Type.DIR
			s.mode = 365
			return s
		return null
	if parts[0] == "net" and _m().net:
		if parts.size() == 1:
			s.type = AgoraStat.Type.DIR
			s.mode = 365
			return s
		if parts.size() == 2 and NET_FILES.has(parts[1]):
			s.size = read_file(rel).size()
			return s
		return null
	var p := _proc(parts[0])
	if p == null:
		return null
	s.uid = p.cred.uid
	s.gid = p.cred.gid
	if parts.size() == 1:
		s.type = AgoraStat.Type.DIR
		s.mode = 365
		return s
	if parts.size() == 2 and PID_FILES.has(parts[1]):
		if parts[1] == "cwd":
			s.type = AgoraStat.Type.SYMLINK
			s.mode = AgoraStat.MODE_SYMLINK
		elif parts[1] == "environ":
			s.mode = 256 # 0o400
		s.size = read_file(rel).size()
		return s
	return null


func list_dir(rel: String) -> PackedStringArray:
	if rel.is_empty():
		var out := TOP_FILES.duplicate()
		out.append("net")
		out.append("sys")
		for pid in _m().list_pids():
			out.append(str(pid))
		return out
	if rel == "net":
		return NET_FILES
	if rel == "sys" or rel.begins_with("sys/"):
		return _sys_children(rel.trim_prefix("sys").trim_prefix("/"))
	if _proc(rel) != null:
		return PID_FILES
	return []


func read_file(rel: String) -> PackedByteArray:
	var parts := rel.split("/", false)
	var m := _m()
	var text := ""
	if parts.size() == 1:
		match parts[0]:
			"uptime":
				text = "%.2f\n" % (m.clock.now() - m.boot_time)
			"kmsg":
				text = "\n".join(m.kmsg) + "\n"
			"version":
				text = "%s version %s\n" % [AgoraMachine.KERNEL_NAME, AgoraMachine.KERNEL_VERSION]
			"mounts":
				for point in m.vfs.mount_points():
					var fs := m.vfs.get_mount(point)
					text += "%s %s %s %s 0 0\n" % [m.vfs.get_source(point), point, fs.fs_type(), "ro" if fs.read_only else "rw"]
			"cpuinfo":
				var hw := m.hardware
				for i in hw.cpu_cores:
					text += "processor\t: %d\nvendor_id\t: %s\nmodel name\t: %s\ncpu MHz\t\t: %d.000\n\n" % [i, hw.vendor, hw.cpu_model, hw.cpu_mhz]
			"meminfo":
				var total := m.hardware.ram_mb * 1024
				var used := mini(total - 1024, total / 8 + m.list_pids().size() * 640)
				text = "MemTotal:\t%8d kB\nMemFree:\t%8d kB\nMemAvailable:\t%8d kB\n" % [total, total - used, total - used]
	elif parts[0] == "sys":
		var value: Variant = _sysctl(m.net, "/".join(parts.slice(1)))
		if value == null:
			return PackedByteArray()
		text = "%d\n" % value
	elif parts.size() == 2 and parts[0] == "net":
		match parts[1]:
			"arp": text = _net_arp(m.net)
			"dev": text = _net_dev(m.net)
			"route": text = _net_route(m.net)
			"udp": text = _net_udp(m.net)
			"tcp": text = _net_tcp(m.net)
			"nf_conntrack":
				for ct in m.net.netfilter.conntrack.list():
					text += AgoraConntrack.format(ct) + "\n"
	elif parts.size() == 2:
		var p := _proc(parts[0])
		if p == null:
			return PackedByteArray()
		match parts[1]:
			"cmdline":
				text = " ".join(p.argv) + "\n"
			"environ":
				for k in p.env:
					text += "%s=%s\n" % [k, p.env[k]]
			"status":
				text = "Name:\t%s\nState:\t%s\nPid:\t%d\nPPid:\t%d\nUid:\t%d\t%d\nGid:\t%d\nTty:\t%s\nStarted:\t%d\n" % [
					p.name, p.state_letter(), p.pid, p.ppid, p.cred.ruid, p.cred.uid, p.cred.gid,
					p.tty.name if p.tty else "?", int(p.start_time)]
	return text.to_utf8_buffer()


## /proc/net/arp: the neighbour table as net-tools arp(8) reads it.
static func _net_arp(net: AgoraNetStack) -> String:
	if net == null:
		return ""
	var text := "IP address       HW type     Flags       HW address            Mask     Device\n"
	for e in net.neigh.entries():
		var flags := 0
		if not e.mac.is_empty() and e.state != "FAILED" and e.state != "INCOMPLETE":
			flags |= 0x2 # ATF_COM
		if e.state == "PERMANENT":
			flags |= 0x4 # ATF_PERM
		var mac: String = e.mac if flags else AgoraNeighbours.ZERO_MAC
		text += "%-16s 0x%-10x0x%-10x%-17s     *        %s\n" % [AgoraInet.to_str(e.ip), 1, flags, mac, e.dev]
	return text


## /proc/net/tcp: TCP sockets, as netstat reads them.
static func _net_tcp(net: AgoraNetStack) -> String:
	if net == null:
		return ""
	var text := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
	var n := 0
	for s: Array in net.tcp.sockets():
		text += "%4d: %s:%04X %s:%04X %02X %08X:%08X 00:00000000 00000000 %5d        0 %d 1 0000000000000000 100 0 0 10 0\n" % [
			n, AgoraInet.to_le_hex(s[0]), s[1], AgoraInet.to_le_hex(s[2]), s[3], AgoraTcp.STATE_CODES[s[4]], s[6], s[7], s[5], 20000 + n]
		n += 1
	return text


## /proc/net/udp: open UDP sockets, as netstat reads them.
static func _net_udp(net: AgoraNetStack) -> String:
	if net == null:
		return ""
	var text := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode ref pointer drops\n"
	var n := 0
	for s in net.udp.sockets:
		text += "%5d: %s:%04X 00000000:0000 07 00000000:%08X 00:00000000 00000000 %5d        0 %d 2 0000000000000000 0\n" % [
			n, AgoraInet.to_le_hex(s.address), s.port, s.inbox.size(), s.uid, 10000 + s.port]
		n += 1
	return text


## /proc/net/dev: traffic counters per interface, in the kernel's layout.
static func _net_dev(net: AgoraNetStack) -> String:
	if net == null:
		return ""
	var text := "Inter-|   Receive                                                |  Transmit\n"
	text += " face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed\n"
	for i in net.interfaces:
		var st := i.stats
		text += "%6s: %7d %7d %4d %4d %4d %5d %10d %9d %8d %7d %4d %4d %4d %5d %7d %10d\n" % [
			i.name, st.rx_bytes, st.rx_packets, st.rx_errors, st.rx_dropped, 0, 0, 0, 0,
			st.tx_bytes, st.tx_packets, st.tx_errors, st.tx_dropped, 0, 0, 0, 0]
	return text


## /proc/net/route: the main table as net-tools route(8) reads it. Lines
## are padded to 127 columns like the kernel's.
static func _net_route(net: AgoraNetStack) -> String:
	if net == null:
		return ""
	var text := "%-127s\n" % "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT"
	for r in net.routes:
		var flags := 0x1 # RTF_UP
		if r.gateway != 0:
			flags |= 0x2 # RTF_GATEWAY
		if r.prefix == 32:
			flags |= 0x4 # RTF_HOST
		if r.type == "unreachable" or r.type == "prohibit":
			flags |= 0x200 # RTF_REJECT
		var line := "%s\t%s\t%s\t%04X\t%d\t%d\t%d\t%s\t%d\t%d\t%d" % [
			r.dev if r.type == "unicast" else "*", AgoraInet.to_le_hex(r.dst), AgoraInet.to_le_hex(r.gateway),
			flags, 0, 0, r.metric, AgoraInet.to_le_hex(AgoraInet.mask(r.prefix)), 0, 0, 0]
		text += "%-127s\n" % line
	return text


## Names directly under [param rel] in /proc/sys.
static func _sys_children(rel: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var prefix := rel + "/" if not rel.is_empty() else ""
	for path: String in SYSCTLS:
		if path.begins_with(prefix):
			var name := path.substr(prefix.length()).get_slice("/", 0)
			if not out.has(name):
				out.append(name)
	out.sort()
	return out


static func _sysctl(net: AgoraNetStack, path: String) -> Variant:
	if net == null:
		return null
	match path:
		"net/ipv4/ip_forward": return 1 if net.ip_forward else 0
		"net/ipv4/ip_default_ttl": return net.default_ttl
		"net/ipv4/icmp_echo_ignore_all": return 1 if net.icmp.echo_ignore_all else 0
		"net/ipv4/icmp_echo_ignore_broadcasts": return 1 if net.icmp.echo_ignore_broadcasts else 0
		"net/ipv4/tcp_syn_retries": return net.tcp.syn_retries
		"net/ipv4/tcp_retries2": return net.tcp.retries2
	return null


## Writing a number into /proc/sys changes the setting (EINVAL otherwise).
func write_file(rel: String, data: PackedByteArray, _append: bool, _mtime: int) -> int:
	var path := rel.trim_prefix("sys/")
	var net := _m().net
	if not rel.begins_with("sys/") or not SYSCTLS.has(path) or net == null:
		return AgoraErrno.EROFS if not rel.begins_with("sys/") else AgoraErrno.ENOENT
	var text := data.get_string_from_utf8().strip_edges()
	if text.is_empty():
		return AgoraErrno.OK # truncating on open, before the write
	if not text.is_valid_int():
		return AgoraErrno.EINVAL
	var v := int(text)
	var limits: Array = SYSCTLS[path]
	if v < limits[0] or v > limits[1]:
		return AgoraErrno.EINVAL
	match path:
		"net/ipv4/ip_forward": net.ip_forward = v == 1
		"net/ipv4/ip_default_ttl": net.default_ttl = v
		"net/ipv4/icmp_echo_ignore_all": net.icmp.echo_ignore_all = v == 1
		"net/ipv4/icmp_echo_ignore_broadcasts": net.icmp.echo_ignore_broadcasts = v == 1
		"net/ipv4/tcp_syn_retries": net.tcp.syn_retries = v
		"net/ipv4/tcp_retries2": net.tcp.retries2 = v
	return AgoraErrno.OK


func read_link(rel: String) -> String:
	var parts := rel.split("/", false)
	if parts.size() == 2 and parts[1] == "cwd":
		var p := _proc(parts[0])
		if p:
			return p.cwd
	return ""
