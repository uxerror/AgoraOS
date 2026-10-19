class_name AgoraMedia
extends RefCounted
## Ready-made removable media.


## A bootable AgoraOS install CD (or USB stick with [param usb]): a live
## system that runs the installer on every console, plus an archive of
## every package (dists/ and pool/, see [AgoraArchive]).
static func installer(usb: bool = false, clock: AgoraClock = null) -> AgoraDisk:
	var kind := AgoraDisk.Kind.USB if usb else AgoraDisk.Kind.CDROM
	var disk := AgoraDisk.make(kind, "AgoraOS %s install %s" % [AgoraDistro.VERSION, "USB" if usb else "CD"], 650)
	disk.label = "AGORA_" + AgoraDistro.VERSION.replace(".", "")
	disk.read_only = false
	disk.format()
	var vfs := AgoraInstaller.target_vfs(disk, clock)
	AgoraInstaller.install_target(vfs, "agora-live", {"profile": "live", "motd": "AgoraOS install CD\n"})
	var root := AgoraCred.root()
	AgoraArchive.write(vfs, "", AgoraDistro.all_packages(), AgoraArchive.SUITE, AgoraArchive.COMPONENT, "AgoraOS")
	disk.read_only = not usb
	disk.fs.read_only = disk.read_only
	return disk


## An empty USB stick.
static func usb_stick(capacity_mb: int = 256) -> AgoraDisk:
	var disk := AgoraDisk.make(AgoraDisk.Kind.USB, "USB Flash Drive %dM" % capacity_mb, capacity_mb)
	disk.format()
	return disk
