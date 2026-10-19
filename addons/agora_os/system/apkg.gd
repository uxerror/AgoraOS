extends AgoraProgram
## The package manager, in the manner of apt-get, apt-cache and dpkg.
##
## /etc/apkg/sources.list names the archives (see [AgoraArchive]), one per
## line: "apkg URI SUITE COMPONENT..." where URI is file:/path, http://...
## or ftp://... . "apkg update" downloads their indexes into
## /var/lib/apkg/lists; "apkg install" picks the newest version of each
## package (or NAME=VERSION), pulls in what it depends on, downloads the
## .pkg files into /var/cache/apkg/archives, checks their size and MD5 sum
## against the index and installs them. What is installed is recorded in
## /var/lib/apkg (see [AgoraPackages]).

const SOURCES := "/etc/apkg/sources.list"
const LISTS := "/var/lib/apkg/lists"
const CACHE := "/var/cache/apkg/archives"
const HOLD := "/var/lib/apkg/hold"
const AGENT := "apkg/%s" % AgoraDistro.VERSION

var p: AgoraProcess
var _yes := false


func summary() -> String:
	return "install, remove and inspect packages"


func usage() -> String:
	return """usage: apkg update
       apkg install [-y] PACKAGE[=VERSION]... | FILE.pkg...
       apkg upgrade | dist-upgrade [-y]
       apkg remove | purge PACKAGE...
       apkg hold | unhold PACKAGE...
       apkg policy [PACKAGE...]
       apkg list [--available]
       apkg search WORD
       apkg show PACKAGE
       apkg info PACKAGE
       apkg files PACKAGE
       apkg clean"""


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv)
	_yes = a.has("y") or a.has("yes") or a.has("assume-yes")
	var command := a.operands[0] if not a.operands.is_empty() else ""
	var names := a.operands.slice(1)
	var vfs := p.machine.vfs
	var installed := AgoraPackages.installed(vfs)
	match command:
		"update":
			if not _root_check():
				return 100
			return await update()
		"install":
			if not _root_check():
				return 100
			if names.is_empty():
				p.outln("0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.")
				return 0
			return await install(names)
		"upgrade", "dist-upgrade":
			if not _root_check():
				return 100
			return await upgrade(command == "dist-upgrade")
		"remove", "purge":
			if not _root_check():
				return 100
			return await _remove(names, installed, command == "purge")
		"hold", "unhold":
			if not _root_check():
				return 100
			var held := holds()
			for n in names:
				if command == "hold" and not held.has(n):
					held.append(n)
					p.outln("%s set on hold." % n)
				elif command == "unhold" and held.has(n):
					held.remove_at(held.find(n))
					p.outln("Canceled hold on %s." % n)
			p.write_text(HOLD, "\n".join(held) + ("\n" if not held.is_empty() else ""))
			return 0
		"policy":
			_policy(names, installed)
			return 0
		"clean":
			if not _root_check():
				return 100
			for f in p.list_dir(CACHE):
				if f.ends_with(".pkg"):
					p.unlink(CACHE + "/" + f)
			return 0
		"list":
			if a.has("available"):
				var cands := candidates()
				var keys := cands.keys()
				keys.sort()
				for n in keys:
					var e: Dictionary = cands[n]
					p.outln("%-18s %-8s %s%s" % [n, e.Version, e.get("Description", ""), "  [installed]" if installed.has(n) else ""])
				if cands.is_empty():
					p.errln("apkg: no package lists; run \"apkg update\" (see %s)" % SOURCES)
				return 0
			if a.has("upgradable"):
				var cands := candidates()
				var keys := installed.keys()
				keys.sort()
				for n: String in keys:
					if cands.has(n) and AgoraArchive.compare_versions(cands[n].Version, installed[n]) > 0:
						p.outln("%-18s %s -> %s" % [n, installed[n], cands[n].Version])
				return 0
			var held := holds()
			var keys := installed.keys()
			keys.sort()
			for n in keys:
				p.outln("%-18s %s%s" % [n, installed[n], "  [hold]" if held.has(n) else ""])
			return 0
		"search":
			if names.is_empty():
				p.errln("E: You must give exactly one pattern")
				return 100
			var cands := candidates()
			var keys := cands.keys()
			keys.sort()
			var word := names[0].to_lower()
			for n: String in keys:
				var e: Dictionary = cands[n]
				if n.to_lower().contains(word) or str(e.get("Description", "")).to_lower().contains(word):
					p.outln("%s - %s" % [n, e.get("Description", "")])
			return 0
		"show":
			if names.is_empty():
				p.errln("E: No packages found")
				return 100
			var found := false
			for e: Dictionary in available():
				if e.Package == names[0]:
					found = true
					var shown := e.duplicate()
					shown.erase("_uri")
					shown.erase("_label")
					p.out(AgoraArchive.stanza_text(shown) + "\n")
			if not found:
				p.errln("W: Unable to locate package %s" % names[0])
				p.errln("E: No packages found")
				return 100
			return 0
		"info":
			if names.is_empty():
				return p.fail(usage(), 1)
			var info := AgoraPackages.control_of(vfs, names[0])
			var cand: Dictionary = candidates().get(names[0], {})
			if info.is_empty() and cand.is_empty():
				return p.fail("package '%s' not found" % names[0], 1)
			if info.is_empty():
				info = {"name": cand.Package, "version": cand.Version, "description": cand.get("Description", ""),
					"depends": str(cand.get("Depends", "")).split(", ", false)}
			var state := "installed" if installed.has(names[0]) else ("config-files" if str(info.get("status", "")) == "config-files" else "not installed")
			p.outln("Package: %s\nVersion: %s\nStatus: %s\nDepends: %s\nDescription: %s" % [
				info.name, info.version, state,
				", ".join(info.get("depends", [])), info.get("description", "")])
			if not cand.is_empty():
				p.outln("Candidate: %s (%s)" % [cand.Version, cand._label])
			return 0
		"files":
			if names.is_empty() or not installed.has(names[0]):
				return p.fail("package '%s' is not installed" % (names[0] if not names.is_empty() else ""), 1)
			for f in AgoraPackages.files_of(vfs, names[0]):
				p.outln(f)
			return 0
	return p.fail(usage(), 1)


