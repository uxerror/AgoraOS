class_name AgoraGrub
extends RefCounted
## GRUB legacy (0.97), the boot loader PCs of the 2000s started from.
##
## Its first stage lives in the disk's boot sector ([member AgoraDisk.
## boot_sector] is "grub" after grub-install or the GRUB command "setup"),
## the rest in /boot/grub on the disk. It reads /boot/grub/menu.lst:
##
## [codeblock]
## default   0
## timeout   5
## title     AgoraOS, kernel 0.1.0
## root      (hd0,0)
## kernel    /boot/vmlinuz-0.1.0 root=/dev/sda1 ro
## [/codeblock]
##
## and runs the commands of the chosen entry. "kernel" names the kernel
## file and its command line, "boot" starts it. Drives are numbered as the
## BIOS sees them: (hd0) is the disk GRUB was loaded from, partitions count
## from 0, so (hd0,0) is sda1 when booting from sda. Without a menu.lst it
## gives its command line.
##
## The firmware creates one of these per boot. [method boot_default] picks
## the default entry at once (no screen to look at); the interactive menu,
## the entry editor and the command line are in [AgoraGrubMenu]. An entry
## changed in the editor has "edited" set.

const VERSION := "0.97"
## Where the grub package keeps its stage files; grub-install copies them
## to /boot/grub.
const STAGE_DIR := "/usr/lib/grub/i386-pc"
const BOOT_DIR := "/boot/grub"
const MENU := "/boot/grub/menu.lst"
const STAGES: PackedStringArray = ["stage1", "stage2", "e2fs_stage1_5"]
const STAGE_FILES := {
	"stage1": "GRUB stage1 0.97: the boot sector loader\n",
	"stage2": "GRUB stage2 0.97: the boot loader proper\n",
	"e2fs_stage1_5": "GRUB stage1.5 0.97 for ext2 file systems\n",
}
const BEGIN_LIST := "### BEGIN AUTOMAGIC KERNELS LIST"
const END_LIST := "### END DEBIAN AUTOMAGIC KERNELS LIST"
const COMMANDS: PackedStringArray = [
	"boot", "cat", "color", "default", "displaymem", "find", "halt", "help", "hiddenmenu", "initrd",
	"kernel", "makeactive", "password", "reboot", "root", "rootnoverify", "savedefault", "setup", "timeout", "title",
]

var hw: AgoraHardware
## Drives in BIOS order: the boot disk first, then the other hard disks
## and USB sticks.
var drives: Array[AgoraDisk] = []
## Prints on the screen.
var out: Callable
## The parsed menu.lst, see [method parse_menu]; empty without one.
var menu := {}

# The session: what root, kernel and initrd have set so far.
var _root := 0
var _root_part := 0
var _kernel := {}
var _initrd := ""


func _init(p_hw: AgoraHardware, boot_drive: AgoraDisk, p_out: Callable) -> void:
	hw = p_hw
	out = p_out
	drives.append(boot_drive)
	for d in hw.disks:
		if d != boot_drive and d.kind in [AgoraDisk.Kind.HDD, AgoraDisk.Kind.USB]:
			drives.append(d)


## Stage 1 found stage 2 and the menu? Prints what GRUB prints while it
## loads and returns "" if it could go on, else the error that stopped it.
func load() -> String:
	var disk := drives[0]
	if disk.fs == null:
		return "GRUB Hard Disk Error"
	out.call("GRUB Loading stage1.5.\n\nGRUB loading, please wait...\n")
	if disk.fs.lstat(BOOT_DIR.trim_prefix("/") + "/stage2") == null:
		return "Error 15"
	var text := _read(disk, MENU)
	menu = parse_menu(text) if text != null else {}
	reset()
	return ""


## Forgets root, kernel and initrd, as before each menu entry.
func reset() -> void:
	_root = 0
	_root_part = 0
	_kernel = {}
	_initrd = ""


