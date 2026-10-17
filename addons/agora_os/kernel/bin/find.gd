extends AgoraProgram


func summary() -> String:
	return "search for files in a directory tree"


func usage() -> String:
	return "usage: find [path...] [-name pattern] [-type f|d|l] [-user name] [-perm mode] [-maxdepth n]"


func main(p: AgoraProcess) -> int:
	var roots: PackedStringArray = []
	var args := p.argv.slice(1)
	while not args.is_empty() and not args[0].begins_with("-"):
		roots.append(args[0])
		args.remove_at(0)
	if roots.is_empty():
		roots.append(".")
	var filters := {}
	var i := 0
	while i < args.size():
		var key := args[i]
		if i + 1 >= args.size() or key not in ["-name", "-type", "-maxdepth", "-user", "-perm"]:
			return p.fail("unknown or incomplete predicate '%s'" % key, 2)
		filters[key] = args[i + 1]
		i += 2
	var status := 0
	for r in roots:
		var st := p.stat(r, false)
		if st == null:
			status = p.fail("'%s': %s" % [r, AgoraErrno.describe(p.errno)])
			continue
		if not await _walk(p, r, st, filters, 0):
			status = 1
	return status


func _walk(p: AgoraProcess, path: String, st: AgoraStat, filters: Dictionary, depth: int) -> bool:
	await p.tick()
	if _matches(p, path, st, filters):
		if not p.outln(path):
			return false
	if not st.is_dir() or (filters.has("-maxdepth") and depth >= int(filters["-maxdepth"])):
		return true
	var names := p.list_dir(path)
	if p.errno != AgoraErrno.OK:
		p.fail("'%s': %s" % [path, AgoraErrno.describe(p.errno)])
		return false
	var ok := true
	for n in names:
		var child := AgoraPath.join(path, n)
		var cst := p.stat(child, false)
		if cst != null:
			ok = await _walk(p, child, cst, filters, depth + 1) and ok
	return ok


func _matches(p: AgoraProcess, path: String, st: AgoraStat, filters: Dictionary) -> bool:
	if filters.has("-name") and not AgoraPath.basename(path).match(filters["-name"]):
		return false
	if filters.has("-type"):
		var t: String = filters["-type"]
		if (t == "f" and not st.is_file()) or (t == "d" and not st.is_dir()) or (t == "l" and not st.is_symlink()):
			return false
	if filters.has("-user") and p.machine.users.name_of(st.uid) != filters["-user"]:
		return false
	if filters.has("-perm"):
		var spec: String = filters["-perm"]
		var want := AgoraStat.parse_octal(spec.trim_prefix("-"))
		if spec.begins_with("-"):
			if st.mode & want != want:
				return false
		elif st.mode & AgoraStat.PERM_MASK != want:
			return false
	return true