func _root_check() -> bool:
	if p.cred.is_root():
		return true
	p.errln("E: Could not open lock file /var/lib/apkg/lock - open (13 Permission denied)")
	p.errln("E: Unable to lock the administration directory (/var/lib/apkg/), are you root?")
	return false


# --- sources and indexes -------------------------------------------------------

## The archives of sources.list: [{uri, suite, component, label, list}].
func sources() -> Array:
	var out: Array = []
	for raw in p.read_text(SOURCES).split("\n", false):
		var line := raw.get_slice("#", 0).strip_edges()
		var words := line.split(" ", false)
		if words.size() < 3 or not words[0] in ["apkg", "deb"]:
			continue
		var uri := words[1].trim_suffix("/")
		for comp in (words.slice(3) if words.size() > 3 else PackedStringArray([AgoraArchive.COMPONENT])):
			out.append({"uri": uri, "suite": words[2], "component": comp, "label": _label(uri),
				"list": "%s/%s_dists_%s_%s_Packages" % [LISTS, _list_name(uri), words[2], comp]})
	return out


## How apt names an archive in its messages: the site, without the path.
static func _label(uri: String) -> String:
	if uri.begins_with("file:"):
		return uri
	var u := AgoraHttp.parse_url(uri)
	return "%s://%s" % [u.get("scheme", "http"), u.get("host", uri)] if not u.is_empty() else uri


static func _list_name(uri: String) -> String:
	var rest := uri.substr(uri.find(":") + 1)
	while rest.begins_with("/"):
		rest = rest.substr(1)
	return rest.replace("/", "_")


## apt's sizes: "3456B", "45.6kB", "1234kB".
static func size_str(n: float) -> String:
	var units := ["B", "kB", "MB", "GB"]
	for k in units.size():
		if n < 100 and k != 0:
			return "%.1f%s" % [n, units[k]]
		if n < 10000:
			return "%d%s" % [int(round(n)), units[k]]
		n /= 1000.0
	return "%d%s" % [int(n), "TB"]