## Lower and upper memory in KB, as GRUB reports them.
func memory_text() -> String:
	return "640K lower / %dK upper memory" % maxi(0, (hw.ram_mb - 1) * 1024)


## Boots the default entry without asking. Returns {disk, cmdline} for the
## firmware to start the kernel with, or {} if GRUB stopped (no menu, an
## error, halt).
func boot_default() -> Dictionary:
	var entries: Array = menu.get("entries", [])
	if entries.is_empty():
		out.call("\n    GNU GRUB  version %s  (%s)\n\n [ Minimal BASH-like line editing is supported.  For the first word, TAB\n   lists possible command completions.  Anywhere else TAB lists the possible\n   completions of a device/filename. ]\n\ngrub> " % [VERSION, memory_text()])
		return {}
	var index: int = clampi(menu.get("default", 0), 0, entries.size() - 1)
	return run_entry(entries[index])


## Runs the commands of a menu entry as GRUB does when it is chosen, and a
## "boot" after them. Returns {disk, cmdline}, {"reboot": true}, or {}
## after an error (printed).
func run_entry(entry: Dictionary) -> Dictionary:
	reset()
	out.call("\n  Booting command-list\n\n" if entry.get("edited", false) else "\n  Booting '%s'\n\n" % entry.title)
	var lines: PackedStringArray = entry.lines
	for line in lines:
		out.call(line + "\n")
		var r := execute(line)
		if r.has("error"):
			out.call("\n%s\n" % r.error)
			return {}
		if r.has("boot") or r.has("reboot") or r.has("halt"):
			return r
	var r := execute("boot")
	if r.has("error"):
		out.call("\n%s\n" % r.error)
		return {}
	return r


## Runs one command line. Returns {} when done, {error}, {boot: true, disk,
## cmdline}, {reboot: true} or {halt: true}.
func execute(line: String) -> Dictionary:
	var words := split_command(line)
	if words.is_empty():
		return {}
	var cmd := words[0]
	var args := words[1]
	match cmd:
		"root", "rootnoverify":
			var dev := parse_device(args.get_slice(" ", 0))
			if dev.has("error"):
				return dev
			if dev.part < 0:
				return {"error": "Error 11: Unrecognized device string"}
			if cmd == "root":
				var disk := drives[dev.drive]
				if disk.fs == null:
					return {"error": "Error 17: Cannot mount selected partition"}
				out.call(" Filesystem type is %s, partition type 0x83\n" % disk.fs.fs_type())
			_root = dev.drive
			_root_part = dev.part
			return {}
		"kernel":
			var file := args.get_slice(" ", 0)
			while file.begins_with("--"):
				args = args.substr(file.length()).strip_edges()
				file = args.get_slice(" ", 0)
			var found := _find_file(file)
			if found.has("error"):
				return found
			var data: PackedByteArray = found.data
			if not data.get_string_from_utf8().begins_with("Agora kernel"):
				return {"error": "Error 13: Invalid or unsupported executable format"}
			_kernel = {"disk": found.disk, "cmdline": args.substr(file.length()).strip_edges()}
			_initrd = ""
			out.call("   [Linux-bzImage, setup=0x1e00, size=0x%x]\n" % (0x16d000 + data.size() * 97 % 0x1000))
			return {}
		"initrd":
			if _kernel.is_empty():
				return {"error": "Error 8: Kernel must be loaded before booting"}
			var found := _find_file(args.get_slice(" ", 0))
			if found.has("error"):
				return found
			_initrd = args.get_slice(" ", 0)
			out.call("   [Linux-initrd @ 0x1fc6c000, 0x%x bytes]\n" % (found.data as PackedByteArray).size())
			return {}
		"boot":
			if _kernel.is_empty():
				return {"error": "Error 8: Kernel must be loaded before booting"}
			return {"boot": true, "disk": _kernel.disk, "cmdline": _kernel.cmdline}
		"reboot":
			return {"reboot": true}
		"halt":
			return {"halt": true}
		"cat":
			var found := _find_file(args.get_slice(" ", 0))
			if found.has("error"):
				return found
			out.call((found.data as PackedByteArray).get_string_from_utf8())
			return {}
		"find":
			var path := args.get_slice(" ", 0)
			if not path.begins_with("/"):
				return {"error": "Error 1: Filename must be either an absolute pathname or blocklist"}
			var any := false
			for i in drives.size():
				if _read(drives[i], path) != null:
					out.call(" (hd%d,0)\n" % i)
					any = true
			return {} if any else {"error": "Error 15: File not found"}
		"setup":
			return _setup(args.get_slice(" ", 0))
		"displaymem":
			out.call(" EISA Memory BIOS Interface is present\n Address Map BIOS Interface is present\n Lower memory: 640K, Upper memory (to first chipset hole): %dK\n" % maxi(0, (hw.ram_mb - 1) * 1024))
			return {}
		"help":
			out.call(help_text())
			return {}
		"savedefault", "makeactive", "color", "default", "timeout", "hiddenmenu", "password", "title":
			return {}
	return {"error": "Error 27: Unrecognized command"}


