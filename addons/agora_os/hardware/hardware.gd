class_name AgoraHardware
extends RefCounted
## A physical device: the box the operating system is installed on.
##
## It has a CPU, memory, disks (fixed ones and removable media), network
## ports, maybe a display connector, and a serial console. Its firmware picks
## a bootable disk following [member boot_order]: a hard disk's boot sector
## starts GRUB ([AgoraGrub]), which loads the kernel ([AgoraMachine]) with
## the command line of its menu; a CD or the router's flash start the
## kernel themselves. With nothing bootable it says so on the console.
##
## The firmware's settings are in [member cmos]. With [member interactive]
## set (a box someone sits at) it is the full BIOS ([AgoraBios]): the
## self test, Setup on DEL, the boot menu on F12, GRUB's menu with its
## countdown; [method power_on] returns at once and
## [signal machine_started] tells when a kernel runs. Otherwise the boot
## takes the defaults and is done when [method power_on] returns.
##
## [codeblock]
## var hw := AgoraHardware.from_template("pc")
## hw.insert(AgoraMedia.installer())   # an install CD
## hw.power_on()                       # boots the installer
## [/codeblock]

signal powered_on
signal powered_off
## A kernel was started (also after a reboot onto another disk).
signal machine_started(machine: AgoraMachine)

enum Power { OFF, ON }

const IMAGE_FORMAT := 2

## Device templates. Names and figures are fictional but true to the era.
const TEMPLATES := {
	"pc": {
		"vendor": "AgoraTech", "model": "Desktop PC 2400", "arch": "i686",
		"cpu": "AgoraTech P4-class CPU 2.40GHz", "mhz": 2400, "cores": 1, "ram_mb": 512,
		"disks": [["hdd", "ATA MAXDISK 40G", 40960]], "cdrom": "ATAPI CD-ROM 52X",
		"nics": [["eth0", ""]], "nic": ["e100", 100], "display": true, "serial": true,
	},
	"server": {
		"vendor": "AgoraTech", "model": "Rack Server R1", "arch": "i686",
		"cpu": "AgoraTech Xeon-class CPU 2.80GHz", "mhz": 2800, "cores": 2, "ram_mb": 2048,
		"disks": [["hdd", "SCSI ULTRA320 73G", 74752]], "cdrom": "ATAPI CD-ROM 48X",
		"nics": [["eth0", ""], ["eth1", ""]], "nic": ["e1000", 1000], "display": true, "serial": true,
	},
	"router": {
		"vendor": "Agora Networks", "model": "WR-54 Wireless Router", "arch": "mips",
		"cpu": "MIPS32 4Kc V0.7 200MHz", "mhz": 200, "cores": 1, "ram_mb": 16,
		"disks": [["flash", "Onboard flash 4M", 4]], "cdrom": "",
		"nics": [["eth0", "WAN"], ["eth1", "LAN1"], ["eth2", "LAN2"], ["eth3", "LAN3"], ["eth4", "LAN4"]],
		"nic": ["b44", 100], "display": false, "serial": true,
	},
	# An unmanaged Ethernet switch: no CPU, no OS, eight ports.
	"switch": {
		"vendor": "Agora Networks", "model": "FS-108 Fast Ethernet Switch", "arch": "", "cpu": "", "mhz": 0,
		"cores": 0, "ram_mb": 0, "disks": [], "cdrom": "",
		"nics": [["port1", "1"], ["port2", "2"], ["port3", "3"], ["port4", "4"], ["port5", "5"], ["port6", "6"], ["port7", "7"], ["port8", "8"]],
		"nic": ["switch", 100], "display": false, "serial": false, "switch": true,
	},
	# A headless PC: what AgoraMachine.create() builds for tests and embedding.
	"virtual": {
		"vendor": "Agora", "model": "Virtual Machine", "arch": "i686",
		"cpu": "Virtual CPU 2.00GHz", "mhz": 2000, "cores": 1, "ram_mb": 256,
		"disks": [["hdd", "VIRTUAL DISK 8G", 8192]], "cdrom": "VIRTUAL CD-ROM",
		"nics": [["eth0", ""]], "nic": ["e1000", 1000], "display": false, "serial": true,
	},
}