func update() -> int:
	var started := Time.get_ticks_msec()
	var fetched := 0
	var failed := false
	var k := 0
	p.make_dirs(LISTS)
	for s: Dictionary in sources():
		var url := "%s/dists/%s/%s/Packages" % [s.uri, s.suite, s.component]
		var what := "%s %s/%s Packages" % [s.label, s.suite, s.component]
		var r: Dictionary = await AgoraFetch.fetch(p, url, AGENT)
		if r.has("error"):
			p.outln("Err %s" % what)
			p.outln("  %s" % r.error)
			failed = true
			continue
		k += 1
		var bytes: PackedByteArray = r.bytes
		var old := p.read_bytes(s.list)
		if old == bytes:
			p.outln("Hit %s" % what)
		else:
			p.outln("Get:%d %s [%s]" % [k, what, size_str(bytes.size())])
			fetched += bytes.size()
		p.write_bytes(s.list, bytes)
	var secs := maxf(0.001, (Time.get_ticks_msec() - started) / 1000.0)
	p.outln("Fetched %s in %ds (%s/s)" % [size_str(fetched), int(secs), size_str(fetched / secs)])
	p.outln("Reading Package Lists... Done")
	if failed:
		p.errln("W: Couldn't stat source package list; some archives could not be reached")
		p.errln("E: Some index files failed to download, they have been ignored, or old ones used instead.")
		return 100
	return 0


## Every package version in the downloaded indexes, with where it is from
## (_uri, _label).
func available() -> Array:
	var out: Array = []
	for s: Dictionary in sources():
		for e: Dictionary in AgoraArchive.stanzas(p.read_text(s.list)):
			if e.has("Package") and e.has("Version"):
				e._uri = s.uri
				e._label = "%s %s/%s" % [s.label, s.suite, s.component]
				out.append(e)
	return out


## The version install would choose for each package: the newest.
func candidates() -> Dictionary:
	var out := {}
	for e: Dictionary in available():
		var n: String = e.Package
		if not out.has(n) or AgoraArchive.compare_versions(e.Version, out[n].Version) > 0:
			out[n] = e
	return out


# --- installing ----------------------------------------------------------------

## A "name (>= 1.0)" dependency: [name, constraint].
static func _parse_dep(text: String) -> Array:
	text = text.strip_edges()
	if text.contains("("):
		return [text.get_slice("(", 0).strip_edges(), text.get_slice("(", 1).get_slice(")", 0).strip_edges()]
	return [text, ""]


func holds() -> PackedStringArray:
	return p.read_text(HOLD).split("\n", false)


func install(names: PackedStringArray) -> int:
	var installed := AgoraPackages.installed(p.machine.vfs)
	p.outln("Reading Package Lists... Done")
	p.outln("Building Dependency Tree... Done")
	var all := available()
	var cands := candidates()
	# What was asked for, by name or NAME=VERSION.
	var chosen := {}
	var newest: PackedStringArray = []
	for arg in names:
		if arg.ends_with(".pkg") or arg.contains("/"):
			var local := _local_entry(arg)
			if local.has("error"):
				p.errln("E: " + str(local.error))
				return 100
			chosen[local.Package] = local
			continue
		var name := arg.get_slice("=", 0)
		var e: Dictionary = {}
		if arg.contains("="):
			var want := arg.get_slice("=", 1)
			for x: Dictionary in all:
				if x.Package == name and x.Version == want:
					e = x
			if e.is_empty():
				p.errln("E: Version '%s' for '%s' was not found" % [want, name])
				return 100
		else:
			e = cands.get(name, {})
			if e.is_empty():
				var providers := _providers(name, cands)
				if not providers.is_empty():
					p.outln("Package %s is a virtual package provided by:" % name)
					for pr: Dictionary in providers:
						p.outln("  %s %s" % [pr.Package, pr.Version])
					p.outln("You should explicitly select one to install.")
					p.errln("E: Package %s has no installation candidate" % name)
					return 100
		if e.is_empty():
			p.errln("E: Couldn't find package %s" % name)
			return 100
		if installed.get(name, "") == e.Version:
			newest.append(name)
			continue
		chosen[name] = e
	var plan := _plan(chosen, cands, installed, true)
	if plan.has("error"):
		p.errln("E: " + str(plan.error))
		return 100
	for n in newest:
		p.outln("%s is already the newest version." % n)
	return await _execute(plan, chosen.keys(), installed, [])


