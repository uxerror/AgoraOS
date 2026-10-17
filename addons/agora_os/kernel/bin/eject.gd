extends AgoraProgram


func summary() -> String:
	return "eject removable media"


func main(p: AgoraProcess) -> int:
	if not p.cred.is_root():
		return p.fail("only root can do that", 1)
	var hw := p.machine.hardware
	var disk := hw.find_device(p.argv[1]) if p.argv.size() > 1 else hw.media(AgoraDisk.Kind.CDROM)
	if disk == null or not disk.removable:
		return p.fail("unable to find or open the device", 1)
	if disk == p.machine.root_disk:
		return p.fail("the running system lives on it", 1)
	hw.eject(disk)
	p.machine._sync_devices()
	return 0