var template := "pc"
var vendor := ""
var model := ""
var arch := "i686"
var cpu_model := ""
var cpu_mhz := 1000
var cpu_cores := 1
var ram_mb := 256
## Fixed disks first, then inserted removable media.
var disks: Array[AgoraDisk] = []
## Model of the optical drive, or "" if there is none.
var cdrom_drive := ""
var nics: Array[AgoraNic] = []
var display: AgoraDisplay
## Text console on the monitor (tty1). Null without a display.
var console: AgoraTty
## Serial console (ttyS0). Connect a terminal to it like a console cable.
var serial: AgoraTty
var boot_order: PackedStringArray = ["cdrom", "usb", "hdd", "flash"]
var cmos := AgoraCmos.new()
## The coin cell that keeps the CMOS while the box has no power at all.
var cmos_battery := true
## The clear-CMOS jumper on pins 2-3 instead of 1-2: the CMOS is shorted
## and the board doesn't start.
var cmos_jumper_clear := false
## The power cord is in (the PSU's standby power also keeps the CMOS).
var mains := true
## The firmware waits for keys and shows its screens (see the class
## description).
var interactive := false
## The NumLock light of the keyboard.
var numlock := false
## When the power was switched on (game time).
var powered_on_at := 0.0
var clock: AgoraClock
## The clock kernels run on: the CMOS clock, [member clock] moved by
## [member AgoraCmos.rtc_offset].
var rtc: AgoraClock
var power: Power = Power.OFF
## An unmanaged switch: while on, it forwards frames between its ports by
## itself, learning which address is behind which port.
var is_switch := false
## The switch's forwarding table: MAC -> port.
var _fdb := {}
var machine: AgoraMachine


static func from_template(name: String, p_clock: AgoraClock = null) -> AgoraHardware:
	var spec: Dictionary = TEMPLATES[name]
	var hw := AgoraHardware.new()
	hw.template = name
	hw.clock = p_clock if p_clock else AgoraClock.new()
	hw.rtc = AgoraClock.follow(hw.clock)
	hw.vendor = spec.vendor
	hw.model = spec.model
	hw.arch = spec.arch
	hw.cpu_model = spec.cpu
	hw.cpu_mhz = spec.mhz
	hw.cpu_cores = spec.cores
	hw.ram_mb = spec.ram_mb
	hw.cdrom_drive = spec.cdrom
	for d: Array in spec.disks:
		var kind: AgoraDisk.Kind = {"hdd": AgoraDisk.Kind.HDD, "flash": AgoraDisk.Kind.FLASH}[d[0]]
		hw.disks.append(AgoraDisk.make(kind, d[1], d[2]))
	var chip: Array = spec.nic
	for n: Array in spec.nics:
		var nic := AgoraNic.new()
		nic.name = n[0]
		nic.label = n[1]
		nic.driver = chip[0]
		nic.speed_mbps = chip[1]
		nic.bus_info = "0000:02:%02x.0" % (hw.nics.size() + 1)
		nic.mac = AgoraNic.random_mac()
		hw.nics.append(nic)
	if spec.serial:
		hw.serial = AgoraTty.new("ttyS0")
	if spec.display:
		hw.add_display()
	hw.is_switch = spec.get("switch", false)
	return hw


## Connects a monitor: a display server and a text console on it.
func add_display() -> AgoraDisplay:
	if display == null:
		display = AgoraDisplay.new(":0")
		console = AgoraTty.new("tty1")
		if machine:
			display.bind_machine(machine)
	return display


# --- media and ports ----------------------------------------------------------

## Inserts removable media (a CD or USB stick). Returns false if there is no
## drive for it.
func insert(disk: AgoraDisk) -> bool:
	if disk.kind == AgoraDisk.Kind.CDROM:
		if cdrom_drive.is_empty() or media(AgoraDisk.Kind.CDROM) != null:
			return false
	disks.append(disk)
	return true


## Removes media. The running kernel loses access to it.
func eject(disk: AgoraDisk) -> bool:
	if not disk.removable or not disks.has(disk):
		return false
	disks.erase(disk)
	if machine:
		machine.vfs.unmount_fs(disk.fs)
	return true