## An index entry for a package file on the disk.
func _local_entry(path: String) -> Dictionary:
	var full := p.abspath(path)
	var bytes := p.read_bytes(full)
	if p.errno != AgoraErrno.OK:
		return {"error": "%s: %s" % [path, AgoraErrno.describe(p.errno)]}
	var pkg := AgoraPackages.from_json(bytes.get_string_from_utf8())
	if pkg.is_empty() or not pkg.has("name"):
		return {"error": "%s is not a package archive" % path}
	var e := AgoraArchive.index_entry(pkg, full, bytes)
	e._uri = ""
	e._label = "local"
	e._local = full
	return e


## Upgrades what is installed to the newest versions. Without [param dist],
## packages that would need others installed are kept back, like held ones.
func upgrade(dist: bool) -> int:
	var installed := AgoraPackages.installed(p.machine.vfs)
	p.outln("Reading Package Lists... Done")
	p.outln("Building Dependency Tree... Done")
	var cands := candidates()
	var held := holds()
	var chosen := {}
	var kept: PackedStringArray = []
	for n: String in installed:
		if cands.has(n) and AgoraArchive.compare_versions(cands[n].Version, installed[n]) > 0:
			if held.has(n):
				kept.append(n)
			else:
				chosen[n] = cands[n]
	var plan := _plan(chosen, cands, installed, dist)
	# Without dist-upgrade, nothing new comes in and nothing goes.
	while not dist and (plan.has("error") or not plan.remove.is_empty() or plan.install.any(func(e: Dictionary) -> bool: return not installed.has(e.Package))):
		var culprit := ""
		if plan.has("error"):
			culprit = str(plan.get("package", ""))
		else:
			for e: Dictionary in plan.install:
				if not installed.has(e.Package) or not plan.remove.is_empty():
					culprit = str(e.get("_for", e.Package))
					break
		if culprit.is_empty() or not chosen.has(culprit):
			culprit = chosen.keys()[0] if not chosen.is_empty() else ""
		if culprit.is_empty():
			break
		chosen.erase(culprit)
		kept.append(culprit)
		plan = _plan(chosen, cands, installed, false)
	if plan.has("error"):
		p.errln("E: " + str(plan.error))
		return 100
	kept.sort()
	return await _execute(plan, PackedStringArray(), installed, kept)


## The packages virtual [param name] stands for.
func _providers(name: String, cands: Dictionary) -> Array:
	var out: Array = []
	var keys := cands.keys()
	keys.sort()
	for n: String in keys:
		var e: Dictionary = cands[n]
		for prov in str(e.get("Provides", "")).split(",", false):
			if prov.strip_edges() == name:
				out.append(e)
	return out


func _installed_provider(name: String, installed: Dictionary) -> bool:
	for n: String in installed:
		if (AgoraPackages.control_of(p.machine.vfs, n).get("provides", []) as Array).has(name):
			return true
	return false


## What installing [param chosen] means: {install (entries, dependencies
## first), remove (names, for conflicts)} or {error, package}.
func _plan(chosen: Dictionary, cands: Dictionary, installed: Dictionary, allow_new: bool) -> Dictionary:
	var plan: Array = []
	var visiting := {}
	for name: String in chosen:
		var error := _add_with_deps(name, name, chosen, cands, installed, plan, visiting, allow_new)
		if not error.is_empty():
			return {"error": error, "package": name}
	# Conflicts, either way round.
	var remove: PackedStringArray = []
	var coming := {}
	for e: Dictionary in plan:
		coming[e.Package] = e.Version
	for e: Dictionary in plan:
		for item in str(e.get("Conflicts", "")).split(",", false):
			var dep := _parse_dep(item)
			if installed.has(dep[0]) and not coming.has(dep[0]) and AgoraArchive.satisfies(installed[dep[0]], dep[1]) and not remove.has(dep[0]):
				remove.append(dep[0])
	for n: String in installed:
		if coming.has(n):
			continue
		for item: String in AgoraPackages.control_of(p.machine.vfs, n).get("conflicts", []):
			var dep := _parse_dep(item)
			if coming.has(dep[0]) and AgoraArchive.satisfies(coming[dep[0]], dep[1]) and not remove.has(n):
				remove.append(n)
	return {"install": plan, "remove": remove}


