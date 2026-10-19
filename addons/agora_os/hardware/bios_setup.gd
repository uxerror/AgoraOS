class_name AgoraBiosSetup
extends RefCounted
## The BIOS Setup program: the blue screens behind DEL. The main menu
## leads to pages of settings (Standard CMOS Features: date, time, drives;
## Advanced BIOS Features: quick POST, the boot order, NumLock, security;
## Integrated Peripherals: the onboard network chip; PC Health Status),
## the defaults, the passwords, and Save & Exit / Exit Without Saving.
##
## Changes are made on a copy of the CMOS and the boot order, written back
## by Save & Exit (or F10). Either way of leaving restarts the machine.

const TITLE := "%s BIOS CMOS Setup Utility"
## Colours: the screen, items, the highlighted item, values, help text.
const BG := 4
const FG := 15
const ITEM := 11
const SEL_FG := 15
const SEL_BG := 1
const HELP := 7
const BOOT_CHOICES: PackedStringArray = ["Floppy", "HDD-0", "CDROM", "USB-HDD", "Disabled"]
const BOOT_KEYS := {"Floppy": "floppy", "HDD-0": "hdd", "CDROM": "cdrom", "USB-HDD": "usb", "Disabled": ""}

const MAIN_LEFT: PackedStringArray = [
	"► Standard CMOS Features", "► Advanced BIOS Features", "► Integrated Peripherals",
	"► PC Health Status", "  Load Fail-Safe Defaults", "  Load Optimized Defaults",
]
const MAIN_RIGHT: PackedStringArray = [
	"  Set Supervisor Password", "  Set User Password", "  Save & Exit Setup", "  Exit Without Saving",
]
const MAIN_HELP: PackedStringArray = [
	"Time, Date, Hard Disk Type...", "Boot order, POST and security options", "Onboard devices",
	"Temperatures, fans and voltages", "Load Fail-Safe Defaults", "Load Optimized Defaults",
	"Change/Set/Disable Password", "Change/Set/Disable Password", "Save Data to CMOS", "Abandon all Data",
]

var hw: AgoraHardware
var screen: AgoraFwScreen
## The settings being edited, and the boot order.
var cmos: AgoraCmos
var boot_order: PackedStringArray


func _init(p_hw: AgoraHardware, p_screen: AgoraFwScreen) -> void:
	hw = p_hw
	screen = p_screen
	cmos = hw.cmos.copy()
	boot_order = hw.boot_order.slice(0, 3)
	while boot_order.size() < 3:
		boot_order.append("")


## Runs Setup until it is left. The caller restarts the machine.
func run() -> void:
	var col := 0
	var row := 0
	while screen.is_alive():
		_draw_main(col, row)
		var k: String = await screen.key()
		var items := MAIN_LEFT if col == 0 else MAIN_RIGHT
		match k:
			"up":
				row = (row - 1 + items.size()) % items.size()
			"down":
				row = (row + 1) % items.size()
			"left", "right":
				col = 1 - col
				row = mini(row, (MAIN_LEFT if col == 0 else MAIN_RIGHT).size() - 1)
			"f10":
				if await _confirm("SAVE to CMOS and EXIT (Y/N)? ", true):
					_save()
					return
			"esc":
				if await _confirm("Quit Without Saving (Y/N)? ", false):
					return
			"enter":
				if await _choose(col, row):
					return
			"":
				return


## Enter on a main menu item. True when Setup is left.
func _choose(col: int, row: int) -> bool:
	var item := (MAIN_LEFT if col == 0 else MAIN_RIGHT)[row].substr(2)
	match item:
		"Standard CMOS Features", "Advanced BIOS Features", "Integrated Peripherals", "PC Health Status":
			return await _page(item)
		"Load Fail-Safe Defaults", "Load Optimized Defaults":
			if await _confirm("%s (Y/N)? " % item, false):
				cmos.load_defaults(item == "Load Fail-Safe Defaults")
				boot_order = AgoraCmos.DEFAULT_BOOT_ORDER.duplicate()
		"Set Supervisor Password", "Set User Password":
			var pw: Variant = await _new_password()
			if pw != null:
				if item == "Set Supervisor Password":
					cmos.supervisor_password = pw
				else:
					cmos.user_password = pw
		"Save & Exit Setup":
			if await _confirm("SAVE to CMOS and EXIT (Y/N)? ", true):
				_save()
				return true
		"Exit Without Saving":
			if await _confirm("Quit Without Saving (Y/N)? ", false):
				return true
	return false


