extends AgoraProgram

const Cp := preload("cp.gd")


func summary() -> String:
	return "move or rename files"


func usage() -> String:
	return "usage: mv source... dest\nRenames source to dest, or moves sources into the directory dest."


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.size() < 2:
		return p.fail("missing file operand", 2)
	var sources := a.operands.slice(0, a.operands.size() - 1)
	var dest := a.operands[-1]
	var dest_is_dir := p.is_dir(dest)
	if sources.size() > 1 and not dest_is_dir:
		return p.fail("target '%s' is not a directory" % dest)
	var status := 0
	for src in sources:
		var target := AgoraPath.join(dest, AgoraPath.basename(src)) if dest_is_dir else dest
		var e := p.rename(src, target)
		if e == AgoraErrno.EXDEV:
			# Different file systems: copy, then delete the original.
			var st := p.stat(src)
			var ok := false
			if st.is_dir():
				ok = await Cp.copy_tree(p, src, target)
			else:
				ok = Cp.copy_file(p, src, target, st)
			if ok:
				await p.run(PackedStringArray(["rm", "-rf", src]))
				continue
			status = 1
		elif e != AgoraErrno.OK:
			status = p.fail("cannot move '%s' to '%s': %s" % [src, target, AgoraErrno.describe(e)])
	return status