## Adds [param name] to the plan after whatever it depends on. Returns an
## error message, or "".
func _add_with_deps(name: String, top: String, chosen: Dictionary, cands: Dictionary, installed: Dictionary, plan: Array,
		visiting: Dictionary, allow_new: bool) -> String:
	if visiting.has(name) or plan.any(func(e: Dictionary) -> bool: return e.Package == name):
		return ""
	visiting[name] = true
	var e: Dictionary = chosen.get(name, cands.get(name, {}))
	for item in str(e.get("Depends", "")).split(",", false):
		# "a | b (>= 2)": the first alternative that is there or can be had.
		var ok := false
		var options: Array = []
		for alt in item.split("|", false):
			options.append(_parse_dep(alt))
		for opt: Array in options:
			if (installed.has(opt[0]) and not chosen.has(opt[0]) and AgoraArchive.satisfies(installed[opt[0]], opt[1])) \
					or (opt[1].is_empty() and _installed_provider(opt[0], installed)):
				ok = true
				break
			if chosen.has(opt[0]) and AgoraArchive.satisfies(chosen[opt[0]].Version, opt[1]):
				ok = _add_with_deps(opt[0], top, chosen, cands, installed, plan, visiting, allow_new).is_empty()
				if ok:
					break
		if ok:
			continue
		for opt: Array in options:
			var c: Dictionary = cands.get(opt[0], {})
			if c.is_empty() and opt[1].is_empty():
				var providers := _providers(opt[0], cands)
				if not providers.is_empty():
					c = providers[0]
			if not c.is_empty() and AgoraArchive.satisfies(c.Version, opt[1]) and (allow_new or installed.has(c.Package)):
				var error := _add_with_deps(c.Package, top, chosen, cands, installed, plan, visiting, allow_new)
				if not error.is_empty():
					return error
				ok = true
				break
		if not ok:
			return "%s depends on %s, but it is not going to be installed" % [name, item.strip_edges()]
	var entry := e.duplicate()
	entry._for = top
	plan.append(entry)
	return ""


