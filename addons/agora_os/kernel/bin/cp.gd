extends AgoraProgram


func summary() -> String:
	return "copy files and directories"


func usage() -> String:
	return "usage: cp [-r] source... dest\nCopies into dest, or into the directory dest when there are several sources.\n  -r  copy directories recursively"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.size() < 2:
		return p.fail("missing file operand", 2)
	var recursive := a.has("r") or a.has("R")
	var sources := a.operands.slice(0, a.operands.size() - 1)
	var dest := a.operands[-1]
	var dest_is_dir := p.is_dir(dest)
	if sources.size() > 1 and not dest_is_dir:
		return p.fail("target '%s' is not a directory" % dest)
	var status := 0
	for src in sources:
		var st := p.stat(src)
		if st == null:
			status = p.fail("cannot stat '%s': %s" % [src, AgoraErrno.describe(p.errno)])
			continue
		var target := AgoraPath.join(dest, AgoraPath.basename(src)) if dest_is_dir else dest
		if st.is_dir():
			if not recursive:
				status = p.fail("-r not specified; omitting directory '%s'" % src)
				continue
			var src_abs := p.realpath(src)
			if AgoraPath.is_inside(AgoraPath.normalize(target, p.cwd), src_abs):
				status = p.fail("cannot copy a directory, '%s', into itself" % src)
				continue
			if not await copy_tree(p, src, target):
				status = 1
		elif not copy_file(p, src, target, st):
			status = 1
	return status


static func copy_file(p: AgoraProcess, src: String, dst: String, st: AgoraStat) -> bool:
	var data := p.read_bytes(src)
	if p.errno != AgoraErrno.OK:
		p.fail("cannot open '%s' for reading: %s" % [src, AgoraErrno.describe(p.errno)])
		return false
	if p.write_bytes(dst, data, false, st.mode) != AgoraErrno.OK:
		p.fail("cannot create '%s': %s" % [dst, AgoraErrno.describe(p.errno)])
		return false
	return true


static func copy_tree(p: AgoraProcess, src: String, dst: String) -> bool:
	var st := p.stat(src)
	if not p.is_dir(dst) and p.mkdir(dst, st.mode) != AgoraErrno.OK:
		p.fail("cannot create directory '%s': %s" % [dst, AgoraErrno.describe(p.errno)])
		return false
	var ok := true
	for n in p.list_dir(src):
		await p.tick()
		var s := AgoraPath.join(src, n)
		var d := AgoraPath.join(dst, n)
		var cst := p.stat(s, false)
		if cst == null:
			continue
		if cst.is_symlink():
			ok = p.symlink(p.read_link(s), d) == AgoraErrno.OK and ok
		elif cst.is_dir():
			ok = await copy_tree(p, s, d) and ok
		elif cst.is_file():
			ok = copy_file(p, s, d, cst) and ok
	return ok
