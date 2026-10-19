class_name AgoraArchive
extends RefCounted
## A package archive (repository) as apkg reads it, laid out like Debian's:
##
##   BASE/dists/SUITE/Release                   what the archive is
##   BASE/dists/SUITE/COMPONENT/Packages        the index: one stanza each
##   BASE/pool/COMPONENT/L/NAME/NAME_VERSION.pkg  the packages
##
## An index stanza has Package, Version, Architecture, Maintainer, Depends,
## Size, MD5sum, Filename (relative to BASE) and Description. One archive
## may hold several versions of a package. The archive can be served from
## a disk (file:), a web server (http:) or an FTP server (ftp:).

const SUITE := "stable"
const COMPONENT := "main"
const MAINTAINER := "AgoraOS Developers <devel@agoraos.org>"


## "pool/main/a/apache2/apache2_0.1.0.pkg"
static func pool_path(pkg: Dictionary, component: String = COMPONENT) -> String:
	var name: String = pkg.name
	var letter := name.left(4) if name.begins_with("lib") else name.left(1)
	return "pool/%s/%s/%s/%s_%s.pkg" % [component, letter, name, name, str(pkg.get("version", "0")).replace(":", "%3a")]


## Writes [param packages] into an archive at [param base] on [param vfs]
## (as root), with the index and Release file.
static func write(vfs: AgoraVfs, base: String, packages: Array, suite: String = SUITE, component: String = COMPONENT,
		origin: String = "AgoraOS", date: String = "") -> void:
	var root := AgoraCred.root()
	for pkg: Dictionary in packages:
		var path := "%s/%s" % [base, pool_path(pkg, component)]
		vfs.make_dirs(root, AgoraPath.dirname(path))
		vfs.write_text(root, path, AgoraPackages.to_json(pkg))
	scan(vfs, base, suite, component, origin, date)


## Builds the index of [param component] from the .pkg files under
## pool/COMPONENT (what apkg-scanpackages does). Returns how many it found.
static func scan(vfs: AgoraVfs, base: String, suite: String = SUITE, component: String = COMPONENT,
		origin: String = "AgoraOS", date: String = "") -> int:
	var root := AgoraCred.root()
	var files: PackedStringArray = []
	_find_pkgs(vfs, "%s/pool/%s" % [base, component], files)
	files.sort()
	var entries: Array = []
	for f in files:
		var bytes := vfs.read_file(root, f)
		var pkg := AgoraPackages.from_json(bytes.get_string_from_utf8())
		if pkg.is_empty():
			continue
		entries.append(index_entry(pkg, f.substr(base.length() + 1), bytes))
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a.Package < b.Package or (a.Package == b.Package and compare_versions(a.Version, b.Version) < 0))
	var text := ""
	for e: Dictionary in entries:
		text += stanza_text(e) + "\n"
	var index := "%s/dists/%s/%s/Packages" % [base, suite, component]
	vfs.make_dirs(root, AgoraPath.dirname(index))
	vfs.write_text(root, index, text)
	var release := {"Origin": origin, "Label": origin, "Suite": suite, "Codename": suite,
		"Architectures": "all", "Components": component, "Description": "%s %s" % [origin, AgoraDistro.VERSION]}
	if not date.is_empty():
		release.Date = date
	release.MD5Sum = "\n %s %d %s/Packages" % [text.md5_text(), text.to_utf8_buffer().size(), component]
	vfs.write_text(root, "%s/dists/%s/Release" % [base, suite], stanza_text(release))
	return entries.size()


static func _find_pkgs(vfs: AgoraVfs, dir: String, out: PackedStringArray) -> void:
	var root := AgoraCred.root()
	for n in vfs.list_dir(root, dir):
		var path := dir + "/" + n
		var st := vfs.stat(root, path)
		if st == null:
			continue
		if st.is_dir():
			_find_pkgs(vfs, path, out)
		elif n.ends_with(".pkg"):
			out.append(path)


## The index stanza of a package file.
static func index_entry(pkg: Dictionary, filename: String, bytes: PackedByteArray) -> Dictionary:
	var e := {"Package": pkg.name, "Version": str(pkg.get("version", "0")), "Architecture": "all",
		"Maintainer": str(pkg.get("maintainer", MAINTAINER))}
	var deps: Array = pkg.get("depends", [])
	if not deps.is_empty():
		e.Depends = ", ".join(PackedStringArray(deps))
	for pair in [["provides", "Provides"], ["conflicts", "Conflicts"], ["replaces", "Replaces"]]:
		var list: Array = pkg.get(pair[0], [])
		if not list.is_empty():
			e[pair[1]] = ", ".join(PackedStringArray(list))
	e.Size = str(bytes.size())
	e.MD5sum = _md5(bytes)
	e.Filename = filename
	e.Description = str(pkg.get("description", ""))
	return e


