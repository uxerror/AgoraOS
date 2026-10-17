extends AgoraProgram
## Runs an init script: "service sshd restart" is /etc/init.d/sshd restart.
## Under the systemd-style init it forwards to systemctl, like on modern
## distributions.


func summary() -> String:
	return "run an init script (start, stop, restart, status)"


func usage() -> String:
	return "usage: service NAME ACTION\n       service --status-all"


func main(p: AgoraProcess) -> int:
	var systemd := p.exists("/run/systemd/system")
	if p.argv.size() == 2 and p.argv[1] == "--status-all":
		for name in p.list_dir("/etc/init.d"):
			if name in ["rc", "rcS"] or name.begins_with("."):
				continue
			var code := await p.run(PackedStringArray(["/etc/init.d/" + name, "status"]), {"stdout": AgoraStream.discard(), "stderr": AgoraStream.discard()})
			p.outln(" [ %s ]  %s" % ["+" if code == 0 else "-", name])
		return 0
	if p.argv.size() < 3:
		return p.fail(usage(), 1)
	var name := p.argv[1]
	var action := p.argv[2]
	if systemd:
		return await p.run(PackedStringArray(["systemctl", action, name]))
	var script := "/etc/init.d/" + name
	if not p.exists(script):
		return p.fail("%s: unrecognized service" % name)
	return await p.run(PackedStringArray([script, action]))
