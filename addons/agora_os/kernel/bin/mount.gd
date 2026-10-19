extends AgoraProgram


func summary() -> String:
	return "mount a disk, or list mounted file systems"


func usage() -> String:
	return "usage: mount                       list mounts\n       mount [-o ro] DEVICE DIR    e.g. mount /dev/sr0 /media/cdrom\n       mount -o remount,rw DIR     make a mounted file system writable again"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "ot")
	var options := str(a.value("o")).split(",", false) if a.has("o") else PackedStringArray()
	if options.has("remount"):
		return _remount(p, a, options)
	if a.operands.is_empty():
		for line in lines_of(p.read_text("/proc/mounts")):
			var f := line.split(" ")
			p.outln("%s on %s type %s (%s)" % [f[0], f[1], f[2], f[3]])
		return 0
	if a.operands.size() != 2:
		return p.fail(usage(), 1)
	if not p.cred.is_root():
		return p.fail("only root can do that", 1)
	if p.machine.mount_device(a.operands[0], p.abspath(a.operands[1])) != AgoraErrno.OK:
		var e := p.machine.errno
		var why := "wrong fs type, bad option, or the device has no file system" if e == AgoraErrno.EINVAL else AgoraErrno.describe(e)
		return p.fail("%s: %s" % [a.operands[0], why], 32)
	if options.has("ro"):
		p.machine.vfs.get_mount(p.abspath(a.operands[1])).read_only = true
	return 0


## -o remount,ro / -o remount,rw on a mounted file system ("/" or its
## device).
func _remount(p: AgoraProcess, a: AgoraArgs, options: PackedStringArray) -> int:
	if a.operands.size() != 1:
		return p.fail(usage(), 1)
	if not p.cred.is_root():
		return p.fail("only root can do that", 1)
	var vfs := p.machine.vfs
	var point := ""
	var target := a.operands[0]
	for mp in vfs.mount_points():
		if mp == AgoraPath.normalize(p.abspath(target)) or vfs.get_source(mp) == target:
			point = mp
	if point.is_empty():
		return p.fail("%s not mounted already, or bad option" % target, 32)
	var fs := vfs.get_mount(point)
	if options.has("rw"):
		var disk := _disk_of(p, fs)
		if (disk and disk.read_only) or fs is AgoraSysFs:
			return p.fail("cannot remount block device %s read-write, is write-protected" % vfs.get_source(point), 32)
		fs.read_only = false
	elif options.has("ro"):
		fs.read_only = true
	return 0


func _disk_of(p: AgoraProcess, fs: AgoraFs) -> AgoraDisk:
	var hw := p.machine.hardware
	if hw:
		for d in hw.disks:
			if d.fs == fs:
				return d
	return null