func _save() -> void:
	hw.cmos = cmos
	var order: PackedStringArray = []
	for b in boot_order:
		if not b.is_empty():
			order.append(b)
	hw.boot_order = order


# --- drawing -------------------------------------------------------------------

func _title(subtitle: String = "") -> void:
	screen.clear(FG, BG)
	var t := TITLE % hw.vendor
	screen.put(0, (AgoraFwScreen.COLS - t.length()) / 2, t, FG, BG)
	if not subtitle.is_empty():
		screen.put(1, (AgoraFwScreen.COLS - subtitle.length()) / 2, subtitle, FG, BG)


func _draw_main(col: int, row: int) -> void:
	_title()
	screen.put(1, 0, "╔" + "═".repeat(39) + "╦" + "═".repeat(38) + "╗", FG, BG)
	for r in range(2, 15):
		screen.put(r, 0, "║", FG, BG)
		screen.put(r, 40, "║", FG, BG)
		screen.put(r, 79, "║", FG, BG)
	for i in MAIN_LEFT.size():
		var on := col == 0 and row == i
		screen.put(3 + i * 2, 2, MAIN_LEFT[i].rpad(36), SEL_FG if on else ITEM, SEL_BG if on else BG)
	for i in MAIN_RIGHT.size():
		var on := col == 1 and row == i
		screen.put(3 + i * 2, 42, MAIN_RIGHT[i].rpad(35), SEL_FG if on else ITEM, SEL_BG if on else BG)
	screen.put(15, 0, "╠" + "═".repeat(39) + "╩" + "═".repeat(38) + "╣", FG, BG)
	screen.put(16, 0, "║ Esc : Quit                            ↑ ↓ → ←   : Select Item".rpad(79) + "║", FG, BG)
	screen.put(17, 0, "║ F10 : Save & Exit Setup".rpad(79) + "║", FG, BG)
	screen.put(18, 0, "╠" + "═".repeat(78) + "╣", FG, BG)
	var help := MAIN_HELP[row if col == 0 else MAIN_LEFT.size() + row]
	screen.put(19, 0, "║" + help.lpad((78 + help.length()) / 2).rpad(78) + "║", FG, BG)
	screen.put(20, 0, "╚" + "═".repeat(78) + "╝", FG, BG)


## A centered box with a question; Y/N, Enter takes the answer shown.
func _confirm(question: String, default: bool) -> bool:
	var answer := default
	var width := question.length() + 6
	var left := (AgoraFwScreen.COLS - width) / 2
	while screen.is_alive():
		screen.box(10, left, 3, width, FG, SEL_BG)
		screen.put(11, left + 2, question + ("Y" if answer else "N"), FG, SEL_BG)
		var k: String = await screen.key()
		match k.to_lower():
			"y":
				answer = true
			"n":
				answer = false
			"enter":
				return answer
			"esc", "":
				return false
	return false


## Asks for a new password twice. Returns it, "" when Enter alone disables
## it, or null when nothing changes.
func _new_password() -> Variant:
	var left := 24
	screen.box(10, left, 3, 32, FG, SEL_BG)
	screen.put(11, left + 2, "Enter Password: ", FG, SEL_BG)
	var first: Variant = await screen.read_line(11, left + 18, "", true, 8, FG, SEL_BG)
	if first == null:
		return null
	if str(first).is_empty():
		screen.box(10, left, 3, 32, FG, SEL_BG)
		screen.put(11, left + 2, "PASSWORD DISABLED !!!", FG, SEL_BG)
		await screen.pause(1.0)
		return ""
	screen.box(10, left, 3, 32, FG, SEL_BG)
	screen.put(11, left + 2, "Confirm Password: ", FG, SEL_BG)
	var second: Variant = await screen.read_line(11, left + 20, "", true, 8, FG, SEL_BG)
	if second == null or str(second) != str(first):
		return null
	return first


