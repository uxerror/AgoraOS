class_name AgoraBios
extends RefCounted
## The BIOS of a PC with someone at it (an Award-style one of 2003):
## the power-on self test with its memory count and the drives found,
## DEL for Setup ([AgoraBiosSetup]), F12 for a one-time boot menu, the
## password when Security is "System", then the boot devices in order
## until one starts: GRUB from a hard disk ([AgoraGrubMenu]), the kernel
## itself from a CD.
##
## The router has no BIOS: [method run] prints its CFE boot loader on the
## serial port instead. [AgoraHardware] runs this when
## [member AgoraHardware.interactive] is set; otherwise it boots at once.

const BIOS_VERSION := "v6.00AG"
const BOOT_NAMES := {"cdrom": "CDROM", "hdd": "HDD-0", "usb": "USB-HDD", "floppy": "Floppy", "": "Disabled"}

var hw: AgoraHardware
var screen: AgoraFwScreen
var _post_key := ""


func _init(p_hw: AgoraHardware, p_screen: AgoraFwScreen) -> void:
	hw = p_hw
	screen = p_screen


## The whole way from the power button to a running kernel.
func run() -> void:
	screen.begin()
	if hw.template == "router":
		await _cfe()
		return
	var once := ""
	while screen.is_alive():
		var action: String = await _post()
		if not screen.is_alive():
			return
		if action == "setup":
			if not await _password(true):
				return
			await AgoraBiosSetup.new(hw, screen).run()
			if screen.is_alive():
				hw.restart_firmware()
			return
		if action == "menu":
			once = await _boot_menu()
			if not screen.is_alive():
				return
		if hw.cmos.security == "System" and not await _password(false):
			return
		await _boot(once)
		return


# --- POST ----------------------------------------------------------------------

## The self test. Returns "setup" (DEL), "menu" (F12) or "".
func _post() -> String:
	var cmos := hw.cmos
	_post_key = ""
	screen.clear()
	screen.put(0, 0, "%s Modular BIOS %s, An Energy Star Ally" % [hw.vendor, BIOS_VERSION], 15)
	screen.put(1, 0, "Copyright (C) 1998-2003, %s Inc." % hw.vendor)
	screen.put(3, 0, "%s %s BIOS Rev 1.07" % [hw.vendor, hw.model])
	screen.put(5, 0, "Main Processor : %s" % hw.cpu_model)
	screen.put(23, 0, "Press DEL to enter SETUP, F12 for BOOT MENU")
	screen.put(24, 0, "10/17/2003-%s-AG-6A79" % hw.model.replace(" ", "").left(8).to_upper())
	var total := hw.ram_mb * 1024
	var steps := 8 if cmos.quick_post else 32
	for i in steps + 1:
		screen.put(6, 0, "Memory Testing : %8dK%s" % [total * i / steps, " OK" if i == steps else ""])
		if not await _post_wait(0.05):
			return ""
	if not cmos.valid:
		screen.put(8, 0, "CMOS checksum error - Defaults loaded")
		screen.put(9, 0, "Press F1 to continue, DEL to enter SETUP")
		cmos.valid = true
		while screen.is_alive() and _post_key.is_empty():
			var k: String = await screen.key()
			if k == "f1":
				break
			if k == "delete":
				return "setup"
		screen.put(8, 0, " ".repeat(40))
		screen.put(9, 0, " ".repeat(42))
	var hdds: Array[AgoraDisk] = []
	for d in hw.disks:
		if d.kind == AgoraDisk.Kind.HDD:
			hdds.append(d)
	var channels := [
		["IDE Channel 0 Master", hdds[0].model if hdds.size() > 0 else "None"],
		["IDE Channel 0 Slave ", hdds[1].model if hdds.size() > 1 else "None"],
		["IDE Channel 1 Master", hw.cdrom_drive if not hw.cdrom_drive.is_empty() else "None"],
		["IDE Channel 1 Slave ", "None"],
	]
	for i in channels.size():
		screen.put(8 + i, 0, "%s : %s" % channels[i])
		if not await _post_wait(0.1 if cmos.quick_post else 0.3):
			return ""
	var row := 13
	for d in hw.disks:
		if d.kind == AgoraDisk.Kind.USB:
			screen.put(row, 0, "USB Mass Storage Device : %s" % d.model)
			row += 1
	hw.numlock = cmos.numlock
	if not await _post_wait(0.8 if cmos.quick_post else 2.0):
		return ""
	match _post_key:
		"delete":
			screen.put(23, 0, "Entering SETUP ...                          ")
			await screen.pause(0.3)
			return "setup"
		"f12":
			return "menu"
	return ""


