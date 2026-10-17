extends AgoraProgram


func summary() -> String:
	return "print user and group ids"


func main(p: AgoraProcess) -> int:
	var users := p.machine.users
	var cred := p.cred
	if p.argv.size() > 1:
		cred = users.cred_for(p.argv[1])
		if cred == null:
			return p.fail("'%s': no such user" % p.argv[1])
	var groups: PackedStringArray = ["%d(%s)" % [cred.gid, users.group_name_of(cred.gid)]]
	for g in cred.groups:
		if g != cred.gid:
			groups.append("%d(%s)" % [g, users.group_name_of(g)])
	var line := "uid=%d(%s) gid=%d(%s)" % [cred.uid, users.name_of(cred.uid), cred.gid, users.group_name_of(cred.gid)]
	if cred.ruid != cred.uid:
		line = "uid=%d(%s) euid=%d(%s) gid=%d(%s)" % [cred.ruid, users.name_of(cred.ruid), cred.uid,
			users.name_of(cred.uid), cred.gid, users.group_name_of(cred.gid)]
	p.outln(line + " groups=" + ",".join(groups))
	return 0
