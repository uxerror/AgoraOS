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
const AGENT := "apkg/%s" % AgoraDistro.VERSION

var p: AgoraProcess
var _yes := false


func summary() -> String:
	return "install, remove and inspect packages"


func usage() -> String:
	return """usage: apkg update
       apkg install [-y] PACKAGE[=VERSION]...
       apkg remove PACKAGE...
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
		"remove", "purge":
			if not _root_check():
				return 100
			return _remove(names, installed)
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
			var keys := installed.keys()
			keys.sort()
			for n in keys:
				p.outln("%-18s %s" % [n, installed[n]])
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
			p.outln("Package: %s\nVersion: %s\nStatus: %s\nDepends: %s\nDescription: %s" % [
				info.name, info.version, "installed" if installed.has(names[0]) else "not installed",
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


func install(names: PackedStringArray) -> int:
	var vfs := p.machine.vfs
	var installed := AgoraPackages.installed(vfs)
	p.outln("Reading Package Lists... Done")
	p.outln("Building Dependency Tree... Done")
	var all := available()
	var cands := candidates()
	# What was asked for, by name or NAME=VERSION.
	var chosen := {}
	var order: Array = []
	var newest: PackedStringArray = []
	for arg in names:
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
			p.errln("E: Couldn't find package %s" % name)
			return 100
		if installed.get(name, "") == e.Version:
			newest.append(name)
			continue
		chosen[name] = e
		order.append(name)
	# What they need, depth first so dependencies come before.
	var plan: Array = []
	var visiting := {}
	for name: String in order:
		var error := _add_with_deps(name, chosen, cands, installed, plan, visiting)
		if not error.is_empty():
			p.errln("E: " + error)
			return 100
	for n in newest:
		p.outln("%s is already the newest version." % n)
	var extra: PackedStringArray = []
	var fresh: PackedStringArray = []
	var upgrades: PackedStringArray = []
	var size := 0
	for e: Dictionary in plan:
		var n: String = e.Package
		if not names.has(n) and not order.has(n):
			extra.append(n)
		if installed.has(n):
			upgrades.append(n)
		else:
			fresh.append(n)
		size += str(e.get("Size", "0")).to_int()
	if not extra.is_empty():
		p.outln("The following extra packages will be installed:")
		p.outln("  " + " ".join(extra))
	if not fresh.is_empty():
		p.outln("The following NEW packages will be installed:")
		p.outln("  " + " ".join(fresh))
	if not upgrades.is_empty():
		p.outln("The following packages will be upgraded:")
		p.outln("  " + " ".join(upgrades))
	p.outln("%d upgraded, %d newly installed, 0 to remove and 0 not upgraded." % [upgrades.size(), fresh.size()])
	if plan.is_empty():
		return 0
	p.outln("Need to get %s of archives." % size_str(size))
	if not extra.is_empty() and not _yes and is_terminal(p):
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
	for e: Dictionary in plan:
		k += 1
		var url := "%s/%s" % [e._uri, e.Filename]
		var r: Dictionary = await AgoraFetch.fetch(p, url, AGENT)
		if r.has("error"):
			p.outln("Err %s %s %s" % [e._label, e.Package, e.Version])
			p.outln("  %s" % r.error)
			p.errln("E: Failed to fetch %s  %s" % [url, r.error])
			p.errln("E: Unable to fetch some archives, maybe run apkg update or try with --fix-missing?")
			return 100
		var bytes: PackedByteArray = r.bytes
		p.outln("Get:%d %s %s %s [%s]" % [k, e._label, e.Package, e.Version, size_str(bytes.size())])
		if str(bytes.size()) != str(e.get("Size", bytes.size())) or AgoraArchive.md5(bytes) != str(e.get("MD5sum", "")):
			p.errln("E: Failed to fetch %s  MD5Sum mismatch" % url)
			p.errln("E: Unable to fetch some archives, maybe run apkg update or try with --fix-missing?")
			return 100
		var cached := "%s/%s" % [CACHE, AgoraPath.basename(str(e.Filename))]
		p.write_bytes(cached, bytes)
		files[e.Package] = cached
		got += bytes.size()
	var secs := maxf(0.001, (Time.get_ticks_msec() - started) / 1000.0)
	p.outln("Fetched %s in %ds (%s/s)" % [size_str(got), int(secs), size_str(got / secs)])
	# Then unpack and set up, as dpkg does.
	for e: Dictionary in plan:
		var pkg := AgoraPackages.from_json(p.read_text(files[e.Package]))
		if pkg.is_empty():
			p.errln("dpkg: error processing %s: not a package archive" % files[e.Package])
			return 100
		var n: String = e.Package
		if installed.has(n):
			p.outln("Preparing to replace %s %s (using .../%s) ..." % [n, installed[n], AgoraPath.basename(files[n])])
		else:
			p.outln("Selecting previously deselected package %s." % n)
		p.outln("Unpacking %s (from .../%s) ..." % [n, AgoraPath.basename(files[n])])
		AgoraPackages.install(vfs, pkg)
		await p.tick()
	for e: Dictionary in plan:
		p.outln("Setting up %s (%s) ..." % [e.Package, e.Version])
	_reload_inetd()
	return 0


## Adds [param name] to the plan after whatever it depends on. Returns an
## error message, or "".
func _add_with_deps(name: String, chosen: Dictionary, cands: Dictionary, installed: Dictionary, plan: Array, visiting: Dictionary) -> String:
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
			if installed.has(opt[0]) and AgoraArchive.satisfies(installed[opt[0]], opt[1]):
				ok = true
				break
		if ok:
			continue
		for opt: Array in options:
			var c: Dictionary = cands.get(opt[0], {})
			if not c.is_empty() and AgoraArchive.satisfies(c.Version, opt[1]):
				var error := _add_with_deps(opt[0], chosen, cands, installed, plan, visiting)
				if not error.is_empty():
					return error
				ok = true
				break
		if not ok:
			return "%s depends on %s, but it is not going to be installed" % [name, item.strip_edges()]
	plan.append(e)
	return ""


func _remove(names: PackedStringArray, installed: Dictionary) -> int:
	var vfs := p.machine.vfs
	for n in names:
		if not installed.has(n):
			return p.fail("package '%s' is not installed" % n, 1)
		for other: String in installed:
			if other != n and not names.has(other) and AgoraPackages.control_of(vfs, other).get("depends", []).has(n):
				return p.fail("cannot remove %s: %s depends on it" % [n, other], 1)
	for n in names:
		p.outln("Removing %s ..." % n)
		AgoraPackages.remove(vfs, n)
	_reload_inetd()
	return 0


## Services may have come or gone from /etc/inetd.conf: a running inetd
## rereads it on SIGHUP.
func _reload_inetd() -> void:
	for pid in p.machine.list_pids():
		var other := p.machine.get_process(pid)
		if other and other.name == "inetd":
			p.machine.kill(pid, AgoraProcess.SIGHUP, p.cred)
