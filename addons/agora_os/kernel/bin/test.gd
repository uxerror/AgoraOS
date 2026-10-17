extends AgoraProgram
## Also installed as "[". Supports the common file and string tests.


func summary() -> String:
	return "evaluate a condition"


func usage() -> String:
	return "usage: test expr | [ expr ]\n  -e/-f/-d/-L/-r/-w/-x/-s file, -z/-n string,\n  a = b, a != b, n -eq/-ne/-lt/-le/-gt/-ge m, ! expr"


func main(p: AgoraProcess) -> int:
	var args := p.argv.slice(1)
	if AgoraPath.basename(p.argv[0]) == "[":
		if args.is_empty() or args[-1] != "]":
			return p.fail("missing ']'", 2)
		args.remove_at(args.size() - 1)
	var negate := false
	while not args.is_empty() and args[0] == "!":
		negate = not negate
		args.remove_at(0)
	var result := _eval(p, args)
	if result < 0:
		return 2
	return int(bool(result) == negate)


func _eval(p: AgoraProcess, a: PackedStringArray) -> int:
	match a.size():
		0:
			return 0
		1:
			return int(not a[0].is_empty())
		2:
			var f := a[1]
			match a[0]:
				"-z": return int(f.is_empty())
				"-n": return int(not f.is_empty())
				"-L", "-h":
					var lst := p.stat(f, false)
					return int(lst != null and lst.is_symlink())
			var st := p.stat(f)
			match a[0]:
				"-e": return int(st != null)
				"-f": return int(st != null and st.is_file())
				"-d": return int(st != null and st.is_dir())
				"-s": return int(st != null and st.size > 0)
				"-r": return int(st != null and AgoraVfs.can_access(p.cred, st, AgoraStat.R))
				"-w": return int(st != null and AgoraVfs.can_access(p.cred, st, AgoraStat.W))
				"-x": return int(st != null and AgoraVfs.can_access(p.cred, st, AgoraStat.X))
		3:
			var l := a[0]
			var r := a[2]
			match a[1]:
				"=", "==": return int(l == r)
				"!=": return int(l != r)
			if not l.is_valid_int() or not r.is_valid_int():
				p.fail("integer expression expected")
				return -1
			var x := int(l)
			var y := int(r)
			match a[1]:
				"-eq": return int(x == y)
				"-ne": return int(x != y)
				"-lt": return int(x < y)
				"-le": return int(x <= y)
				"-gt": return int(x > y)
				"-ge": return int(x >= y)
	p.fail("unsupported expression")
	return -1
