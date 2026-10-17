extends AgoraProgram


func summary() -> String:
	return "print the environment or run a command in a modified one"


func usage() -> String:
	return "usage: env [NAME=value...] [command [args...]]"


func main(p: AgoraProcess) -> int:
	var env := p.env.duplicate()
	var i := 1
	while i < p.argv.size() and p.argv[i].contains("=") and not p.argv[i].begins_with("="):
		env[p.argv[i].get_slice("=", 0)] = p.argv[i].substr(p.argv[i].find("=") + 1)
		i += 1
	if i < p.argv.size():
		var child := p.spawn(p.argv.slice(i), {"env": env})
		if child == null:
			return p.fail("'%s': %s" % [p.argv[i], AgoraErrno.describe(p.errno)], 127)
		return await child.wait()
	var keys := env.keys()
	keys.sort()
	for k in keys:
		p.outln("%s=%s" % [k, env[k]])
	return 0