# --- pages ---------------------------------------------------------------------

## The items of a page: {label, value: Callable -> String, help, kind:
## "choice" (options, set: Callable(String)), "date", "time" or "info"}.
func _items(page: String) -> Array:
	match page:
		"Standard CMOS Features":
			var hdds: Array[AgoraDisk] = []
			for d in hw.disks:
				if d.kind == AgoraDisk.Kind.HDD:
					hdds.append(d)
			var mem := hw.ram_mb * 1024
			return [
				{"label": "Date (mm:dd:yy)", "kind": "date", "value": _date_text, "help": "Change the day, month,\nyear and century"},
				{"label": "Time (hh:mm:ss)", "kind": "time", "value": _time_text, "help": "Change the internal\nclock"},
				{"label": "", "kind": "info", "value": func() -> String: return ""},
				{"label": "► IDE Channel 0 Master", "kind": "info", "value": _const("[%s]" % (hdds[0].model if hdds.size() > 0 else "None"))},
				{"label": "► IDE Channel 0 Slave", "kind": "info", "value": _const("[%s]" % (hdds[1].model if hdds.size() > 1 else "None"))},
				{"label": "► IDE Channel 1 Master", "kind": "info", "value": _const("[%s]" % (hw.cdrom_drive if not hw.cdrom_drive.is_empty() else "None"))},
				{"label": "► IDE Channel 1 Slave", "kind": "info", "value": _const("[None]")},
				{"label": "", "kind": "info", "value": _const("")},
				{"label": "Drive A", "kind": "info", "value": _const("[None]")},
				{"label": "Video", "kind": "info", "value": _const("[EGA/VGA]" if hw.display else "[None]")},
				{"label": "Halt On", "kind": "info", "value": _const("[All , But Keyboard]")},
				{"label": "", "kind": "info", "value": _const("")},
				{"label": "Base Memory", "kind": "info", "value": _const("640K")},
				{"label": "Extended Memory", "kind": "info", "value": _const("%dK" % (mem - 1024))},
				{"label": "Total Memory", "kind": "info", "value": _const("%dK" % mem)},
			]
		"Advanced BIOS Features":
			var out := [_toggle("Quick Power On Self Test", "quick_post", "Enabled", "Disabled", "Allows the system to\nskip certain tests\nwhile booting. This\nwill decrease the time\nneeded to boot the\nsystem")]
			for i in 3:
				out.append({"label": ["First", "Second", "Third"][i] + " Boot Device", "kind": "choice", "options": BOOT_CHOICES,
					"value": func() -> String: return "[%s]" % _boot_name(boot_order[i]),
					"set": func(v: String) -> void: boot_order[i] = BOOT_KEYS[v],
					"help": "Select Your Boot\nDevice Priority"})
			out.append(_toggle("Boot Up NumLock Status", "numlock", "On", "Off", "Select power on state\nfor NumLock"))
			out.append({"label": "Security Option", "kind": "choice", "options": PackedStringArray(["Setup", "System"]),
				"value": func() -> String: return "[%s]" % cmos.security,
				"set": func(v: String) -> void: cmos.security = v,
				"help": "Select whether the\npassword is required\nevery time the system\nboots or only when you\nenter setup"})
			return out
		"Integrated Peripherals":
			return [_toggle("Onboard LAN Device", "onboard_lan", "Enabled", "Disabled", "Enable or disable the\nonboard network\ncontroller")]
		"PC Health Status":
			var up := hw.clock.now() - hw.powered_on_at
			var temp := 38 + mini(14, int(up / 60.0))
			return [
				{"label": "Current CPU Temperature", "kind": "info", "value": _const("%d°C/%d°F" % [temp, temp * 9 / 5 + 32])},
				{"label": "Current CPU FAN Speed", "kind": "info", "value": _const("%d RPM" % (3100 + temp * 7))},
				{"label": "Vcore", "kind": "info", "value": _const("1.52 V")},
				{"label": "+3.3 V", "kind": "info", "value": _const("3.31 V")},
				{"label": "+5 V", "kind": "info", "value": _const("5.02 V")},
				{"label": "+12 V", "kind": "info", "value": _const("12.16 V")},
				{"label": "5VSB(V)", "kind": "info", "value": _const("5.05 V")},
				{"label": "Voltage Battery", "kind": "info", "value": _const("3.12 V")},
			]
	return []


