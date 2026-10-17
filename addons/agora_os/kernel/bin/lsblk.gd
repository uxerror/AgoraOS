extends AgoraProgram


func summary() -> String:
	return "list disks"


func main(p: AgoraProcess) -> int:
	var hw := p.machine.hardware
	p.outln("NAME        SIZE RO TYPE MOUNTPOINT")
	for d in hw.disks:
		var name := hw.device_name(d)
		var type := "rom" if d.kind == AgoraDisk.Kind.CDROM else "disk"
		var part := hw.fs_device_name(d)
		var mounted := p.machine.vfs.mount_point_of(d.fs) if d.fs else ""
		p.outln("%-10s %5s  %d %-4s %s" % [name, d.size_text(), int(d.read_only), type, mounted if part == name else ""])
		if part != name and d.is_formatted():
			p.outln("%-10s %5s  %d %-4s %s" % ["`-" + part, d.size_text(), int(d.read_only), "part", mounted])
	return 0
