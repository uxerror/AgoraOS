extends AgoraProgram
## Creates a file system on a disk, erasing it. Disks have a single
## partition, so "mkfs /dev/sda" creates /dev/sda1.


func summary() -> String:
	return "create a file system (erases the disk)"


func usage() -> String:
	return "usage: mkfs DEVICE"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail(usage(), 1)
	if not p.cred.is_root():
		return p.fail("only root can do that", 1)
	var hw := p.machine.hardware
	var disk := hw.find_device(p.argv[1])
	if disk == null:
		return p.fail("%s: No such device" % p.argv[1], 1)
	if disk.read_only:
		return p.fail("%s: Read-only device" % p.argv[1], 1)
	if disk.fs and not p.machine.vfs.mount_point_of(disk.fs).is_empty():
		return p.fail("%s is mounted; will not make a filesystem here!" % p.argv[1], 1)
	disk.format()
	p.machine._sync_devices()
	p.outln("Creating filesystem on /dev/%s (%s)... done" % [hw.fs_device_name(disk), disk.size_text()])
	return 0