## The inserted medium of [param kind], or null.
func media(kind: AgoraDisk.Kind) -> AgoraDisk:
	for d in disks:
		if d.kind == kind and d.removable:
			return d
	return null


## Kernel device name: sda/sdb for disks and USB sticks, sr0 for CDs,
## mtdblock0 for flash.
func device_name(disk: AgoraDisk) -> String:
	var sd := 0
	var sr := 0
	var mtd := 0
	for d in disks:
		var name := ""
		match d.kind:
			AgoraDisk.Kind.HDD, AgoraDisk.Kind.USB:
				name = "sd" + "abcdefgh"[sd]
				sd += 1
			AgoraDisk.Kind.CDROM:
				name = "sr%d" % sr
				sr += 1
			AgoraDisk.Kind.FLASH:
				name = "mtdblock%d" % mtd
				mtd += 1
		if d == disk:
			return name
	return ""


## Name of the device holding the file system: "sda1" for a partitioned
## disk, the disk itself for CDs and flash.
func fs_device_name(disk: AgoraDisk) -> String:
	var name := device_name(disk)
	return name + "1" if name.begins_with("sd") else name


## Disk for a device name like "sda", "sda1", "/dev/sr0", or null.
func find_device(name: String) -> AgoraDisk:
	name = name.trim_prefix("/dev/")
	for d in disks:
		if device_name(d) == name or fs_device_name(d) == name:
			return d
	return null


func nic(name: String) -> AgoraNic:
	for n in nics:
		if n.name == name:
			return n
	return null


## Plugs a cable [param length_m] metres long between a port of this box
## and a port of another.
func connect_port(port: String, other: AgoraHardware, other_port: String, length_m: float = 2.0) -> bool:
	var a := nic(port)
	var b := other.nic(other_port)
	if a == null or b == null:
		return false
	a.plug(b, length_m)
	return true


func get_tty(name: String) -> AgoraTty:
	name = name.trim_prefix("/dev/")
	if console and name == console.name:
		return console
	if serial and name == serial.name:
		return serial
	return null


# --- power and firmware -------------------------------------------------------

## Presses the power button. The firmware looks for a bootable disk and,
## unless [param boot] is false, starts the kernel on it. Returns the
## machine, or null if nothing could boot.
func power_on(boot: bool = true) -> AgoraMachine:
	if power == Power.ON:
		return machine
	if cmos_jumper_clear or not mains:
		return null # no power, or the board stays dead while the CMOS is shorted
	power = Power.ON
	powered_on_at = clock.now()
	powered_on.emit()
	if is_switch:
		_fdb.clear()
		for n in nics:
			n.receiver = _switch_frame.bind(n)
		return null
	if interactive and boot:
		_run_bios()
		return null
	return _firmware(boot)


## Moves the clear-CMOS jumper: on pins 2-3 ([param clear]) the CMOS
## loses its settings; back on 1-2 the board starts again.
func set_cmos_jumper(clear: bool) -> void:
	cmos_jumper_clear = clear
	if clear:
		cmos.clear(self)


## Takes the CMOS battery out or puts it back. Without it and without
## the power cord the settings are gone.
func set_cmos_battery(present: bool) -> void:
	cmos_battery = present
	_check_cmos_power()


## The power cord in or out. Out cuts the power.
func set_mains(plugged: bool) -> void:
	mains = plugged
	if not plugged and power == Power.ON:
		power_off()
	_check_cmos_power()


func _check_cmos_power() -> void:
	if not cmos_battery and not mains and cmos.valid:
		cmos.clear(self)


## Starts the firmware over, as the reset button or Save & Exit do.
func restart_firmware() -> void:
	if power != Power.ON:
		return
	if interactive:
		_run_bios()
	else:
		_firmware(true)


## The screen the firmware uses: the monitor, or the serial port of a box
## without one.
func firmware_tty() -> AgoraTty:
	return console if console else serial


var _boot_gen := 0
var _fw_screen: AgoraFwScreen