func help_text() -> String:
	var text := ""
	var col := 0
	for c in COMMANDS:
		text += c.rpad(19)
		col += 1
		if col % 4 == 0:
			text += "\n"
	return text + "\n"


## GRUB's "setup (hd0)": writes stage1 into the drive's boot sector, using
## the stage files in /boot/grub of the current root.
func _setup(arg: String) -> Dictionary:
	var dev := parse_device(arg)
	if dev.has("error"):
		return dev
	var root_disk := drives[_root]
	if root_disk.fs == null:
		return {"error": "Error 17: Cannot mount selected partition"}
	for s in STAGES:
		var there := _read(root_disk, BOOT_DIR + "/" + s) != null
		out.call(" Checking if \"%s/%s\" exists... %s\n" % [BOOT_DIR, s, "yes" if there else "no"])
		if not there:
			return {"error": "Error 15: File not found"}
	var target := drives[dev.drive]
	out.call(" Running \"embed %s/e2fs_stage1_5 (hd%d)\"...  15 sectors are embedded.\nsucceeded\n" % [BOOT_DIR, dev.drive])
	out.call(" Running \"install %s/stage1 (hd%d) (hd%d)1+15 p (hd%d,%d)%s/stage2 %s\"... succeeded\nDone.\n" % [BOOT_DIR, dev.drive, dev.drive, _root, _root_part, BOOT_DIR, MENU])
	target.boot_sector = "grub"
	return {}


## "(hd0,0)" -> {drive: 0, part: 0}; "(hd1)" -> {drive: 1, part: -1}; or
## {error}.
func parse_device(text: String) -> Dictionary:
	if not text.begins_with("(") or not text.contains(")"):
		return {"error": "Error 11: Unrecognized device string"}
	var inner := text.substr(1, text.find(")") - 1)
	var parts := inner.split(",")
	if not parts[0].begins_with("hd"):
		return {"error": "Error 21: Selected disk does not exist"} if parts[0].begins_with("fd") else {"error": "Error 11: Unrecognized device string"}
	var num := parts[0].substr(2)
	if not num.is_valid_int():
		return {"error": "Error 11: Unrecognized device string"}
	var drive := int(num)
	if drive < 0 or drive >= drives.size():
		return {"error": "Error 21: Selected disk does not exist"}
	if parts.size() < 2:
		return {"drive": drive, "part": -1}
	if not parts[1].is_valid_int():
		return {"error": "Error 11: Unrecognized device string"}
	if int(parts[1]) != 0 or drives[drive].fs == null:
		return {"error": "Error 22: No such partition"}
	return {"drive": drive, "part": 0}