## Waits, noting DEL or F12 if pressed. False when the boot was abandoned.
func _post_wait(seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var k: String = await screen.key(maxf(0.0, (deadline - Time.get_ticks_msec()) / 1000.0))
		if not screen.is_alive():
			return false
		if k in ["delete", "f12"] and _post_key.is_empty():
			_post_key = k
	return screen.is_alive()


# --- passwords -----------------------------------------------------------------

## Asks for a password: the supervisor's for Setup ([param for_setup]),
## either one at boot. Three wrong ones halt the system. True when there
## is no password to ask for, or it was right.
func _password(for_setup: bool) -> bool:
	var cmos := hw.cmos
	var accepted: PackedStringArray = []
	if not cmos.supervisor_password.is_empty():
		accepted.append(cmos.supervisor_password)
	if not cmos.user_password.is_empty() and (not for_setup or cmos.supervisor_password.is_empty()):
		accepted.append(cmos.user_password)
	if accepted.is_empty():
		return true
	for attempt in 3:
		if for_setup:
			screen.box(11, 24, 3, 32, 15, 1)
			screen.put(12, 26, "Enter Password: ", 15, 1)
		else:
			screen.clear()
			screen.put(12, 0, "Enter Password: ")
		var given: Variant = await screen.read_line(12, 42 if for_setup else 16, "", true, 8, 15 if for_setup else 7, 1 if for_setup else 0)
		if not screen.is_alive():
			return false
		if given != null and accepted.has(str(given)):
			return true
	screen.clear()
	screen.put(12, 0, "SYSTEM HALTED")
	return false


# --- booting -------------------------------------------------------------------

## The F12 menu: the devices there are, to boot one of them once. Returns
## its boot order name, or "" for the normal order (Esc).
func _boot_menu() -> String:
	var items: Array = []
	if not hw.cdrom_drive.is_empty():
		items.append(["cdrom", "CDROM    : " + hw.cdrom_drive])
	for d in hw.disks:
		if d.kind == AgoraDisk.Kind.HDD and not items.any(func(i: Array) -> bool: return i[0] == "hdd"):
			items.append(["hdd", "HDD-0    : " + d.model])
		elif d.kind == AgoraDisk.Kind.USB:
			items.append(["usb", "USB-HDD  : " + d.model])
	var sel := 0
	var width := 44
	var left := (AgoraFwScreen.COLS - width) / 2
	var top := 6
	while screen.is_alive():
		screen.clear()
		screen.box(top, left, items.size() + 7, width, 15, 4, true)
		screen.put(top, left + (width - 11) / 2, " Boot Menu ", 14, 4)
		for i in items.size():
			screen.fill(top + 1 + i, left + 1, width - 2, 15 if i == sel else 7, 1 if i == sel else 4, " %d. %s" % [i + 1, items[i][1]])
		var r := top + 2 + items.size()
		screen.put(r, left + 2, "↑ and ↓ to move selection", 7, 4)
		screen.put(r + 1, left + 2, "ENTER to select boot device", 7, 4)
		screen.put(r + 2, left + 2, "ESC to boot using defaults", 7, 4)
		var k: String = await screen.key()
		match k:
			"up": sel = maxi(0, sel - 1)
			"down": sel = mini(items.size() - 1, sel + 1)
			"enter": return items[sel][0] if not items.is_empty() else ""
			"esc", "": return ""
			_:
				if k.is_valid_int() and int(k) >= 1 and int(k) <= items.size():
					return items[int(k) - 1][0]
	return ""


## Tries the boot devices ([param once] alone, if given) until one starts.
func _boot(once: String) -> void:
	while screen.is_alive():
		screen.clear()
		screen.write("Verifying DMI Pool Data ........\n")
		if not await _post_wait(0.3):
			return
		var order := PackedStringArray([once]) if not once.is_empty() else hw.boot_order
		var disk := hw.boot_disk(order)
		if disk == null:
			screen.write("DISK BOOT FAILURE, INSERT SYSTEM DISK AND PRESS ENTER\n")
			while screen.is_alive() and await screen.key() != "enter":
				pass
			continue
		if disk.boot_sector == "grub":
			var grub := AgoraGrub.new(hw, disk, screen.write)
			var r: Dictionary = await AgoraGrubMenu.new(grub, screen).run()
			if not screen.is_alive() or r.is_empty() or r.has("error"):
				return
			if r.has("reboot"):
				hw.restart_firmware()
			elif r.has("halt"):
				hw.power_off()
			else:
				screen.end()
				hw.start_kernel(r.disk, r.cmdline)
			return
		if disk.kind == AgoraDisk.Kind.CDROM:
			screen.write("Boot from CD :\n")
		screen.write("Booting from %s...\n" % hw.device_name(disk))
		await screen.pause(0.3)
		if not screen.is_alive():
			return
		screen.end()
		hw.start_kernel(disk, "root=/dev/" + hw.fs_device_name(disk))
		return


## The router's boot loader on its serial console.
func _cfe() -> void:
	var lines := [
		"CFE version 1.0.37 for %s (32bit,SP,BE)" % hw.model.get_slice(" ", 0),
		"Build Date: Fri Oct 17 12:00:00 CST 2003",
		"Copyright (C) 2003 %s" % hw.vendor,
		"",
		"Initializing Arena",
		"Initializing Devices.",
		"CPU type 0x19300: %dMHz" % hw.cpu_mhz,
		"Total memory: %d MB" % hw.ram_mb,
		"",
		"Total memory used by CFE:  0x80700000 - 0x80800000 (1048576)",
		"Initialized Data:          0x80734200 - 0x80736C60 (10848)",
		"",
		"Device eth0:  hwaddr %s, ipaddr 192.168.1.1, mask 255.255.255.0" % hw.nics[0].mac.to_upper().replace(":", "-"),
		"        gateway not set, nameserver not set",
		"Loader:raw Filesys:raw Dev:flash0.os File: Options:(null)",
		"Loading: ...... 1048576 bytes read",
		"Entry at 0x80001000",
		"Closing network.",
		"Starting program at 0x80001000",
	]
	for line: String in lines:
		screen.write(line + "\n")
		if not await _post_wait(0.03):
			return
	screen.end()
	var flash := hw.boot_disk(PackedStringArray(["flash"]))
	if flash == null:
		screen.write("Could not load flash0.os: Error\nCFE> ")
		return
	hw.start_kernel(flash, "root=/dev/%s console=ttyS0,115200" % hw.fs_device_name(flash))