## Shows the plan, downloads, unpacks and sets up. [param asked]: what the
## user named (the rest are extras); [param kept]: what stays back.
func _execute(plan: Dictionary, asked: Array, installed: Dictionary, kept: PackedStringArray) -> int:
	var vfs := p.machine.vfs
	var todo: Array = plan.install
	var remove: PackedStringArray = plan.remove
	var extra: PackedStringArray = []
	var fresh: PackedStringArray = []
	var upgrades: PackedStringArray = []
	var downgrades: PackedStringArray = []
	var size := 0
	for e: Dictionary in todo:
		var n: String = e.Package
		if not asked.has(n) and not installed.has(n):
			extra.append(n)
		if not installed.has(n):
			fresh.append(n)
		elif AgoraArchive.compare_versions(e.Version, installed[n]) < 0:
			downgrades.append(n)
		else:
			upgrades.append(n)
		size += str(e.get("Size", "0")).to_int()
	if not extra.is_empty():
		p.outln("The following extra packages will be installed:")
		p.outln("  " + " ".join(extra))
	if not remove.is_empty():
		p.outln("The following packages will be REMOVED:")
		p.outln("  " + " ".join(remove))
	if not fresh.is_empty():
		p.outln("The following NEW packages will be installed:")
		p.outln("  " + " ".join(fresh))
	if not kept.is_empty():
		p.outln("The following packages have been kept back:")
		p.outln("  " + " ".join(kept))
	if not upgrades.is_empty():
		p.outln("The following packages will be upgraded:")
		p.outln("  " + " ".join(upgrades))
	if not downgrades.is_empty():
		p.outln("The following packages will be DOWNGRADED:")
		p.outln("  " + " ".join(downgrades))
	p.outln("%d upgraded, %d newly installed, %s%d to remove and %d not upgraded." % [upgrades.size(), fresh.size(),
		"%d downgraded, " % downgrades.size() if not downgrades.is_empty() else "", remove.size(), kept.size()])
	if todo.is_empty() and remove.is_empty():
		return 0
	if not todo.is_empty():
		p.outln("Need to get %s of archives." % size_str(size))
	if (not extra.is_empty() or not remove.is_empty() or not upgrades.is_empty() or not downgrades.is_empty()) and not _yes and is_terminal(p):
		p.out("Do you want to continue? [Y/n] ")
		var answer: Variant = await p.read_line()
		if answer == null or str(answer).strip_edges().to_lower().begins_with("n"):
			p.outln("Abort.")
			return 1
	# Download everything first, as apt does.
	p.make_dirs(CACHE)
	var started := Time.get_ticks_msec()
	var got := 0
	var files := {}
	var k := 0
	for e: Dictionary in todo:
		k += 1
		var url := "%s/%s" % [e._uri, e.Filename]
		if e.has("_local"):
			files[e.Package] = e._local
			continue
		var cached := "%s/%s" % [CACHE, AgoraPath.basename(str(e.Filename))]
		var bytes := p.read_bytes(cached)
		if bytes.size() == str(e.get("Size", "-1")).to_int() and AgoraArchive.md5(bytes) == str(e.get("MD5sum", "")):
			files[e.Package] = cached # already downloaded
			continue
		var r: Dictionary = await AgoraFetch.fetch(p, url, AGENT)
		if r.has("error"):
			p.outln("Err %s %s %s" % [e._label, e.Package, e.Version])
			p.outln("  %s" % r.error)
			p.errln("E: Failed to fetch %s  %s" % [url, r.error])
			p.errln("E: Unable to fetch some archives, maybe run apkg update or try with --fix-missing?")
			return 100
		bytes = r.bytes
		p.outln("Get:%d %s %s %s [%s]" % [k, e._label, e.Package, e.Version, size_str(bytes.size())])
		if str(bytes.size()) != str(e.get("Size", bytes.size())) or AgoraArchive.md5(bytes) != str(e.get("MD5sum", "")):
			p.errln("E: Failed to fetch %s  MD5Sum mismatch" % url)
			p.errln("E: Unable to fetch some archives, maybe run apkg update or try with --fix-missing?")
			return 100
		p.write_bytes(cached, bytes)
		files[e.Package] = cached
		got += bytes.size()
	if got > 0:
		var secs := maxf(0.001, (Time.get_ticks_msec() - started) / 1000.0)
		p.outln("Fetched %s in %ds (%s/s)" % [size_str(got), int(secs), size_str(got / secs)])
	# Out with what conflicts, then unpack and set up, as dpkg does.
	for n in remove:
		if not await _remove_one(n, false):
			return 100
	var failed: PackedStringArray = []
	var unpacked: Array = []
	for e: Dictionary in todo:
		var pkg := AgoraPackages.from_json(p.read_text(files[e.Package]))
		if pkg.is_empty():
			p.errln("dpkg: error processing %s: not a package archive" % files[e.Package])
			return 100
		var n: String = e.Package
		var old: String = installed.get(n, "")
		var leftover := old.is_empty() and str(AgoraPackages.control_of(vfs, n).get("status", "")) == "config-files"
		if not old.is_empty():
			p.outln("Preparing to replace %s %s (using .../%s) ..." % [n, old, AgoraPath.basename(files[n])])
			if await _script_file(n, "prerm", ["upgrade", e.Version]) != 0:
				_script_error(n, "pre-removal", "--install")
				failed.append(n)
				continue
		else:
			p.outln("Selecting previously deselected package %s." % n)
		var pre_args := ["upgrade", old] if not old.is_empty() else (["install", str(AgoraPackages.control_of(vfs, n).get("version", ""))] if leftover else ["install"])
		if await _script_text(n, "preinst", pkg, pre_args) != 0:
			_script_error(n, "pre-installation", "--install")
			failed.append(n)
			continue
		p.outln("Unpacking %s (from .../%s) ..." % [n, AgoraPath.basename(files[n])])
		e._pkg = pkg
		e._old = old
		unpacked.append(e)
		await p.tick()
	for e: Dictionary in unpacked:
		var n: String = e.Package
		p.outln("Setting up %s (%s) ..." % [n, e.Version])
		var answers := await _conffile_answers(e._pkg)
		var keep := func(path: String) -> bool: return answers.get(path, true)
		var old_postrm := p.read_text(AgoraPackages.script_path(n, "postrm")) if not str(e._old).is_empty() else ""
		var notes := AgoraPackages.install(vfs, e._pkg, false, keep)
		for line in notes:
			# What was asked on the terminal isn't said twice.
			if answers.is_empty() or line.begins_with(" ==> Keeping") or line.begins_with(" ==> Installing"):
				p.outln(line)
		if not old_postrm.is_empty():
			await _run_script(n, "postrm", old_postrm, ["upgrade", e.Version])
		var post_args := ["configure"] + ([e._old] if not str(e._old).is_empty() else [])
		if await _script_file(n, "postinst", post_args) != 0:
			_script_error(n, "post-installation", "--configure")
			failed.append(n)
	_reload_inetd()
	if not failed.is_empty():
		p.errln("Errors were encountered while processing:")
		for n in failed:
			p.errln(" " + n)
		p.errln("E: Sub-process apkg returned an error code (1)")
		return 100
	return 0


