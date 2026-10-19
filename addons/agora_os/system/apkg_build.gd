extends AgoraProgram
## apkg-build DIRECTORY [FILE]: makes a package from a directory, as
## dpkg-deb --build does. DIRECTORY holds the files as they will lie on
## the system (DIRECTORY/usr/bin/hello becomes /usr/bin/hello) and an
## APKG directory with:
##
##   control    Package, Version (required), Depends, Conflicts, Provides,
##              Replaces, Maintainer, Description
##   conffiles  more configuration files, one path per line (all of /etc
##              is anyway)
##   preinst, postinst, prerm, postrm
##              maintainer scripts, run by apkg as dpkg runs them
##
## The package is written to FILE, or NAME_VERSION.pkg in the current
## directory. Files keep their modes; they are installed owned by root.

const META := "APKG"


func summary() -> String:
	return "build a package from a directory"


func usage() -> String:
	return "usage: apkg-build DIRECTORY [FILE]"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv)
	if a.operands.is_empty():
		return p.fail(usage(), 2)
	var dir := p.abspath(a.operands[0]).trim_suffix("/")
	if not p.is_dir(dir):
		return p.fail("error: failed to open package info file `%s/%s/control' for reading: %s" % [dir, META, AgoraErrno.describe(AgoraErrno.ENOENT)], 2)
	var text := p.read_text("%s/%s/control" % [dir, META])
	if p.errno != AgoraErrno.OK:
		return p.fail("error: failed to open package info file `%s/%s/control' for reading: %s" % [dir, META, AgoraErrno.describe(p.errno)], 2)
	var st := AgoraArchive.stanzas(text)
	var control: Dictionary = st[0] if not st.is_empty() else {}
	for field in ["Package", "Version"]:
		if str(control.get(field, "")).is_empty():
			return p.fail("error: parsing file '%s/%s/control' near line 1 package '%s':\n missing %s field" % [dir, META, control.get("Package", "?"), field], 2)
	var name := str(control.Package)
	if not _valid_name(name):
		return p.fail("error: parsing file '%s/%s/control': invalid package name '%s'" % [dir, META, name], 2)
	var version := str(control.Version)
	if version.contains(" ") or version.contains("/"):
		return p.fail("error: parsing file '%s/%s/control': invalid version '%s'" % [dir, META, version], 2)
	var pkg := {"name": name, "version": version, "description": str(control.get("Description", "")).get_slice("\n", 0),
		"depends": _list(control.get("Depends", "")), "dirs": {}, "files": {}, "programs": [], "links": {}}
	for pair in [["Conflicts", "conflicts"], ["Provides", "provides"], ["Replaces", "replaces"]]:
		var list := _list(control.get(pair[0], ""))
		if not list.is_empty():
			pkg[pair[1]] = list
	if control.has("Maintainer"):
		pkg.maintainer = str(control.Maintainer)
	var conf := p.read_text("%s/%s/conffiles" % [dir, META]).split("\n", false)
	if not conf.is_empty():
		pkg.conffiles = Array(conf)
	# Maintainer scripts must be runnable, as dpkg-deb insists.
	var scripts := {}
	for which in AgoraPackages.SCRIPTS:
		var path := "%s/%s/%s" % [dir, META, which]
		var sst := p.stat(path)
		if sst == null:
			continue
		var perms := sst.mode & 511
		if perms & 365 != 365 or perms & 2: # 0o555, 0o002
			return p.fail("error: maintainer script `%s' has bad permissions %o (must be >=0555 and <=0775)" % [which, perms], 2)
		scripts[which] = p.read_text(path)
	if not scripts.is_empty():
		pkg.scripts = scripts
	var error := _collect(p, dir, "", pkg)
	if not error.is_empty():
		return p.fail("error: " + error, 2)
	var out := p.abspath(a.operands[1]) if a.operands.size() > 1 else p.abspath("%s_%s.pkg" % [name, version.replace(":", "%3a")])
	if p.is_dir(out):
		out = "%s/%s_%s.pkg" % [out.trim_suffix("/"), name, version.replace(":", "%3a")]
	p.outln("apkg-build: building package `%s' in `%s'." % [name, a.operands[1] if a.operands.size() > 1 else AgoraPath.basename(out)])
	if p.write_text(out, AgoraPackages.to_json(pkg)) != AgoraErrno.OK:
		return p.fail("error: unable to create `%s': %s" % [out, AgoraErrno.describe(p.errno)], 2)
	return 0


static func _valid_name(name: String) -> bool:
	if name.length() < 2 or not (name[0].is_valid_int() or (name[0] >= "a" and name[0] <= "z")):
		return false
	for c in name:
		if not (c.is_valid_int() or (c >= "a" and c <= "z") or c in ["+", "-", "."]):
			return false
	return true


static func _list(value: Variant) -> Array:
	var out: Array = []
	for item in str(value).replace("\n", " ").split(",", false):
		if not item.strip_edges().is_empty():
			out.append(item.strip_edges())
	return out


## Walks the tree below [param dir]: directories, files and links, with
## their modes, under their paths on the system.
func _collect(p: AgoraProcess, dir: String, rel: String, pkg: Dictionary) -> String:
	var names := p.list_dir(dir + rel)
	names.sort()
	for n in names:
		if rel.is_empty() and n == META:
			continue
		var path := "%s/%s" % [rel, n]
		var full := dir + path
		var st := p.stat(full, false)
		if st == null:
			return "cannot read %s: %s" % [full, AgoraErrno.describe(p.errno)]
		if st.is_symlink():
			pkg.links[path] = p.read_link(full)
		elif st.is_dir():
			pkg.dirs[path] = st.mode & 4095
			var error := _collect(p, dir, path, pkg)
			if not error.is_empty():
				return error
		elif st.is_file():
			var bytes := p.read_bytes(full)
			if p.errno != AgoraErrno.OK:
				return "cannot read %s: %s" % [full, AgoraErrno.describe(p.errno)]
			var text := bytes.get_string_from_utf8()
			if text.to_utf8_buffer() == bytes:
				pkg.files[path] = [text, st.mode & 4095]
			else:
				pkg.files[path] = [Marshalls.raw_to_base64(bytes), st.mode & 4095, "base64"]
	return ""
