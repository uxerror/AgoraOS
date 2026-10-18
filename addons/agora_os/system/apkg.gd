extends AgoraProgram
## The package manager. Packages are .pkg files (JSON) in the repository
## directories listed in /etc/apkg/repositories, such as /repo on the
## install CD. Installed packages are recorded in /var/lib/apkg.


func summary() -> String:
	return "install, remove and inspect packages"


func usage() -> String:
	return """usage: apkg list [--available]
       apkg info PACKAGE
       apkg files PACKAGE
       apkg install PACKAGE...
       apkg remove PACKAGE..."""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	var command := a.operands[0] if not a.operands.is_empty() else ""
	var names := a.operands.slice(1)
	var vfs := p.machine.vfs
	var installed := AgoraPackages.installed(vfs)
	match command:
		"list":
			if a.has("available"):
				var repo := _repository(p)
				var keys := repo.keys()
				keys.sort()
				for n in keys:
					p.outln("%-18s %-8s %s%s" % [n, repo[n].version, repo[n].description, "  [installed]" if installed.has(n) else ""])
				if repo.is_empty():
					p.errln("apkg: no repository found (see /etc/apkg/repositories)")
				return 0
			var keys := installed.keys()
			keys.sort()
			for n in keys:
				p.outln("%-18s %s" % [n, installed[n]])
			return 0
		"info":
			if names.is_empty():
				return p.fail(usage(), 1)
			var info := AgoraPackages.control_of(vfs, names[0])
			if info.is_empty():
				info = _repository(p).get(names[0], {})
			if info.is_empty():
				return p.fail("package '%s' not found" % names[0], 1)
			p.outln("Package: %s\nVersion: %s\nStatus: %s\nDepends: %s\nDescription: %s" % [
				info.name, info.version, "installed" if installed.has(names[0]) else "not installed",
				", ".join(info.get("depends", [])), info.get("description", "")])
			return 0
		"files":
			if names.is_empty() or not installed.has(names[0]):
				return p.fail("package '%s' is not installed" % (names[0] if not names.is_empty() else ""), 1)
			for f in AgoraPackages.files_of(vfs, names[0]):
				p.outln(f)
			return 0
		"install":
			if not p.cred.is_root():
				return p.fail("you must be root to install packages", 1)
			var repo := _repository(p)
			for n in names:
				if not repo.has(n):
					return p.fail("unable to locate package %s" % n, 1)
			var lookup := func(n: String) -> Dictionary: return repo.get(n, {})
			var count := 0
			for pkg in AgoraPackages.resolve(names, lookup):
				if installed.has(pkg.name) and not names.has(pkg.name):
					continue
				p.outln("Installing %s (%s)..." % [pkg.name, pkg.version])
				AgoraPackages.install(vfs, pkg)
				count += 1
				await p.tick()
			p.outln("%d package(s) installed." % count)
			_reload_inetd(p)
			return 0
		"remove":
			if not p.cred.is_root():
				return p.fail("you must be root to remove packages", 1)
			for n in names:
				if not installed.has(n):
					return p.fail("package '%s' is not installed" % n, 1)
				for other: String in installed:
					if other != n and not names.has(other) and AgoraPackages.control_of(vfs, other).get("depends", []).has(n):
						return p.fail("cannot remove %s: %s depends on it" % [n, other], 1)
			for n in names:
				p.outln("Removing %s..." % n)
				AgoraPackages.remove(vfs, n)
			_reload_inetd(p)
			return 0
	return p.fail(usage(), 1)


## Services may have come or gone from /etc/inetd.conf: a running inetd
## rereads it on SIGHUP.
func _reload_inetd(p: AgoraProcess) -> void:
	for pid in p.machine.list_pids():
		var other := p.machine.get_process(pid)
		if other and other.name == "inetd":
			p.machine.kill(pid, AgoraProcess.SIGHUP, p.cred)


## Every package in the configured repositories: name -> package.
func _repository(p: AgoraProcess) -> Dictionary:
	var out := {}
	for line in p.read_text("/etc/apkg/repositories").split("\n", false):
		var dir := line.strip_edges()
		if dir.is_empty() or dir.begins_with("#"):
			continue
		for f in p.list_dir(dir):
			if f.ends_with(".pkg"):
				var pkg := AgoraPackages.from_json(p.read_text(dir + "/" + f))
				if not pkg.is_empty() and not out.has(pkg.name):
					out[pkg.name] = pkg
	return out
