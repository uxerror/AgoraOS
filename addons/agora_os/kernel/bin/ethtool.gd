extends AgoraProgram
## ethtool 5.9: shows and changes what a network card's PHY and driver do.
##   ethtool DEV             link modes, speed, duplex, autonegotiation
##   ethtool -i DEV          driver information
##   ethtool -S DEV          the driver's statistics
##   ethtool -s DEV ...      speed, duplex, autoneg, advertise (root)
##   ethtool -r DEV          restart autonegotiation (root)
## Output follows the ioctl interface; what needs CAP_NET_ADMIN (wake-on-LAN
## settings, changes) fails for others with EPERM, as on Linux.

const VERSION := "5.9"
const DRIVERS := {
	"e100": {"version": "3.5.24-k2-NAPI", "firmware": "N/A", "port": "MII", "ports": "[ TP MII ]",
		"phyad": 1, "wol": ["g", "g"], "lp": true, "mdix": false},
	"e1000": {"version": "7.3.21-k8-NAPI", "firmware": "", "port": "Twisted Pair", "ports": "[ TP ]",
		"phyad": 0, "wol": ["umbg", "d"], "lp": false, "mdix": true},
	"b44": {"version": "2.0", "firmware": "", "port": "MII", "ports": "[ TP MII ]",
		"phyad": 30, "wol": ["g", "d"], "lp": true, "mdix": false},
	# An NE2000 clone: its driver answers ethtool -i and nothing else.
	"ne2k-pci": {"version": "1.03", "firmware": "", "mii": false},
}


## True for a card whose driver has only driver information for ethtool.
static func _no_mii(nic: AgoraNic) -> bool:
	return nic != null and not DRIVERS.get(nic.driver, {}).get("mii", true)
## The statistics each driver names for ethtool -S, mapped to the
## counters they come from ("" is always 0).
const E100_STATS := [
	"rx_packets", "tx_packets", "rx_bytes", "tx_bytes", "rx_errors", "tx_errors", "rx_dropped",
	"tx_dropped", "multicast", "collisions", "rx_length_errors", "rx_over_errors", "rx_crc_errors",
	"rx_frame_errors", "rx_fifo_errors", "rx_missed_errors", "tx_aborted_errors",
	"tx_carrier_errors", "tx_fifo_errors", "tx_heartbeat_errors", "tx_window_errors",
	["tx_deferred", "nic:tx_deferred"], ["tx_single_collisions", "nic:tx_single_collisions"],
	["tx_multi_collisions", "nic:tx_multi_collisions"], ["tx_flow_control_pause", ""],
	["rx_flow_control_pause", ""], ["rx_flow_control_unsupported", ""], ["tx_tco_packets", ""],
	["rx_tco_packets", ""], ["rx_short_frame_errors", "rx_length_errors"], ["rx_over_length_errors", ""],
]
const E1000_STATS := [
	"rx_packets", "tx_packets", "rx_bytes", "tx_bytes", ["rx_broadcast", ""], ["tx_broadcast", ""],
	["rx_multicast", "multicast"], ["tx_multicast", ""], "rx_errors", "tx_errors", "tx_dropped",
	"multicast", "collisions", "rx_length_errors", "rx_over_errors", "rx_crc_errors",
	"rx_frame_errors", ["rx_no_buffer_count", ""], "rx_missed_errors", "tx_aborted_errors",
	"tx_carrier_errors", "tx_fifo_errors", "tx_heartbeat_errors", "tx_window_errors",
	["tx_abort_late_coll", "nic:tx_late_collisions"], ["tx_deferred_ok", "nic:tx_deferred"],
	["tx_single_coll_ok", "nic:tx_single_collisions"], ["tx_multi_coll_ok", "nic:tx_multi_collisions"],
	["tx_timeout_count", ""], ["tx_restart_queue", ""], ["rx_long_length_errors", ""],
	["rx_short_length_errors", "rx_length_errors"], ["rx_align_errors", ""], ["tx_tcp_seg_good", ""],
	["tx_tcp_seg_failed", ""], ["rx_flow_control_xon", ""], ["rx_flow_control_xoff", ""],
	["tx_flow_control_xon", ""], ["tx_flow_control_xoff", ""], ["rx_long_byte_count", "rx_bytes"],
	["rx_csum_offload_good", ""], ["rx_csum_offload_errors", ""], ["alloc_rx_buff_failed", ""],
	["tx_smbus", ""], ["rx_smbus", ""], ["dropped_smbus", ""],
]