## A file named as GRUB names it: "/boot/vmlinuz" on the current root, or
## "(hd0,0)/boot/vmlinuz". Returns {disk, data} or {error}.
func _find_file(spec: String) -> Dictionary:
	var drive := _root
	var path := spec
	if spec.begins_with("("):
		var dev := parse_device(spec)
		if dev.has("error"):
			return dev
		drive = dev.drive
		path = spec.substr(spec.find(")") + 1)
	if not path.begins_with("/"):
		return {"error": "Error 1: Filename must be either an absolute pathname or blocklist"}
	var disk := drives[drive]
	if disk.fs == null:
		return {"error": "Error 17: Cannot mount selected partition"}
	var data: Variant = _read_bytes(disk, path)
	if data == null:
		return {"error": "Error 15: File not found"}
	return {"disk": disk, "data": data}


func _read_bytes(disk: AgoraDisk, path: String) -> Variant:
	if disk.fs == null:
		return null
	var vfs := AgoraInstaller.target_vfs(disk, hw.clock)
	var root := AgoraCred.root()
	if not vfs.exists(root, path) or vfs.is_dir(root, path):
		return null
	return vfs.read_file(root, path)


func _read(disk: AgoraDisk, path: String) -> Variant:
	var data: Variant = _read_bytes(disk, path)
	return (data as PackedByteArray).get_string_from_utf8() if data != null else null


# --- menu.lst ------------------------------------------------------------------

## A command line split into its name and the rest: "kernel /boot/x ro"
## -> ["kernel", "/boot/x ro"]. GRUB also takes "timeout=5". Comments and
## empty lines give [].
static func split_command(line: String) -> PackedStringArray:
	var s := line.strip_edges()
	if s.is_empty() or s.begins_with("#"):
		return PackedStringArray()
	var cut := s.length()
	for sep in [" ", "\t", "="]:
		var i := s.find(sep)
		if i >= 0 and i < cut:
			cut = i
	return PackedStringArray([s.substr(0, cut), s.substr(cut + 1).strip_edges() if cut < s.length() else ""])


## Reads menu.lst: {default, timeout (-1 without one), hidden, color
## [normal, highlight], password, entries: [{title, lines}]}.
static func parse_menu(text: String) -> Dictionary:
	var m := {"default": 0, "timeout": -1, "hidden": false, "color": PackedStringArray(), "password": "", "entries": []}
	var entry: Dictionary = {}
	for raw in text.split("\n"):
		var words := split_command(raw)
		if words.is_empty():
			continue
		if words[0] == "title":
			entry = {"title": words[1], "lines": PackedStringArray()}
			(m.entries as Array).append(entry)
			continue
		if not entry.is_empty():
			var lines: PackedStringArray = entry.lines
			lines.append(raw.strip_edges())
			entry.lines = lines
			continue
		match words[0]:
			"default":
				m.default = int(words[1]) if words[1].is_valid_int() else 0
			"timeout":
				m.timeout = int(words[1]) if words[1].is_valid_int() else -1
			"hiddenmenu":
				m.hidden = true
			"color":
				m.color = words[1].split(" ", false)
			"password":
				m.password = words[1]
	return m


## The kernels in /boot of [param vfs], newest first ("0.1.0", ...).
static func kernels(vfs: AgoraVfs) -> PackedStringArray:
	var out: Array[String] = []
	var root := AgoraCred.root()
	for name in vfs.list_dir(root, "/boot"):
		var st := vfs.stat(root, "/boot/" + name, "/", false)
		if name.begins_with("vmlinuz-") and st != null and st.is_file():
			out.append(name.substr(8))
	out.sort_custom(func(a: String, b: String) -> bool: return AgoraArchive.compare_versions(a, b) > 0)
	return PackedStringArray(out)