func _run_bios() -> void:
	_boot_gen += 1
	var gen := _boot_gen
	var tty := firmware_tty()
	if tty == null:
		_firmware(true)
		return
	if _fw_screen:
		_fw_screen.end()
	_fw_screen = AgoraFwScreen.new(tty, func() -> bool: return _boot_gen == gen and power == Power.ON)
	var bios := AgoraBios.new(self, _fw_screen)
	await bios.run()
	if _boot_gen == gen and _fw_screen and machine and machine.state == AgoraMachine.State.RUNNING:
		_fw_screen = null


## Cuts the power: no clean shutdown.
func power_off() -> void:
	if machine:
		machine.shutdown()
	_powered_down()


## A frame on one of the switch's ports: learn where its sender is, then
## pass it to the port of its receiver, or out of every other port.
func _switch_frame(frame: Dictionary, from: AgoraNic) -> void:
	if power != Power.ON or frame.get("bad_fcs", false) or frame.get("runt", false):
		return
	_fdb[frame.get("src", "")] = from
	var to: AgoraNic = _fdb.get(frame.get("dst", ""))
	if to and to != from:
		to.transmit(frame)
		return
	if to == from:
		return
	for n in nics:
		if n != from and n.carrier:
			n.transmit(frame)


func _powered_down() -> void:
	_boot_gen += 1
	numlock = false
	if _fw_screen:
		_fw_screen.end()
		_fw_screen = null
	if is_switch:
		for n in nics:
			n.receiver = Callable()
		_fdb.clear()
	power = Power.OFF
	powered_off.emit()


## The firmware picks a disk following the boot order ([param order], or
## [member boot_order]).
func boot_disk(order: PackedStringArray = PackedStringArray()) -> AgoraDisk:
	var kinds := {"cdrom": AgoraDisk.Kind.CDROM, "usb": AgoraDisk.Kind.USB, "hdd": AgoraDisk.Kind.HDD, "flash": AgoraDisk.Kind.FLASH}
	for entry in (order if not order.is_empty() else boot_order):
		for d in disks:
			if d.kind == kinds.get(entry, -1) and d.is_bootable():
				return d
	return null


func _firmware(boot: bool) -> AgoraMachine:
	_say("\u001b[2J\u001b[H%s BIOS v1.07" % vendor)
	_say("%s, %d MB RAM" % [cpu_model, ram_mb])
	for d in disks:
		_say("  %-10s %s%s" % [device_name(d), d.model, "" if d.is_formatted() else " (empty)"])
	if not cmos.valid:
		_say("CMOS checksum error - Defaults loaded")
		cmos.valid = true
	var disk := boot_disk()
	if disk == null:
		_say("\nDISK BOOT FAILURE, INSERT SYSTEM DISK AND PRESS ENTER")
		machine = null
		return null
	var loaded := _boot_loader(disk)
	if not loaded.has("boot"):
		machine = null
		if loaded.has("reboot"):
			_kernel_reboot()
		return null
	return start_kernel(loaded.disk, loaded.cmdline, boot)


## What the boot device starts with: GRUB from a hard disk's boot sector,
## the kernel itself from a CD, a live stick or the flash. Returns {boot,
## disk, cmdline} or what stopped it.
func _boot_loader(disk: AgoraDisk) -> Dictionary:
	if disk.boot_sector == "grub":
		var grub := AgoraGrub.new(self, disk, _print)
		var err := grub.load()
		if not err.is_empty():
			_say(err)
			return {}
		return grub.boot_default()
	if disk.kind == AgoraDisk.Kind.FLASH:
		return {"boot": true, "disk": disk, "cmdline": "root=/dev/%s console=ttyS0,115200" % fs_device_name(disk)}
	_say("Booting from %s...\n" % device_name(disk))
	return {"boot": true, "disk": disk, "cmdline": "root=/dev/%s" % fs_device_name(disk)}