var _p: AgoraProcess


func summary() -> String:
	return "query or control network driver and hardware settings"


func usage() -> String:
	return """ethtool version %s
Usage:
        ethtool [ FLAGS ] DEVNAME	Display standard information about device
        ethtool [ FLAGS ] -s|--change DEVNAME	Change generic options
		[ speed %%d ]
		[ duplex half|full ]
		[ autoneg on|off ]
		[ advertise %%x[/%%x] | mode on|off ... [--] ]
        ethtool [ FLAGS ] -r|--negotiate DEVNAME	Restart N-WAY negotiation
        ethtool [ FLAGS ] -i|--driver DEVNAME	Show driver information
        ethtool [ FLAGS ] -S|--statistics DEVNAME	Show adapter statistics
        ethtool -h|--help 		Show this help
        ethtool --version 		Show version number""" % VERSION


func main(p: AgoraProcess) -> int:
	_p = p
	var args := p.argv.slice(1)
	if args.is_empty():
		return _bad_args()
	match args[0]:
		"-h", "--help":
			p.outln(usage())
			return 0
		"--version":
			p.outln("ethtool version %s" % VERSION)
			return 0
		"-i", "--driver":
			return _driver(args.slice(1)) if args.size() == 2 else _bad_args()
		"-S", "--statistics":
			return _statistics(args.slice(1)) if args.size() == 2 else _bad_args()
		"-s", "--change":
			return _change(args.slice(1)) if args.size() >= 2 else _bad_args()
		"-r", "--negotiate":
			return _restart(args.slice(1)) if args.size() == 2 else _bad_args()
	if args.size() != 1 or args[0].begins_with("-"):
		return _bad_args()
	return _settings(args[0])


func _bad_args() -> int:
	_p.errln("ethtool: bad command line argument(s)")
	_p.errln("For more information run ethtool -h")
	return 1


func _iface(name: String) -> AgoraNetStack.Iface:
	return _p.machine.net.iface(name) if _p.machine.net else null


# --- ethtool DEV -------------------------------------------------------------

