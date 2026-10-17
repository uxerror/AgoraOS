extends AgoraProgram


func summary() -> String:
	return "change file owner and group"


func usage() -> String:
	return "usage: chown [-R] owner[:group] file..."


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var recursive := false
	if not args.is_empty() and args[0] == "-R":
		recursive = true
		args.remove_at(0)
	if args.size() < 2:
		return p.fail("missing operand", 2)
	var spec := args[0]
	var owner := spec.get_slice(":", 0)
	var group := spec.get_slice(":", 1) if spec.contains(":") else ""
	var uid := -1
	var gid := -1
	if not owner.is_empty():
		var u := p.machine.users.find(owner)
		if u.is_empty() and not owner.is_valid_int():
			return p.fail("invalid user: '%s'" % owner)
		uid = u.uid if not u.is_empty() else int(owner)
	if not group.is_empty():
		var g := p.machine.users.find_group(group)
		if g.is_empty() and not group.is_valid_int():
			return p.fail("invalid group: '%s'" % group)
		gid = g.gid if not g.is_empty() else int(group)
	var status := 0
	for f in args.slice(1):
		if not _apply(p, f, uid, gid, recursive):
			status = 1
	return status


func _apply(p: AgoraProcess, path: String, uid: int, gid: int, recursive: bool) -> bool:
	if p.chown(path, uid, gid) != AgoraErrno.OK:
		p.fail("changing ownership of '%s': %s" % [path, AgoraErrno.describe(p.errno)])
		return false
	var ok := true
	if recursive and p.is_dir(path):
		for n in p.list_dir(path):
			ok = _apply(p, AgoraPath.join(path, n), uid, gid, true) and ok
	return ok