## A new menu.lst, or [param old] with its automagic kernel list rewritten
## from [param kernel_versions]. The default options between the markers
## (kopt, groot, alternative, defoptions, altoptions) are kept; new files
## get kopt "root=[param root_device] ro".
static func menu_text(old: String, kernel_versions: PackedStringArray, root_device: String, vfs: AgoraVfs = null) -> String:
	if old.is_empty():
		old = _new_menu(root_device)
	elif not old.contains(BEGIN_LIST):
		# A menu of one's own: the automagic list goes after it.
		var fresh := _new_menu(root_device)
		old = old.trim_suffix("\n") + "\n\n" + fresh.substr(fresh.find(BEGIN_LIST))
	var head := old.substr(0, old.find(BEGIN_LIST))
	var after := old.substr(old.find(BEGIN_LIST))
	var tail := ""
	if after.contains(END_LIST):
		tail = after.substr(after.find(END_LIST) + END_LIST.length()).trim_prefix("\n")
	var opts := {"kopt": "root=%s ro" % root_device, "groot": "(hd0,0)", "alternative": "true", "defoptions": "", "altoptions": []}
	var options_block := ""
	for line in after.split("\n").slice(1):
		if line.begins_with("title") or line.begins_with(END_LIST):
			break # a list without the options block
		options_block += line + "\n"
		if line.begins_with("# ") and line.contains("="):
			var kv := line.substr(2)
			var key := kv.substr(0, kv.find("="))
			var value := kv.substr(kv.find("=") + 1)
			if key == "altoptions":
				(opts.altoptions as Array).append(value)
			elif opts.has(key):
				opts[key] = value
		if line.begins_with("## ## End Default Options ##"):
			break
	if (opts.altoptions as Array).is_empty():
		opts.altoptions = ["(single-user mode) single"]
	var text := head + BEGIN_LIST + "\n" + options_block + "\n"
	var root := AgoraCred.root()
	for v in kernel_versions:
		var initrd := ""
		if vfs and vfs.exists(root, "/boot/initrd.img-" + v):
			initrd = "initrd\t\t/boot/initrd.img-%s\n" % v
		var kopt := str(opts.kopt)
		var defo := str(opts.defoptions)
		text += _entry("AgoraOS, kernel " + v, opts.groot, "/boot/vmlinuz-%s %s%s" % [v, kopt, (" " + defo) if not defo.is_empty() else ""], initrd)
		if opts.alternative == "true":
			for alt: String in opts.altoptions:
				var suffix := alt.substr(0, alt.find(")") + 1) if alt.begins_with("(") else ""
				var extra := alt.substr(suffix.length()).strip_edges()
				text += _entry("AgoraOS, kernel %s %s" % [v, suffix], opts.groot, "/boot/vmlinuz-%s %s %s" % [v, kopt, extra], initrd)
	return text + END_LIST + "\n" + tail


static func _entry(title: String, groot: String, kernel: String, initrd: String) -> String:
	return "title\t\t%s\nroot\t\t%s\nkernel\t\t%s\n%ssavedefault\n\n" % [title, groot, kernel.strip_edges(), initrd]


static func _new_menu(root_device: String) -> String:
	return """# menu.lst: the boot menu of GRUB (see grub(8) and update-grub(8)).
# update-grub rewrites the kernel entries between the AUTOMAGIC markers
# below; everything else in this file is left as it is.

## default num
# The entry booted when nobody chooses, counted from 0.
default		0

## timeout sec
# Seconds to wait before booting the default entry.
timeout		5

# Colours of the menu: normal, then highlighted.
color cyan/blue white/blue

## password passwd
# A password here locks the entry editor and the command line until it
# is given (press 'p' in the menu).
# password topsecret

%s
## update-grub rewrites the lines between the markers, except the options
## below, which it reads. They stay comments: edit them, don't uncomment.

## ## Start Default Options ##
## kernel options of every entry
# kopt=root=%s ro

## the GRUB root device of the entries
# groot=(hd0,0)

## whether to add the alternative entries (altoptions)
# alternative=true

## options of the main entry only
# defoptions=

## alternative entries: (title suffix) options; one line each
# altoptions=(single-user mode) single

## ## End Default Options ##

%s
""" % [BEGIN_LIST, root_device, END_LIST]


# --- installing ----------------------------------------------------------------

