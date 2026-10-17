extends AgoraProgram


func summary() -> String:
	return "create a user account"


func usage() -> String:
	return "usage: useradd [-G group,...] [-s shell] [-d home] name\nSet a password afterwards with passwd."


func main(p: AgoraProcess) -> int:
	if not p.cred.is_root():
		return p.fail("Permission denied.")
	var a := AgoraArgs.parse(p.argv, "Gsdc")
	if not a.error.is_empty() or a.operands.size() != 1:
		return p.fail(a.error if not a.error.is_empty() else usage(), 2)
	var opts := {}
	if a.has("G"):
		opts["groups"] = Array(a.value("G").split(",", false))
	if a.has("s"):
		opts["shell"] = a.value("s")
	if a.has("d"):
		opts["home"] = a.value("d")
	var uid := p.machine.users.add_user(a.operands[0], "", opts)
	if uid < 0:
		return p.fail("cannot create user '%s': %s" % [a.operands[0], AgoraErrno.describe(-uid)])
	# New accounts start locked until passwd sets a password.
	var rows := p.read_text(AgoraUsers.SHADOW)
	p.write_text(AgoraUsers.SHADOW, rows.replace("\n%s:\n" % a.operands[0], "\n%s:!\n" % a.operands[0]))
	return 0
