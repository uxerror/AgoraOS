extends AgoraProgram
## Installed setuid root: the spool directory is private. Files to install
## are read with the caller's own permissions.


func summary() -> String:
	return "install, list or remove a user's cron table"


func usage() -> String:
	return "usage: crontab [-u user] file | -   install from a file (or stdin)\n       crontab [-u user] -l | -r       list | remove"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "u")
	var users := p.machine.users
	var caller := users.name_of(p.cred.ruid)
	var user := a.value("u", caller)
	if user != caller and p.cred.ruid != 0:
		return p.fail("must be privileged to use -u")
	if users.find(user).is_empty():
		return p.fail("user '%s' unknown" % user)
	var path := "/var/spool/cron/crontabs/" + user
	if a.has("l"):
		var text := p.read_text(path)
		if p.errno != AgoraErrno.OK:
			p.errln("no crontab for " + user)
			return 1
		p.out(text)
		return 0
	if a.has("r"):
		if p.unlink(path) != AgoraErrno.OK:
			p.errln("no crontab for " + user)
			return 1
		return 0
	if a.operands.is_empty():
		return p.fail(usage(), 1)
	var source := a.operands[0]
	var text := ""
	if source == "-":
		text = await p.read_all()
	else:
		text = p.machine.vfs.read_text(users.cred_for(caller), source, p.cwd)
		if p.machine.vfs.errno != AgoraErrno.OK:
			return p.fail("%s: %s" % [source, AgoraErrno.describe(p.machine.vfs.errno)])
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.is_empty() or l.begins_with("#") or l.contains("=") and not l.contains(" "):
			continue
		if not l.begins_with("@") and l.split(" ", false).size() < 6:
			p.errln("errors in crontab file, can't install.")
			return 1
	p.make_dirs("/var/spool/cron/crontabs", AgoraStat.MODE_PRIVATE_DIR)
	p.write_text(path, text, false, AgoraStat.MODE_PRIVATE_FILE)
	var u := users.find(user)
	p.chown(path, u.uid, u.gid)
	return 0
