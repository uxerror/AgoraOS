extends AgoraProgram
## procps sysctl: reads and changes kernel settings in /proc/sys.
## net.ipv4.ip_forward is /proc/sys/net/ipv4/ip_forward.

const ROOT := "/proc/sys/"


func summary() -> String:
	return "configure kernel parameters at runtime"


func usage() -> String:
	return """
Usage:
 sysctl [options] [variable[=value] ...]

Options:
  -a, --all            display all variables
  -n, --values         print only values of the given variable(s)
  -p, --load[=<file>]  read values from file
  -q, --quiet          do not echo variable set
  -w, --write          enable writing a value to variable"""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var values_only := a.has("n") or a.has("values")
	var quiet := a.has("q") or a.has("quiet")
	if a.has("a") or a.has("A") or a.has("all"):
		for key in _all(p, ROOT.trim_suffix("/")):
			_show(p, key, values_only)
		return 0
	if a.has("p") or a.has("load"):
		var file := a.operands[0] if not a.operands.is_empty() else "/etc/sysctl.conf"
		if not p.exists(file):
			p.errln("sysctl: cannot open \"%s\": No such file or directory" % file)
			return 255
		var status := 0
		for line in p.read_text(file).split("\n"):
			line = line.strip_edges()
			if line.is_empty() or line.begins_with("#") or line.begins_with(";") or not line.contains("="):
				continue
			if _write_key(p, line.get_slice("=", 0).strip_edges(), line.get_slice("=", 1).strip_edges(), quiet, values_only) != 0:
				status = 255
		return status
	if a.operands.is_empty():
		p.errln(usage())
		return 255
	var status := 0
	for op in a.operands:
		if op.contains("="):
			if _write_key(p, op.get_slice("=", 0), op.substr(op.find("=") + 1), quiet, values_only) != 0:
				status = 255
		elif a.has("w") or a.has("write"):
			p.errln("sysctl: \"%s\" must be of the form name=value" % op)
			status = 255
		elif _show(p, op, values_only) != 0:
			status = 255
	return status


static func _path(key: String) -> String:
	return ROOT + key.replace(".", "/")


func _show(p: AgoraProcess, key: String, values_only: bool) -> int:
	var path := _path(key)
	if p.stat(path) == null:
		p.errln("sysctl: cannot stat %s: No such file or directory" % path)
		return 1
	var value := p.read_text(path).strip_edges()
	p.outln(value if values_only else "%s = %s" % [key, value])
	return 0


func _write_key(p: AgoraProcess, key: String, value: String, quiet: bool, values_only: bool) -> int:
	var path := _path(key)
	if p.stat(path) == null:
		p.errln("sysctl: cannot stat %s: No such file or directory" % path)
		return 1
	var code := p.write_text(path, value + "\n")
	if code == AgoraErrno.EACCES:
		p.errln("sysctl: permission denied on key '%s'" % key)
		return 1
	if code != AgoraErrno.OK:
		p.errln("sysctl: setting key \"%s\": %s" % [key, AgoraErrno.describe(code)])
		return 1
	if not quiet:
		p.outln(value if values_only else "%s = %s" % [key, value])
	return 0


func _all(p: AgoraProcess, dir: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for name in p.list_dir(dir):
		var path := dir + "/" + name
		var st := p.stat(path)
		if st and st.is_dir():
			out.append_array(_all(p, path))
		elif st:
			out.append(path.trim_prefix(ROOT).replace("/", "."))
	return out