## Starts a kernel loaded from [param kernel_disk] with [param cmdline]. Its
## root file system is the device "root=" names (the kernel's own disk
## without one). Returns the machine, or null after a kernel panic over a
## root device that isn't there.
func start_kernel(kernel_disk: AgoraDisk, cmdline: String, boot: bool = true) -> AgoraMachine:
	var params: Dictionary = AgoraMachine.parse_cmdline(cmdline).params
	var disk := kernel_disk
	var root_name: String = params.get("root", "")
	if not root_name.is_empty():
		disk = find_device(root_name)
		if disk and (not disk.is_formatted() or fs_device_name(disk) != root_name.trim_prefix("/dev/")):
			disk = null
	if disk == null:
		var dev := root_name.trim_prefix("/dev/")
		_say("VFS: Cannot open root device \"%s\" or unknown-block(0,0)" % dev)
		_say("Please append a correct \"root=\" boot option")
		_say("Kernel panic - not syncing: VFS: Unable to mount root fs on unknown-block(0,0)")
		machine = null
		return null
	_print("Uncompressing Agora... Ok, booting the kernel.\n")
	numlock = cmos.numlock
	rtc.follow_offset = cmos.rtc_offset
	if machine == null or machine.root_disk != disk:
		if machine:
			machine.shutdown()
		machine = AgoraMachine.new(rtc, self, disk)
		if display:
			display.bind_machine(machine)
	machine.cmdline = cmdline
	if boot:
		machine.boot()
		machine_started.emit(machine)
	return machine


## Called by the kernel when init asks for a reboot: back to the firmware,
## which may now pick another disk (the installer ejected its CD).
func _kernel_reboot() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.process_frame
	restart_firmware()


## Called by the kernel after a clean poweroff or halt.
func _kernel_power_off() -> void:
	_powered_down()


## Prints a firmware message on every console.
func _say(text: String) -> void:
	_print(text + "\n")


func _print(text: String) -> void:
	for tty in [console, serial]:
		if tty:
			(tty as AgoraTty).output.write(text)


# --- persistence --------------------------------------------------------------

func serialize() -> Dictionary:
	var disk_data: Array = []
	for d in disks:
		disk_data.append(d.serialize())
	var nic_data: Array = []
	for n in nics:
		nic_data.append({"name": n.name, "mac": n.mac, "label": n.label})
	return {
		"format": IMAGE_FORMAT, "template": template, "disks": disk_data, "nics": nic_data,
		"display": display != null, "boot_order": boot_order, "clock": clock.serialize(), "cmos": cmos.serialize(),
		"cmos_battery": cmos_battery, "cmos_jumper_clear": cmos_jumper_clear, "mains": mains,
	}


static func deserialize(data: Dictionary, p_clock: AgoraClock = null) -> AgoraHardware:
	if data.get("format", 1) < 2:
		return _from_v1(data, p_clock)
	var hw := from_template(data.get("template", "pc"), p_clock)
	hw.disks.clear()
	for d: Dictionary in data.get("disks", []):
		hw.disks.append(AgoraDisk.deserialize(d))
	for n: Dictionary in data.get("nics", []):
		var nic := hw.nic(n.name)
		if nic:
			nic.mac = n.mac
	if data.get("display", false):
		hw.add_display()
	hw.boot_order = data.get("boot_order", hw.boot_order)
	hw.cmos.deserialize(data.get("cmos", {}))
	hw.cmos_battery = data.get("cmos_battery", true)
	hw.cmos_jumper_clear = data.get("cmos_jumper_clear", false)
	hw.mains = data.get("mains", true)
	if p_clock == null and data.has("clock"):
		hw.clock.deserialize(data.clock)
	return hw


## Images saved before hardware existed held just the root file system.
static func _from_v1(data: Dictionary, p_clock: AgoraClock) -> AgoraHardware:
	var hw := from_template("pc", p_clock)
	hw.disks[0].fs = AgoraMemFs.new()
	hw.disks[0].fs.deserialize(data.get("root", {}))
	if p_clock == null and data.has("clock"):
		hw.clock.deserialize(data.clock)
	return hw


## Saves the whole box (every disk included), compressed.
func save(path: String) -> int:
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(serialize())
	return OK


static func load_from(path: String, p_clock: AgoraClock = null) -> AgoraHardware:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return null
	var data: Variant = f.get_var()
	return deserialize(data, p_clock) if data is Dictionary else null
