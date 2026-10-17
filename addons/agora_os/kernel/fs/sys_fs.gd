class_name AgoraSysFs
extends AgoraFs
## Read-only view of the hardware, mounted at /sys:
##   /sys/class/net/<dev>/{address,broadcast,carrier,flags,ifindex,mtu,
##       operstate,speed,tx_queue_len,type,statistics/*}
##   /sys/block/<disk>/{size,removable,ro,model}
##   /sys/class/dmi/id/{sys_vendor,product_name}

var _machine: WeakRef


func _init(machine: Object) -> void:
	_machine = weakref(machine)
	read_only = true


func fs_type() -> String:
	return "sysfs"


const NET_FILES: PackedStringArray = [
	"address", "broadcast", "carrier", "flags", "ifindex", "mtu", "operstate",
	"speed", "statistics", "tx_queue_len", "type",
]
const NET_STATS: PackedStringArray = [
	"rx_bytes", "rx_dropped", "rx_errors", "rx_packets",
	"tx_bytes", "tx_dropped", "tx_errors", "tx_packets",
]


func _hw() -> AgoraHardware:
	var m := _machine.get_ref() as AgoraMachine
	return m.hardware if m else null


func _iface(name: String) -> AgoraNetStack.Iface:
	var m := _machine.get_ref() as AgoraMachine
	return m.net.iface(name) if m and m.net else null


## Directory tree as nested names; leaves are file names.
func _children(rel: String) -> PackedStringArray:
	var hw := _hw()
	var parts := rel.split("/", false)
	match parts.size():
		0: return ["block", "class"]
		1:
			if parts[0] == "class":
				return ["dmi", "net"]
			if parts[0] == "block":
				var out: PackedStringArray = []
				for d in hw.disks:
					out.append(hw.device_name(d))
				return out
		2:
			if parts[0] == "class" and parts[1] == "net":
				var m := _machine.get_ref() as AgoraMachine
				var out: PackedStringArray = []
				if m and m.net:
					for i in m.net.interfaces:
						out.append(i.name)
				return out
			if parts[0] == "class" and parts[1] == "dmi":
				return ["id"]
			if parts[0] == "block" and hw.find_device(parts[1]):
				return ["model", "removable", "ro", "size"]
		3:
			if parts[1] == "net" and _iface(parts[2]):
				return NET_FILES
			if parts[1] == "dmi" and parts[2] == "id":
				return ["product_name", "sys_vendor"]
		4:
			if parts[1] == "net" and parts[3] == "statistics" and _iface(parts[2]):
				return NET_STATS
	return []


func _content(rel: String) -> Variant:
	var hw := _hw()
	var parts := rel.split("/", false)
	if parts.size() == 3 and parts[0] == "block":
		var d := hw.find_device(parts[1])
		if d:
			match parts[2]:
				"size": return str(d.capacity_mb * 2048) # 512-byte sectors
				"removable": return "1" if d.removable else "0"
				"ro": return "1" if d.read_only else "0"
				"model": return d.model
	if parts.size() >= 4 and parts[1] == "net":
		var i := _iface(parts[2])
		if i and parts.size() == 5 and parts[3] == "statistics":
			return str(i.stats.get(parts[4])) if NET_STATS.has(parts[4]) else null
		if i and parts.size() == 4:
			match parts[3]:
				"address": return i.mac
				"broadcast": return "00:00:00:00:00:00" if i.is_loopback() else "ff:ff:ff:ff:ff:ff"
				"carrier": return "1" if i.carrier else "0"
				"flags": return "0x%x" % i.flags()
				"ifindex": return str(i.index)
				"mtu": return str(i.mtu)
				"operstate": return i.operstate()
				"speed": return str(i.nic.speed_mbps) if i.nic and i.carrier else "-1"
				"tx_queue_len": return str(i.tx_queue_len)
				"type": return str(AgoraNetStack.ARPHRD_LOOPBACK if i.is_loopback() else AgoraNetStack.ARPHRD_ETHER)
	if parts.size() == 4 and parts[1] == "dmi":
		match parts[3]:
			"sys_vendor": return hw.vendor
			"product_name": return hw.model
	return null


func lstat(rel: String) -> AgoraStat:
	var s := AgoraStat.new()
	s.mtime = 0
	if _content(rel) != null:
		s.mode = 292 # 0o444
		s.size = read_file(rel).size()
		return s
	if rel.is_empty() or not _children(rel).is_empty():
		s.type = AgoraStat.Type.DIR
		s.mode = 365 # 0o555
		return s
	return null


func list_dir(rel: String) -> PackedStringArray:
	return _children(rel)


func read_file(rel: String) -> PackedByteArray:
	var c: Variant = _content(rel)
	return (str(c) + "\n").to_utf8_buffer() if c != null else PackedByteArray()
