extends AgoraProgram


func summary() -> String:
	return "translate or delete characters"


func usage() -> String:
	return "usage: tr [-d] set1 [set2]\nSets may use ranges like a-z."


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.is_empty() or (not a.has("d") and a.operands.size() < 2):
		return p.fail("missing operand", 2)
	var set1 := _expand(a.operands[0])
	var set2 := _expand(a.operands[1]) if a.operands.size() > 1 else ""
	var text := await p.read_all()
	var out := ""
	for c in text:
		var idx := set1.find(c)
		if idx < 0:
			out += c
		elif not a.has("d"):
			out += set2[mini(idx, set2.length() - 1)]
	p.out(out)
	return 0


func _expand(s: String) -> String:
	s = s.replace("\\n", "\n").replace("\\t", "\t")
	var out := ""
	var i := 0
	while i < s.length():
		if i + 2 < s.length() and s[i + 1] == "-":
			for code in range(s.unicode_at(i), s.unicode_at(i + 2) + 1):
				out += String.chr(code)
			i += 3
			continue
		out += s[i]
		i += 1
	return out
