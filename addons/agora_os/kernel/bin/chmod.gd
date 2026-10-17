extends AgoraProgram


func summary() -> String:
	return "change file permissions"


func usage() -> String:
	return "usage: chmod [-R] mode file...\nmode is octal (755) or symbolic ([ugoa]*[+-=][rwxst]*, comma separated, e.g. u+x,go-w)"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	var recursive := false
	if not args.is_empty() and args[0] == "-R":
		recursive = true
		args.remove_at(0)
	if args.size() < 2:
		return p.fail("missing operand", 2)
	var spec := args[0]
	var status := 0
	for f in args.slice(1):
		if not _apply(p, spec, f, recursive):
			status = 1
	return status


func _apply(p: AgoraProcess, spec: String, path: String, recursive: bool) -> bool:
	var st := p.stat(path)
	if st == null:
		p.fail("cannot access '%s': %s" % [path, AgoraErrno.describe(p.errno)])
		return false
	var mode := compute_mode(spec, st.mode, st.is_dir())
	if mode < 0:
		p.fail("invalid mode: '%s'" % spec)
		return false
	var ok := true
	if p.chmod(path, mode) != AgoraErrno.OK:
		p.fail("changing permissions of '%s': %s" % [path, AgoraErrno.describe(p.errno)])
		ok = false
	if recursive and st.is_dir():
		for n in p.list_dir(path):
			ok = _apply(p, spec, AgoraPath.join(path, n), true) and ok
	return ok


## New mode for [param spec] applied to [param mode], or -1 if invalid.
static func compute_mode(spec: String, mode: int, is_dir: bool) -> int:
	var octal := AgoraStat.parse_octal(spec)
	if octal >= 0:
		return octal
	for clause in spec.split(","):
		var i := 0
		var who := 0
		while i < clause.length() and "ugoa".contains(clause[i]):
			match clause[i]:
				"u": who |= 2496 # 0o4700
				"g": who |= 1080 # 0o2070
				"o": who |= 7 # 0o007
				"a": who |= 4095
			i += 1
		if who == 0:
			who = 4095
		if i >= clause.length() or not "+-=".contains(clause[i]):
			return -1
		var op := clause[i]
		i += 1
		var bits := 0
		while i < clause.length():
			match clause[i]:
				"r": bits |= 292 # 0o444
				"w": bits |= 146 # 0o222
				"x": bits |= 73 # 0o111
				"X": bits |= 73 if is_dir or mode & 73 else 0
				"s": bits |= AgoraStat.S_ISUID | AgoraStat.S_ISGID
				"t": bits |= AgoraStat.S_ISVTX
				_: return -1
			i += 1
		bits &= who | (AgoraStat.S_ISVTX if who == 4095 or who & 7 else 0)
		match op:
			"+": mode |= bits
			"-": mode &= ~bits
			"=": mode = (mode & ~who) | bits
	return mode & AgoraStat.PERM_MASK