func _script_error(name: String, kind: String, stage: String) -> void:
	p.errln("dpkg: error processing %s (%s):" % [name, stage])
	p.errln(" subprocess %s script returned error exit status %d" % [kind, _last_status])


var _last_status := 0


## Runs the installed package's maintainer script [param which], if it has
## one. Returns its exit status (0 if there is none).
func _script_file(name: String, which: String, args: Array) -> int:
	var text := p.read_text(AgoraPackages.script_path(name, which))
	if text.is_empty():
		return 0
	return await _run_script(name, which, text, args)


## Runs a script that comes with [param pkg] (not installed yet).
func _script_text(name: String, which: String, pkg: Dictionary, args: Array) -> int:
	var text := str((pkg.get("scripts", {}) as Dictionary).get(which, ""))
	if text.is_empty():
		return 0
	return await _run_script(name, which, text, args)


func _run_script(name: String, which: String, text: String, args: Array) -> int:
	var dir := "/var/lib/apkg/tmp.ci"
	p.make_dirs(dir)
	var path := "%s/%s.%s" % [dir, name, which]
	p.write_text(path, text, false, AgoraStat.MODE_EXEC)
	p.chmod(path, AgoraStat.MODE_EXEC)
	var argv := PackedStringArray(["/bin/sh", path])
	for a in args:
		argv.append(str(a))
	var env := p.env.duplicate()
	env.APKG_MAINTSCRIPT_PACKAGE = name
	env.APKG_MAINTSCRIPT_NAME = which
	env.PATH = AgoraMachine.DEFAULT_PATH
	var child := p.spawn(argv, {"env": env, "cwd": "/"})
	_last_status = await child.wait() if child else 127
	p.unlink(path)
	return _last_status


## Removes one package with its scripts, as dpkg --remove (--purge).
## Returns false if its prerm failed.
func _remove_one(n: String, purge: bool) -> bool:
	var vfs := p.machine.vfs
	if AgoraPackages.installed(vfs).has(n):
		p.outln("Removing %s ..." % n)
		if await _script_file(n, "prerm", ["remove"]) != 0:
			_script_error(n, "pre-removal", "--remove")
			return false
		var postrm := p.read_text(AgoraPackages.script_path(n, "postrm"))
		AgoraPackages.remove(vfs, n, false)
		if not postrm.is_empty():
			await _run_script(n, "postrm", postrm, ["remove"])
	if purge:
		p.outln("Purging configuration files for %s ..." % n)
		var postrm := p.read_text(AgoraPackages.script_path(n, "postrm"))
		AgoraPackages.remove(vfs, n, true)
		if not postrm.is_empty():
			await _run_script(n, "postrm", postrm, ["purge"])
	return true