func _settings(name: String) -> int:
	var i := _iface(name)
	var root := _p.cred.is_root()
	_p.outln("Settings for %s:" % name)
	if i == null:
		for what in ["device settings", "wake-on-lan settings", "message level", "link status"]:
			_p.errln("Cannot get %s: No such device" % what)
		_p.errln("No data available")
		return 75
	var nic := i.nic
	if _no_mii(nic):
		for what in ["device settings", "wake-on-lan settings", "message level", "link status"]:
			_p.errln("Cannot get %s: Operation not supported" % what)
		_p.errln("No data available")
		return 75
	if nic:
		var d: Dictionary = DRIVERS.get(nic.driver, DRIVERS.e100)
		_p.outln("\tSupported ports: %s" % d.ports)
		_modes("Supported link modes:   ", nic.supported_mask())
		_p.outln("\tSupported pause frame use: No")
		_p.outln("\tSupports auto-negotiation: Yes")
		_p.outln("\tSupported FEC modes: Not reported")
		_modes("Advertised link modes:  ", nic.advertising)
		_p.outln("\tAdvertised pause frame use: No")
		_p.outln("\tAdvertised auto-negotiation: %s" % ("Yes" if nic.autoneg else "No"))
		_p.outln("\tAdvertised FEC modes: Not reported")
		var partner := nic.peer
		if d.lp and nic.carrier and nic.cable.negotiated(nic) and partner:
			_modes("Link partner advertised link modes:  ", partner.advertising)
			_p.outln("\tLink partner advertised pause frame use: No")
			_p.outln("\tLink partner advertised auto-negotiation: Yes")
			_p.outln("\tLink partner advertised FEC modes: Not reported")
		if nic.carrier:
			_p.outln("\tSpeed: %dMb/s" % nic.link_speed)
			_p.outln("\tDuplex: %s" % nic.duplex.capitalize())
		else:
			_p.outln("\tSpeed: Unknown!")
			_p.outln("\tDuplex: Unknown! (255)")
		_p.outln("\tPort: %s" % d.port)
		_p.outln("\tPHYAD: %d" % d.phyad)
		_p.outln("\tTransceiver: internal")
		_p.outln("\tAuto-negotiation: %s" % ("on" if nic.autoneg else "off"))
		if d.mdix:
			var mdix := "off" if nic.carrier else "Unknown"
			_p.outln("\tMDI-X: %s" % (mdix + " (auto)" if nic.autoneg else mdix))
		if root:
			_p.outln("\tSupports Wake-on: %s" % d.wol[0])
			_p.outln("\tWake-on: %s" % d.wol[1])
		else:
			_p.errln("Cannot get wake-on-lan settings: Operation not permitted")
		_p.outln("\tCurrent message level: 0x00000007 (7)")
		_p.outln("\t\t\t       drv probe link")
	elif not root:
		_p.errln("Cannot get wake-on-lan settings: Operation not permitted")
	_p.outln("\tLink detected: %s" % ("yes" if i.admin_up and i.carrier else "no"))
	return 0


## Prints link modes in [param mask] the way ethtool groups them: the
## half and full duplex modes of one speed share a line.
func _modes(label: String, mask: int) -> void:
	var lines: PackedStringArray = []
	var line := ""
	var speed := 0
	for mode: Array in AgoraNic.MODES:
		if not mask & mode[3]:
			continue
		if not line.is_empty() and mode[1] != speed:
			lines.append(line)
			line = ""
		line += mode[0] + " "
		speed = mode[1]
	if not line.is_empty():
		lines.append(line)
	if lines.is_empty():
		lines.append("Not reported")
	_p.outln("\t" + label + lines[0])
	for k in range(1, lines.size()):
		_p.outln("\t" + " ".repeat(label.length()) + lines[k])


# --- -i, -S --------------------------------------------------------------------

func _driver(args: PackedStringArray) -> int:
	var i := _iface(args[0])
	if i == null:
		_p.errln("Cannot get driver information: No such device")
		return 71
	if i.is_loopback():
		_p.errln("Cannot get driver information: Operation not supported")
		return 71
	var info := {"driver": "bridge", "version": "2.3", "firmware": "N/A", "bus": "N/A", "stats": "no",
		"test": "no", "eeprom": "no", "regs": "no"}
	if i.nic:
		var d: Dictionary = DRIVERS.get(i.nic.driver, DRIVERS.e100)
		var y := "no" if _no_mii(i.nic) else "yes"
		info = {"driver": i.nic.driver, "version": d.version, "firmware": d.firmware, "bus": i.nic.bus_info,
			"stats": y, "test": y, "eeprom": y, "regs": y}
	_p.outln("driver: %s" % info.driver)
	_p.outln("version: %s" % info.version)
	_p.outln("firmware-version: %s" % info.firmware)
	_p.outln("expansion-rom-version: ")
	_p.outln("bus-info: %s" % info.bus)
	_p.outln("supports-statistics: %s" % info.stats)
	_p.outln("supports-test: %s" % info.test)
	_p.outln("supports-eeprom-access: %s" % info.eeprom)
	_p.outln("supports-register-dump: %s" % info.regs)
	_p.outln("supports-priv-flags: no")
	return 0


