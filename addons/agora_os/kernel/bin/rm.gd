extends AgoraProgram


func summary() -> String:
	return "remove files or directories"


func usage() -> String:
	return "usage: rm [-rf] file...\n  -r  remove directories and their contents\n  -f  ignore missing files, never complain"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var recursive := a.has("r") or a.has("R")
	var force := a.has("f")
	if a.operands.is_empty():
		return 0 if force else p.fail("missing operand", 2)
	var status := 0
	for f in a.operands:
		var st := p.stat(f, false)
		if st == null:
			if not force:
				status = p.fail("cannot remove '%s': %s" % [f, AgoraErrno.describe(p.errno)])
			continue
		if AgoraPath.normalize(f, p.cwd) == "/":
			status = p.fail("refusing to remove '/'")
			continue
		if st.is_dir():
			if not recursive:
				status = p.fail("cannot remove '%s': Is a directory" % f)
				continue
			if not await _remove_tree(p, f):
				status = 1
		elif p.unlink(f) != AgoraErrno.OK:
			status = p.fail("cannot remove '%s': %s" % [f, AgoraErrno.describe(p.errno)])
	return status


func _remove_tree(p: AgoraProcess, path: String) -> bool:
	var ok := true
	for n in p.list_dir(path):
		await p.tick()
		var child := AgoraPath.join(path, n)
		var st := p.stat(child, false)
		if st == null:
			continue
		if st.is_dir():
			ok = await _remove_tree(p, child) and ok
		elif p.unlink(child) != AgoraErrno.OK:
			p.fail("cannot remove '%s': %s" % [child, AgoraErrno.describe(p.errno)])
			ok = false
	if p.rmdir(path) != AgoraErrno.OK:
		p.fail("cannot remove '%s': %s" % [path, AgoraErrno.describe(p.errno)])
		return false
	return ok