func _const(text: String) -> Callable:
	return func() -> String: return text


func _toggle(label: String, field: String, on: String, off: String, help: String) -> Dictionary:
	return {"label": label, "kind": "choice", "options": PackedStringArray([on, off]),
		"value": func() -> String: return "[%s]" % (on if cmos.get(field) else off),
		"set": func(v: String) -> void: cmos.set(field, v == on),
		"help": help}


func _boot_name(key: String) -> String:
	for name: String in BOOT_KEYS:
		if BOOT_KEYS[name] == key:
			return name
	return "Disabled"


## A page of items. True when Setup is left from it (F10).
func _page(page: String) -> bool:
	var items := _items(page)
	var sel := _next_item(items, -1, 1)
	while screen.is_alive():
		items = _items(page)
		_draw_page(page, items, sel)
		# The clock ticks on the page with the time.
		var k: String = await screen.key(1.0 if page == "Standard CMOS Features" else -1.0)
		if not screen.is_alive():
			return false
		match k:
			"":
				continue
			"up":
				sel = _next_item(items, sel, -1)
			"down":
				sel = _next_item(items, sel, 1)
			"esc":
				return false
			"f10":
				if await _confirm("SAVE to CMOS and EXIT (Y/N)? ", true):
					_save()
					return true
			"pageup", "+", "pagedown", "-":
				if sel >= 0:
					_step(items[sel], 1 if k in ["pageup", "+"] else -1)
			"enter":
				if sel >= 0:
					await _edit(items[sel])
	return false


func _next_item(items: Array, from: int, dir: int) -> int:
	var i := from
	for n in items.size():
		i = (i + dir + items.size()) % items.size()
		if items[i].kind != "info":
			return i
	return -1


func _draw_page(page: String, items: Array, sel: int) -> void:
	_title(page)
	screen.put(2, 0, "╔" + "═".repeat(55) + "╦" + "═".repeat(22) + "╗", FG, BG)
	for r in range(3, 22):
		screen.put(r, 0, "║", FG, BG)
		screen.put(r, 56, "║", FG, BG)
		screen.put(r, 79, "║", FG, BG)
	screen.put(3, 63, "Item Help", FG, BG)
	screen.put(4, 57, "─".repeat(22), FG, BG)
	screen.put(5, 58, "Menu Level   ►", FG, BG)
	for i in mini(items.size(), 18):
		var it: Dictionary = items[i]
		var on := i == sel
		screen.put(3 + i, 2, str(it.label).rpad(26), ITEM if it.kind != "info" else FG, BG)
		screen.put(3 + i, 29, (it.value as Callable).call(), SEL_FG if on else FG, SEL_BG if on else BG)
	if sel >= 0:
		var help: PackedStringArray = str(items[sel].get("help", "")).split("\n")
		for i in help.size():
			screen.put(7 + i, 58, help[i], FG, BG)
	screen.put(22, 0, "╚" + "═".repeat(55) + "╩" + "═".repeat(22) + "╝", FG, BG)
	screen.put(23, 0, " ↑↓→←:Move  Enter:Select  +/-/PU/PD:Value  F10:Save  ESC:Exit".rpad(80), FG, BG)


