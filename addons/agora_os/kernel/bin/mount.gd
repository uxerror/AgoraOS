extends AgoraProgram


func summary() -> String:
	return "mount a disk, or list mounted file systems"


func usage() -> String:
	return "usage: mount                 list mounts\n       mount DEVICE DIR      e.g. mount /dev/sr0 /media/cdrom"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
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
	return 0
