extends AgoraProgram
## update-grub: writes the kernel entries of /boot/grub/menu.lst from the
## kernels in /boot, keeping the rest of the file (see [AgoraGrub]). -y
## creates a missing menu.lst without asking.

var p: AgoraProcess


func summary() -> String:
	return "update the GRUB boot menu from the kernels in /boot"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv)
	if not p.cred.is_root():
		return p.fail("update-grub: must be run as root", 1)
	p.out("Searching for GRUB installation directory ... ")
	if not p.is_dir(AgoraGrub.BOOT_DIR):
		p.outln("\n\nCould not find GRUB installation directory. Run grub-install first.")
		return 1
	p.outln("found: " + AgoraGrub.BOOT_DIR)
	p.out("Testing for an existing GRUB menu.lst file ... ")
	var old := ""
	if p.exists(AgoraGrub.MENU):
		p.outln("found: " + AgoraGrub.MENU)
		old = p.read_text(AgoraGrub.MENU)
	else:
		p.outln("\n\nCould not find %s file." % AgoraGrub.MENU)
		if not a.has("y"):
			p.out("Would you like %s generated for you? (y/N) " % AgoraGrub.MENU)
			var answer: Variant = await p.read_line()
			if answer == null or not str(answer).strip_edges().to_lower().begins_with("y"):
				return 1
		p.outln("Generating %s" % AgoraGrub.MENU)
	var vfs := p.machine.vfs
	var kernels := AgoraGrub.kernels(vfs)
	for v in kernels:
		p.outln("Found kernel: /boot/vmlinuz-" + v)
	var root_device := vfs.get_source("/")
	if root_device.is_empty() or not root_device.begins_with("/dev/"):
		root_device = "/dev/sda1"
	p.out("Updating %s ... " % AgoraGrub.MENU)
	if p.write_text(AgoraGrub.MENU, AgoraGrub.menu_text(old, kernels, root_device, vfs)) != AgoraErrno.OK:
		p.outln()
		return p.fail("update-grub: cannot write %s: %s" % [AgoraGrub.MENU, AgoraErrno.describe(vfs.errno)], 1)
	p.outln("done\n")
	return 0
