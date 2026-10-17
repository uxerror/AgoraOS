extends AgoraProgram
## Shows the journal written by the systemd-style init.


func summary() -> String:
	return "query the systemd journal"


func usage() -> String:
	return "usage: journalctl [-u unit] [-t identifier] [-n lines] [-f]\n  -f  keep printing new entries (Ctrl+C to stop)"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "untp", PackedStringArray(["unit", "lines", "identifier"]))
	if not a.error.is_empty():
		return p.fail(a.error, 1)
	var unit := a.value("u", a.value("unit"))
	var ident := a.value("t", a.value("identifier"))
	var count := int(a.value("n", a.value("lines", "-1")))
	var text := p.read_text(AgoraUnits.JOURNAL)
	if p.errno == AgoraErrno.EACCES:
		p.outln("Hint: You are currently not seeing messages from other users and the system.")
		p.outln("      Users in group 'adm' can see all messages. Pass -q to")
		p.outln("      turn off this notice.")
		return 1
	if p.errno != AgoraErrno.OK:
		p.outln("-- No entries --")
		return 0
	var lines := _filter(lines_of(text), unit, ident)
	if count >= 0:
		lines = lines.slice(maxi(0, lines.size() - count))
	if lines.is_empty():
		p.outln("-- No entries --")
	for l in lines:
		if not p.outln(l):
			return 0
	if not a.has("f"):
		return 0
	var seen := text.length()
	while p.is_running():
		await p.sleep(0.5)
		var now := p.read_text(AgoraUnits.JOURNAL)
		if now.length() > seen:
			for l in _filter(lines_of(now.substr(seen)), unit, ident):
				p.outln(l)
		seen = now.length()
	return 0


static func _filter(lines: PackedStringArray, unit: String, ident: String) -> PackedStringArray:
	if unit.is_empty() and ident.is_empty():
		return lines
	var name := AgoraUnits.normalize(unit) if not unit.is_empty() else ""
	var tag := name.trim_suffix(".service") if not name.is_empty() else ident
	var out: PackedStringArray = []
	for l in lines:
		if l.contains(" %s[" % tag) or (not name.is_empty() and l.contains(" " + name)):
			out.append(l)
	return out
