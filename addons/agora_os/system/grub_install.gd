extends AgoraProgram
## grub-install: puts the GRUB boot loader on a disk. Copies the stage
## files of the grub package to /boot/grub (under --root-directory), writes
## a device map if there is none and stage1 into the disk's boot sector
## (see [AgoraGrub]).

var p: AgoraProcess


func summary() -> String:
	return "install GRUB on a disk"


func usage() -> String:
	return "Usage: grub-install [--root-directory=DIR] INSTALL_DEVICE\n\nINSTALL_DEVICE can be a GRUB device name, like (hd0), or a system device\nfilename, like /dev/sda."


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv)
	if a.has("help") or a.has("h"):
		p.outln(usage())
		return 0
	if a.operands.size() != 1:
		p.errln("grub-install: no install device specified.")
		return p.fail(usage(), 1)
	if not p.cred.is_root():
		return p.fail("grub-install: must be run as root", 1)
	var hw := p.machine.hardware
	var dir := str(a.value("root-directory", "")).trim_suffix("/")
	var grub_dir := dir + AgoraGrub.BOOT_DIR
	var disk := _device(hw, a.operands[0])
	if disk == null:
		return p.fail("%s: Not found or not a block device." % a.operands[0], 1)
	if disk.read_only or not disk.kind in [AgoraDisk.Kind.HDD, AgoraDisk.Kind.USB]:
		return p.fail("grub-install: cannot write the boot sector of /dev/%s: Read-only file system" % hw.device_name(disk), 1)
	p.make_dirs(grub_dir)
	for s in AgoraGrub.STAGES:
		var src := AgoraGrub.STAGE_DIR + "/" + s
		if not p.exists(src):
			return p.fail("%s: Not found." % src, 1)
		if p.write_bytes(grub_dir + "/" + s, p.read_bytes(src)) != AgoraErrno.OK:
			return p.fail("grub-install: cannot write %s/%s: %s" % [grub_dir, s, AgoraErrno.describe(p.machine.vfs.errno)], 1)
	p.outln("Searching for GRUB installation directory ... found: " + grub_dir)
	var map_path := grub_dir + "/device.map"
	if not p.exists(map_path):
		p.write_text(map_path, _device_map(hw))
	disk.boot_sector = "grub"
	p.outln("Installation finished. No error reported.")
	p.outln("This is the contents of the device map %s." % map_path)
	p.outln("Check if this is correct or not. If any of the lines is incorrect,")
	p.outln("fix it and re-run the script `grub-install'.\n")
	p.out(p.read_text(map_path))
	return 0


## "/dev/sda", "sda1", "(hd0)" or "hd0" -> the disk.
func _device(hw: AgoraHardware, name: String) -> AgoraDisk:
	var bare := name.trim_prefix("(").trim_suffix(")").get_slice(",", 0)
	if bare.begins_with("hd") and bare.substr(2).is_valid_int():
		var n := int(bare.substr(2))
		var disks := _hard_disks(hw)
		return disks[n] if n < disks.size() else null
	return hw.find_device(name)


func _hard_disks(hw: AgoraHardware) -> Array[AgoraDisk]:
	var out: Array[AgoraDisk] = []
	for d in hw.disks:
		if d.kind in [AgoraDisk.Kind.HDD, AgoraDisk.Kind.USB]:
			out.append(d)
	return out


func _device_map(hw: AgoraHardware) -> String:
	var text := ""
	var disks := _hard_disks(hw)
	for i in disks.size():
		text += "(hd%d)\t/dev/%s\n" % [i, hw.device_name(disks[i])]
	return text
