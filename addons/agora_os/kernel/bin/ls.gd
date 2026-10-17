extends AgoraProgram

const COLUMNS := 80


func summary() -> String:
	return "list directory contents"


func usage() -> String:
	return "usage: ls [-1aAdlF] [file...]\n  -a  include names starting with '.'\n  -A  like -a, without . and ..\n  -d  list directories themselves\n  -l  long format\n  -F  mark directories with '/' and executables with '*'\n  -1  one name per line"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if not a.error.is_empty():
		return p.fail(a.error, 2)
	var targets := a.operands if not a.operands.is_empty() else PackedStringArray(["."])
	var status := 0
	var files: PackedStringArray = []
	var dirs: PackedStringArray = []
	for t in targets:
		var st := p.stat(t, not a.has("l") or t.ends_with("/"))
		if st == null:
			st = p.stat(t, false)
		if st == null:
			p.fail("cannot access '%s': %s" % [t, AgoraErrno.describe(p.errno)])
			status = 2
			continue
		if st.is_dir() and not a.has("d"):
			dirs.append(t)
		else:
			files.append(t)
	if not files.is_empty():
		_print_entries(p, a, files, "")
	for i in dirs.size():
		var d := dirs[i]
		if targets.size() > 1:
			if i > 0 or not files.is_empty():
				p.outln()
			p.outln(d + ":")
		var names := p.list_dir(d)
		if p.errno != AgoraErrno.OK:
			p.fail("cannot open directory '%s': %s" % [d, AgoraErrno.describe(p.errno)])
			status = 2
			continue
		var shown: PackedStringArray = []
		if a.has("a"):
			shown.append_array([".", ".."])
		for n in names:
			if n.begins_with(".") and not (a.has("a") or a.has("A")):
				continue
			shown.append(n)
		_print_entries(p, a, shown, d)
	return status


func _print_entries(p: AgoraProcess, a: AgoraArgs, names: PackedStringArray, dir: String) -> void:
	var labels: PackedStringArray = []
	var rows: Array = []
	for n in names:
		var path := n if dir.is_empty() else AgoraPath.join(dir, n)
		var st := p.stat(path, false)
		var label := n
		if st and a.has("F"):
			if st.is_dir():
				label += "/"
			elif st.is_symlink():
				label += "@"
			elif st.mode & 73:
				label += "*"
		if a.has("l") and st:
			if st.is_symlink():
				label += " -> " + p.read_link(path)
			rows.append([st.mode_string(), "1", p.machine.users.name_of(st.uid),
				p.machine.users.group_name_of(st.gid), str(st.size),
				p.machine.clock.format_short(st.mtime), label])
		else:
			labels.append(label)
	if a.has("l"):
		var widths := [0, 0, 0, 0, 0]
		for r: Array in rows:
			for c in 5:
				widths[c] = maxi(widths[c], (r[c] as String).length())
		for r: Array in rows:
			p.outln("%s %s %s %s %s %s %s" % [r[0], (r[1] as String).lpad(widths[1]),
				(r[2] as String).rpad(widths[2]), (r[3] as String).rpad(widths[3]),
				(r[4] as String).lpad(widths[4]), r[5], r[6]])
		return
	if labels.is_empty():
		return
	if a.has("1") or not is_terminal(p):
		for l in labels:
			p.outln(l)
		return
	var width := 0
	for l in labels:
		width = maxi(width, l.length())
	width += 2
	var per_line := maxi(1, COLUMNS / width)
	var line := ""
	for i in labels.size():
		line += labels[i].rpad(width) if (i + 1) % per_line != 0 and i != labels.size() - 1 else labels[i]
		if (i + 1) % per_line == 0 or i == labels.size() - 1:
			p.outln(line.strip_edges(false, true))
			line = ""