func _statistics(args: PackedStringArray) -> int:
	var i := _iface(args[0])
	if i == null:
		_p.errln("Cannot get stats strings information: No such device")
		return 96
	if i.nic == null or _no_mii(i.nic):
		_p.errln("no stats available")
		return 94
	var names: Array = E1000_STATS if i.nic.driver == "e1000" else E100_STATS
	_p.outln("NIC statistics:")
	for entry: Variant in names:
		var label: String = entry if entry is String else entry[0]
		var source: String = entry if entry is String else entry[1]
		var value := 0
		if source.begins_with("nic:"):
			value = int(i.nic.counters.get(source.trim_prefix("nic:"), 0))
		elif not source.is_empty():
			value = int(i.stats.get(source, 0))
		_p.outln("     %s: %d" % [label, value])
	return 0


# --- -s, -r --------------------------------------------------------------------

func _change(args: PackedStringArray) -> int:
	var name := args[0]
	var want := {}
	var k := 1
	while k < args.size():
		if k + 1 >= args.size():
			return _bad_args()
		var key := args[k]
		var value := args[k + 1]
		match key:
			"speed":
				if not value.is_valid_int():
					return _bad_args()
				want.speed = value.to_int()
			"duplex":
				if value not in ["half", "full"]:
					return _bad_args()
				want.duplex = value
			"autoneg":
				if value not in ["on", "off"]:
					return _bad_args()
				want.autoneg = value == "on"
			"advertise":
				var hex := value.trim_prefix("0x").trim_prefix("0X")
				if not hex.is_valid_hex_number():
					return _bad_args()
				want.advertise = hex.hex_to_int()
			_:
				return _bad_args()
		k += 2
	var i := _iface(name)
	if i == null or i.nic == null or _no_mii(i.nic):
		_p.errln("Cannot get current device settings: %s" % ("No such device" if i == null else "Operation not supported"))
		return 75 if i == null else 1
	var nic := i.nic
	var autoneg: bool = want.get("autoneg", nic.autoneg)
	var speed: int = want.get("speed", nic.forced_speed)
	var duplex: String = want.get("duplex", nic.forced_duplex)
	var adv := -1
	if want.has("advertise"):
		adv = want.advertise
	elif want.get("autoneg", false):
		# autoneg on with a speed or duplex advertises just the matching
		# modes; without, everything the card can do.
		adv = 0
		for mode: Array in AgoraNic.MODES:
			if (not want.has("speed") or mode[1] == want.speed) and (not want.has("duplex") or mode[2] == want.duplex):
				adv |= mode[3]
		adv &= nic.supported_mask()
	var error := ""
	if not _p.cred.is_root():
		error = "Operation not permitted"
	elif not autoneg and not _can_force(nic, speed, duplex):
		error = "Invalid argument"
	elif adv == 0 or (adv > 0 and adv & ~nic.supported_mask()):
		error = "Invalid argument"
	if not error.is_empty():
		_p.errln("Cannot set new settings: %s" % error)
		for what in ["speed", "duplex", "autoneg"]:
			if want.has(what):
				_p.errln("  not setting %s" % what)
		if want.has("advertise"):
			_p.errln("  not setting advertise")
		return 80
	nic.configure(autoneg, speed, duplex, adv)
	return 0


## Fixed settings a card accepts: a speed it has below gigabit (1000BASE-T
## needs autonegotiation).
func _can_force(nic: AgoraNic, speed: int, duplex: String) -> bool:
	for mode: Array in AgoraNic.MODES:
		if mode[1] == speed and mode[2] == duplex and speed < 1000:
			return nic.supported_mask() & mode[3] != 0
	return false


func _restart(args: PackedStringArray) -> int:
	var i := _iface(args[0])
	if i == null:
		_p.errln("Cannot restart autonegotiation: No such device")
		return 1
	if not _p.cred.is_root():
		_p.errln("Cannot restart autonegotiation: Operation not permitted")
		return 1
	if i.nic == null or _no_mii(i.nic) or not i.nic.autoneg:
		_p.errln("Cannot restart autonegotiation: %s" % ("Operation not supported" if i.nic == null or _no_mii(i.nic) else "Invalid argument"))
		return 1
	if i.nic.cable:
		i.nic.cable.negotiate(true)
	return 0
