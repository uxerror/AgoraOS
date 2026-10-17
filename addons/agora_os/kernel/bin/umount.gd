extends AgoraProgram


func summary() -> String:
	return "unmount a file system"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail("usage: umount DIR", 1)
	if not p.cred.is_root():
		return p.fail("only root can do that", 1)
	var target := p.abspath(p.argv[1])
	var hw := p.machine.hardware
	var disk := hw.find_device(p.argv[1]) if hw else null
	if disk and disk.fs:
		target = p.machine.vfs.mount_point_of(disk.fs)
	if target in ["/", "/proc", "/dev", "/run", "/sys"]:
		return p.fail("%s: target is busy" % target, 32)
	if p.machine.vfs.unmount(target) != AgoraErrno.OK:
		return p.fail("%s: not mounted" % p.argv[1], 32)
	return 0