## On a terminal, asks what to do about each configuration file the user
## changed and the new version changes too, as dpkg asks. Returns path ->
## keep (true: keep the user's version). Without a terminal (or with -y)
## nothing is asked and the user's version stays.
func _conffile_answers(pkg: Dictionary) -> Dictionary:
	var answers := {}
	if _yes or not is_terminal(p):
		return answers
	for path in AgoraPackages.changed_conffiles(p.machine.vfs, pkg):
		p.outln("")
		p.outln("Configuration file `%s'" % path)
		p.outln(" ==> Modified (by you or by a script) since installation.")
		p.outln(" ==> Package distributor has shipped an updated version.")
		p.outln("   What would you like to do about it ?  Your options are:")
		p.outln("    Y or I  : install the package maintainer's version")
		p.outln("    N or O  : keep your currently-installed version")
		p.out("*** %s (Y/I/N/O) [default=N] ? " % AgoraPath.basename(path))
		var a: Variant = await p.read_line()
		var choice := str(a).strip_edges().to_upper() if a != null else ""
		answers[path] = not (choice.begins_with("Y") or choice.begins_with("I"))
	return answers


func _policy(names: PackedStringArray, installed: Dictionary) -> void:
	var all := available()
	if names.is_empty():
		p.outln("Package Files:")
		p.outln(" 100 %s" % AgoraPackages.DB)
		for s: Dictionary in sources():
			p.outln(" 500 %s %s/%s Packages" % [s.label, s.suite, s.component])
		return
	var cands := candidates()
	for n in names:
		var versions := {}
		for e: Dictionary in all:
			if e.Package == n:
				if not versions.has(e.Version):
					versions[e.Version] = []
				versions[e.Version].append(e._label)
		var inst: String = installed.get(n, "")
		if not inst.is_empty() and not versions.has(inst):
			versions[inst] = []
		p.outln("%s:" % n)
		p.outln("  Installed: %s" % (inst if not inst.is_empty() else "(none)"))
		p.outln("  Candidate: %s" % (cands[n].Version if cands.has(n) else "(none)"))
		p.outln("  Version Table:")
		var order := versions.keys()
		order.sort_custom(func(a: String, b: String) -> bool: return AgoraArchive.compare_versions(a, b) > 0)
		for v: String in order:
			p.outln(" %s %s 0" % ["***" if v == inst else "   ", v])
			for label: String in versions[v]:
				p.outln("        500 %s Packages" % label)
			if v == inst:
				p.outln("        100 %s" % AgoraPackages.DB)


func _remove(names: PackedStringArray, installed: Dictionary, purge: bool) -> int:
	var vfs := p.machine.vfs
	var leftover := AgoraPackages.config_only(vfs)
	for n in names:
		if not installed.has(n) and not (purge and leftover.has(n)):
			return p.fail("package '%s' is not installed" % n, 1)
		for other: String in installed:
			if other == n or names.has(other):
				continue
			for dep: String in AgoraPackages.control_of(vfs, other).get("depends", []):
				var alts := dep.split("|", false)
				if alts.size() == 1 and _parse_dep(alts[0])[0] == n:
					return p.fail("cannot remove %s: %s depends on it" % [n, other], 1)
	for n in names:
		if not await _remove_one(n, purge):
			_reload_inetd()
			return 100
	_reload_inetd()
	return 0


## Services may have come or gone from /etc/inetd.conf: a running inetd
## rereads it on SIGHUP.
func _reload_inetd() -> void:
	for pid in p.machine.list_pids():
		var other := p.machine.get_process(pid)
		if other and other.name == "inetd":
			p.machine.kill(pid, AgoraProcess.SIGHUP, p.cred)
