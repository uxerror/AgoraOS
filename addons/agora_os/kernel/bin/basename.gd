extends AgoraProgram


func summary() -> String:
	return "strip directory (and suffix) from a path"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail("missing operand", 2)
	var name := AgoraPath.basename(p.argv[1])
	if p.argv.size() > 2 and name.ends_with(p.argv[2]) and name != p.argv[2]:
		name = name.substr(0, name.length() - p.argv[2].length())
	p.outln(name)
	return 0