## PgUp/PgDn (+/-): the next or previous value, a day or a minute.
func _step(item: Dictionary, dir: int) -> void:
	match item.kind:
		"choice":
			var options: PackedStringArray = item.options
			var current: String = str((item.value as Callable).call()).trim_prefix("[").trim_suffix("]")
			var i := options.find(current)
			(item.set as Callable).call(options[(i + dir + options.size()) % options.size()])
		"date":
			cmos.rtc_offset += 86400.0 * dir
		"time":
			cmos.rtc_offset += 60.0 * dir


## Enter on an item: the list of choices, or a date or time to type.
func _edit(item: Dictionary) -> void:
	match item.kind:
		"choice":
			var options: PackedStringArray = item.options
			var current: String = str((item.value as Callable).call()).trim_prefix("[").trim_suffix("]")
			var chosen: Variant = await _list(str(item.label), options, maxi(0, options.find(current)))
			if chosen != null:
				(item.set as Callable).call(chosen)
		"date", "time":
			var is_date: bool = item.kind == "date"
			var d := hw.clock.local_datetime(_rtc_now())
			var initial := "%02d/%02d/%04d" % [d.month, d.day, d.year] if is_date else "%02d:%02d:%02d" % [d.hour, d.minute, d.second]
			var prompt := "Date (mm/dd/yyyy): " if is_date else "Time (hh:mm:ss): "
			screen.box(10, 18, 3, 44, FG, SEL_BG)
			screen.put(11, 20, prompt, FG, SEL_BG)
			var typed: Variant = await screen.read_line(11, 20 + prompt.length(), initial, false, 10, FG, SEL_BG)
			if typed != null:
				_set_clock(str(typed), is_date)


## A pop-up list of [param options]; returns the one chosen or null.
func _list(title: String, options: PackedStringArray, sel: int) -> Variant:
	var width := maxi(title.length(), 16) + 6
	var left := (AgoraFwScreen.COLS - width) / 2
	var top := 8
	while screen.is_alive():
		screen.box(top, left, options.size() + 4, width, FG, SEL_BG)
		screen.put(top, left + (width - title.length() - 2) / 2, " %s " % title, FG, SEL_BG)
		for i in options.size():
			screen.fill(top + 2 + i, left + 2, width - 4, SEL_FG if i == sel else FG, BG if i == sel else SEL_BG, options[i])
		var k: String = await screen.key()
		match k:
			"up": sel = maxi(0, sel - 1)
			"down": sel = mini(options.size() - 1, sel + 1)
			"enter": return options[sel]
			"esc", "": return null
	return null


# --- the CMOS clock --------------------------------------------------------------

func _rtc_now() -> float:
	return hw.clock.now() + cmos.rtc_offset


func _date_text() -> String:
	var d := hw.clock.local_datetime(_rtc_now())
	return "%s, %s %d %d" % [["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.weekday], ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.month - 1], d.day, d.year]


func _time_text() -> String:
	var d := hw.clock.local_datetime(_rtc_now())
	return "%2d : %02d : %02d" % [d.hour, d.minute, d.second]


## Sets the CMOS clock from "mm/dd/yyyy" or "hh:mm:ss" (local time).
func _set_clock(text: String, is_date: bool) -> void:
	var d := hw.clock.local_datetime(_rtc_now())
	var parts := text.split("/" if is_date else ":")
	if parts.size() != 3:
		return
	for p in parts:
		if not p.strip_edges().is_valid_int():
			return
	var a := int(parts[0])
	var b := int(parts[1])
	var c := int(parts[2])
	if is_date:
		if a < 1 or a > 12 or b < 1 or b > 31 or c < 1980 or c > 2099:
			return
		d.month = a
		d.day = b
		d.year = c
	else:
		if a > 23 or b > 59 or c > 59:
			return
		d.hour = a
		d.minute = b
		d.second = c
	var local := Time.get_unix_time_from_datetime_dict(d)
	cmos.rtc_offset = float(local - hw.clock.tz_offset_minutes * 60) - hw.clock.now()
