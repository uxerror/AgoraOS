extends AgoraProgram


func summary() -> String:
	return "make symbolic links"


func usage() -> String:
	return "usage: ln -s target link_name"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if not a.has("s"):
		return p.fail("hard links are not supported, use -s")
	if a.operands.is_empty():
		return p.fail("missing file operand", 2)
	var target := a.operands[0]
	var link := a.operands[1] if a.operands.size() > 1 else AgoraPath.basename(target)
	if p.is_dir(link):
		link = AgoraPath.join(link, AgoraPath.basename(target))
	if a.has("f") and p.stat(link, false) != null:
		p.unlink(link)
	if p.symlink(target, link) != AgoraErrno.OK:
		return p.fail("failed to create symbolic link '%s': %s" % [link, AgoraErrno.describe(p.errno)])
	return 0
