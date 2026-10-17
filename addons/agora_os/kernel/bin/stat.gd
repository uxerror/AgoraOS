extends AgoraProgram


func summary() -> String:
	return "show file metadata"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.is_empty():
		return p.fail("missing operand", 2)
	var status := 0
	var kinds := {
		AgoraStat.Type.FILE: "regular file", AgoraStat.Type.DIR: "directory",
		AgoraStat.Type.SYMLINK: "symbolic link", AgoraStat.Type.DEVICE: "character device",
	}
	for f in a.operands:
		var st := p.stat(f, false)
		if st == null:
			status = p.fail("cannot stat '%s': %s" % [f, AgoraErrno.describe(p.errno)])
			continue
		var users := p.machine.users
		p.outln("  File: %s%s" % [f, " -> " + p.read_link(f) if st.is_symlink() else ""])
		p.outln("  Size: %-10d Type: %s" % [st.size, kinds[st.type]])
		p.outln("Access: (%04d/%s)  Uid: (%5d/%8s)   Gid: (%5d/%8s)" % [
			int(AgoraStat.to_octal(st.mode)), st.mode_string(), st.uid, users.name_of(st.uid),
			st.gid, users.group_name_of(st.gid)])
		p.outln("Modify: %s" % p.machine.clock.format_long(st.mtime))
	return status