static func _md5(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


static func md5(bytes: PackedByteArray) -> String:
	return _md5(bytes)


## "Key: value" lines; values with newlines continue on indented lines.
static func stanza_text(fields: Dictionary) -> String:
	var out := ""
	for k: String in fields:
		var v := str(fields[k])
		out += "%s:%s\n" % [k, ("" if v.begins_with("\n") else " ") + v]
	return out


## The stanzas of an index or control file.
static func stanzas(text: String) -> Array:
	var out: Array = []
	var cur := {}
	var last := ""
	for line in text.replace("\r", "").split("\n"):
		if line.strip_edges().is_empty():
			if not cur.is_empty():
				out.append(cur)
			cur = {}
			last = ""
			continue
		if (line.begins_with(" ") or line.begins_with("\t")) and not last.is_empty():
			cur[last] = str(cur[last]) + "\n" + line.strip_edges()
			continue
		if line.contains(":"):
			last = line.get_slice(":", 0).strip_edges()
			cur[last] = line.substr(line.find(":") + 1).strip_edges()
	if not cur.is_empty():
		out.append(cur)
	return out


# --- versions ------------------------------------------------------------------

## Compares two version strings the way dpkg does ([epoch:]upstream[-revision]):
## negative if [param a] is older, 0 if equal, positive if newer.
static func compare_versions(a: String, b: String) -> int:
	var ea := _epoch(a)
	var eb := _epoch(b)
	if ea[0] != eb[0]:
		return 1 if ea[0] > eb[0] else -1
	var ra := _split_revision(ea[1])
	var rb := _split_revision(eb[1])
	var c := _compare_part(ra[0], rb[0])
	if c != 0:
		return c
	return _compare_part(ra[1], rb[1])


static func _epoch(v: String) -> Array:
	var colon := v.find(":")
	if colon > 0 and v.substr(0, colon).is_valid_int():
		return [v.substr(0, colon).to_int(), v.substr(colon + 1)]
	return [0, v]


static func _split_revision(v: String) -> Array:
	var dash := v.rfind("-")
	if dash < 0:
		return [v, ""]
	return [v.substr(0, dash), v.substr(dash + 1)]


## Order of a character outside a digit run: "~" before everything, even
## the end; letters before other symbols.
static func _order(c: String) -> int:
	if c.is_empty():
		return 0
	if c == "~":
		return -1
	var code := c.unicode_at(0)
	if (code >= 65 and code <= 90) or (code >= 97 and code <= 122):
		return code
	return code + 256


static func _compare_part(a: String, b: String) -> int:
	var i := 0
	var j := 0
	while i < a.length() or j < b.length():
		# The non-digit part, character by character.
		while (i < a.length() and not a[i].is_valid_int()) or (j < b.length() and not b[j].is_valid_int()):
			var ca := a[i] if i < a.length() and not a[i].is_valid_int() else ""
			var cb := b[j] if j < b.length() and not b[j].is_valid_int() else ""
			var oa := _order(ca)
			var ob := _order(cb)
			if oa != ob:
				return 1 if oa > ob else -1
			if not ca.is_empty():
				i += 1
			if not cb.is_empty():
				j += 1
		# Then the number.
		var na := 0
		var nb := 0
		while i < a.length() and a[i].is_valid_int():
			na = na * 10 + a[i].to_int()
			i += 1
		while j < b.length() and b[j].is_valid_int():
			nb = nb * 10 + b[j].to_int()
			j += 1
		if na != nb:
			return 1 if na > nb else -1
	return 0


## "1.2.0" against a constraint like ">= 1.0" ("" always matches).
static func satisfies(version: String, constraint: String) -> bool:
	constraint = constraint.strip_edges()
	if constraint.is_empty():
		return true
	for op in [">=", "<=", ">>", "<<", "=", ">", "<"]:
		if constraint.begins_with(op):
			var c := compare_versions(version, constraint.substr(op.length()).strip_edges())
			match op:
				">=", ">": return c >= 0
				"<=", "<": return c <= 0
				">>": return c > 0
				"<<": return c < 0
				"=": return c == 0
	return compare_versions(version, constraint) == 0