## Puts GRUB on [param disk], whose file system [param vfs] is (the
## installed system): the stage files into /boot/grub, a device map and,
## if there is none, a menu.lst for the kernels in /boot; then stage1 into
## the boot sector. [param root_device] goes into the kernel lines
## ("/dev/sda1"). Returns "" or an error.
static func install_on(disk: AgoraDisk, vfs: AgoraVfs, root_device: String, device_map: String = "") -> String:
	var err := configure(vfs, root_device, device_map)
	if err.is_empty():
		disk.boot_sector = "grub"
	return err


## The file side of [method install_on]: stage files, device map, menu.lst.
static func configure(vfs: AgoraVfs, root_device: String, device_map: String = "") -> String:
	var root := AgoraCred.root()
	var err := install_files(vfs)
	if not err.is_empty():
		return err
	if not device_map.is_empty() or not vfs.exists(root, BOOT_DIR + "/device.map"):
		vfs.write_text(root, BOOT_DIR + "/device.map", device_map if not device_map.is_empty() else "(hd0)\t%s\n" % root_device.rstrip("0123456789"))
	if not vfs.exists(root, MENU):
		vfs.write_text(root, MENU, menu_text("", kernels(vfs), root_device, vfs))
	return ""


## Copies the stage files from the grub package to /boot/grub.
static func install_files(vfs: AgoraVfs) -> String:
	var root := AgoraCred.root()
	vfs.make_dirs(root, BOOT_DIR)
	for s in STAGES:
		var src := STAGE_DIR + "/" + s
		if not vfs.exists(root, src):
			return "%s: Not found" % src
		vfs.write_file(root, BOOT_DIR + "/" + s, vfs.read_file(root, src))
	return ""


## The files of the grub package.
static func package_files() -> Dictionary:
	var files := {}
	for s in STAGES:
		files[STAGE_DIR + "/" + s] = [STAGE_FILES[s], AgoraStat.MODE_FILE]
	return files


# --- passwords -----------------------------------------------------------------

const ITOA64 := "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


## Does [param given] match a "password" line's value: "secret", or
## "--md5 $1$salt$hash" as grub-md5-crypt makes it?
static func check_password(spec: String, given: String) -> bool:
	spec = spec.strip_edges()
	if spec.begins_with("--md5"):
		var hash := spec.substr(5).strip_edges().get_slice(" ", 0)
		var parts := hash.split("$")
		return parts.size() >= 4 and md5_crypt(given, parts[2]) == hash
	return spec.get_slice(" ", 0) == given


## The MD5-based crypt(3) of FreeBSD and glibc ("$1$"), which GRUB uses.
static func md5_crypt(password: String, salt: String) -> String:
	salt = salt.left(8)
	var pw := password.to_utf8_buffer()
	var sb := salt.to_utf8_buffer()
	var magic := "$1$".to_utf8_buffer()
	var alt := _md5(pw + sb + pw)
	var ctx := pw + magic + sb
	var n := pw.size()
	while n > 0:
		ctx.append_array(alt.slice(0, mini(16, n)))
		n -= 16
	n = pw.size()
	while n > 0:
		ctx.append(0 if n & 1 else (pw[0] if not pw.is_empty() else 0))
		n >>= 1
	var final := _md5(ctx)
	for i in 1000:
		var c := PackedByteArray()
		c.append_array(pw if i & 1 else final)
		if i % 3:
			c.append_array(sb)
		if i % 7:
			c.append_array(pw)
		c.append_array(final if i & 1 else pw)
		final = _md5(c)
	var out := ""
	for g in [[0, 6, 12], [1, 7, 13], [2, 8, 14], [3, 9, 15], [4, 10, 5]]:
		out += _to64((final[g[0]] << 16) | (final[g[1]] << 8) | final[g[2]], 4)
	out += _to64(final[11], 2)
	return "$1$%s$%s" % [salt, out]


static func _md5(data: PackedByteArray) -> PackedByteArray:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_MD5)
	h.update(data)
	return h.finish()


static func _to64(v: int, n: int) -> String:
	var s := ""
	for i in n:
		s += ITOA64[v & 0x3f]
		v >>= 6
	return s
