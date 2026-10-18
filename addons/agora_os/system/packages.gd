class_name AgoraPackages
extends RefCounted
## Installs and removes packages (see [AgoraDistro] for the format) on a
## file system, and keeps the database of what is installed:
##   /var/lib/apkg/installed        "name version" per line
##   /var/lib/apkg/info/<name>.list  files the package put on disk
##   /var/lib/apkg/info/<name>.control  version, description, depends (JSON)

const DB := "/var/lib/apkg/installed"
const INFO_DIR := "/var/lib/apkg/info"


## Installs [param pkg] onto [param vfs] as root. With [param only_missing],
## files that already exist are left alone (used for upgrades, so local
## edits survive).
static func install(vfs: AgoraVfs, pkg: Dictionary, only_missing: bool = false) -> void:
	var root := AgoraCred.root()
	var owned: PackedStringArray = []
	var dirs: Dictionary = pkg.get("dirs", {})
	for path: String in dirs:
		if not vfs.exists(root, path):
			vfs.make_dirs(root, path)
			vfs.chmod(root, path, dirs[path])
	var files: Dictionary = pkg.get("files", {})
	for path: String in files:
		owned.append(path)
		if only_missing and vfs.stat(root, path, "/", false) != null:
			continue
		vfs.make_dirs(root, AgoraPath.dirname(path))
		var entry: Array = files[path]
		vfs.write_text(root, path, entry[0], "/", false, entry[1])
		vfs.chmod(root, path, entry[1])
	for name: String in pkg.get("programs", []):
		var path := AgoraPrograms.path_for(name)
		owned.append(path)
		if only_missing and vfs.stat(root, path, "/", false) != null:
			continue
		write_binary(vfs, name, path)
	var links: Dictionary = pkg.get("links", {})
	for link: String in links:
		owned.append(link)
		var existing := vfs.stat(root, link, "/", false)
		if existing != null:
			if only_missing or existing.is_dir():
				continue
			vfs.unlink(root, link)
		vfs.make_dirs(root, AgoraPath.dirname(link))
		vfs.symlink(root, links[link], link)
	for line: String in pkg.get("inetd", []):
		_inetd_add(vfs, line)
	add_system_users(vfs, pkg.get("users", []))
	_record(vfs, pkg, owned)


## System accounts a package needs (www-data, ftp...): {name, uid, home,
## shell}, locked, created unless they exist. Their home is not populated.
static func add_system_users(vfs: AgoraVfs, list: Array) -> void:
	if list.is_empty() or not vfs.exists(AgoraCred.root(), "/etc/passwd"):
		return
	var users := AgoraUsers.new(vfs)
	for u: Dictionary in list:
		if users.find(u.name).is_empty():
			# The home is made here, so no /etc/skel files land in it.
			vfs.make_dirs(AgoraCred.root(), u.home)
			users.add_user(u.name, "", {"uid": int(u.uid), "home": u.home, "shell": u.get("shell", "/bin/false"), "gecos": u.get("gecos", u.name)})
			users.lock(u.name)


## Services a package offers through inetd, as update-inetd does: the line
## is added to /etc/inetd.conf unless the service is listed (or disabled
## with "#<off>#") already.
const INETD_CONF := "/etc/inetd.conf"


static func _inetd_add(vfs: AgoraVfs, line: String) -> void:
	var root := AgoraCred.root()
	var service := line.get_slice("\t", 0).get_slice(" ", 0)
	var text := vfs.read_text(root, INETD_CONF)
	for l in text.split("\n"):
		var w := l.trim_prefix("#<off># ").replace("\t", " ").split(" ", false)
		if not w.is_empty() and w[0] == service:
			return
	if not text.is_empty() and not text.ends_with("\n"):
		text += "\n"
	vfs.write_text(root, INETD_CONF, text + line + "\n", "/", false, AgoraStat.MODE_FILE)


static func _inetd_remove(vfs: AgoraVfs, line: String) -> void:
	var root := AgoraCred.root()
	var kept: PackedStringArray = []
	for l in vfs.read_text(root, INETD_CONF).split("\n"):
		if l.strip_edges() != line.strip_edges():
			kept.append(l)
	vfs.write_text(root, INETD_CONF, "\n".join(kept))


## Writes the on-disk binary of a registered program.
static func write_binary(vfs: AgoraVfs, name: String, path: String) -> void:
	var root := AgoraCred.root()
	var body := "%s%s\n# %s native executable. Not human readable.\n" % [AgoraMachine.EXEC_MAGIC, name, AgoraMachine.KERNEL_NAME]
	var mode := AgoraStat.MODE_EXEC
	if AgoraPrograms.SETUID.has(name):
		mode |= AgoraStat.S_ISUID
	vfs.make_dirs(root, AgoraPath.dirname(path))
	if vfs.stat(root, path, "/", false) != null and vfs.stat(root, path, "/", false).is_symlink():
		vfs.unlink(root, path)
	vfs.write_text(root, path, body, "/", false, mode)
	vfs.chmod(root, path, mode)


## Removes the files of an installed package. Directories stay.
static func remove(vfs: AgoraVfs, name: String) -> int:
	var root := AgoraCred.root()
	if not installed(vfs).has(name):
		return AgoraErrno.ENOENT
	for path in vfs.read_text(root, "%s/%s.list" % [INFO_DIR, name]).split("\n", false):
		var st := vfs.stat(root, path, "/", false)
		if st != null and not st.is_dir():
			vfs.unlink(root, path)
	for line: String in control_of(vfs, name).get("inetd", []):
		_inetd_remove(vfs, line)
	vfs.unlink(root, "%s/%s.list" % [INFO_DIR, name])
	vfs.unlink(root, "%s/%s.control" % [INFO_DIR, name])
	var db := installed(vfs)
	db.erase(name)
	_write_db(vfs, db)
	return AgoraErrno.OK


## Installed packages: name -> version.
static func installed(vfs: AgoraVfs) -> Dictionary:
	var out := {}
	for line in vfs.read_text(AgoraCred.root(), DB).split("\n", false):
		var words := line.split(" ", false)
		if words.size() >= 2:
			out[words[0]] = words[1]
	return out


static func files_of(vfs: AgoraVfs, name: String) -> PackedStringArray:
	return vfs.read_text(AgoraCred.root(), "%s/%s.list" % [INFO_DIR, name]).split("\n", false)


## [param names] plus everything they depend on, dependencies first.
## [param lookup] returns a package dictionary for a name ({} if unknown).
static func resolve(names: PackedStringArray, lookup: Callable) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	for n in names:
		_resolve_one(n, lookup, out, seen)
	return out


static func _resolve_one(name: String, lookup: Callable, out: Array[Dictionary], seen: Dictionary) -> void:
	if seen.has(name):
		return
	seen[name] = true
	var pkg: Dictionary = lookup.call(name)
	if pkg.is_empty():
		return
	for dep: String in pkg.get("depends", []):
		_resolve_one(dep, lookup, out, seen)
	out.append(pkg)


static func to_json(pkg: Dictionary) -> String:
	return JSON.stringify(pkg, "\t")


static func from_json(text: String) -> Dictionary:
	var data: Variant = JSON.parse_string(text)
	if not data is Dictionary:
		return {}
	# JSON turns numbers into floats: modes must be ints again.
	for section in ["dirs"]:
		var d: Dictionary = data.get(section, {})
		for k in d:
			d[k] = int(d[k])
	var files: Dictionary = data.get("files", {})
	for k in files:
		files[k] = [files[k][0], int(files[k][1])]
	return data


static func _record(vfs: AgoraVfs, pkg: Dictionary, owned: PackedStringArray) -> void:
	var root := AgoraCred.root()
	var name: String = pkg.name
	vfs.make_dirs(root, INFO_DIR)
	vfs.write_text(root, "%s/%s.list" % [INFO_DIR, name], "\n".join(owned) + "\n")
	var control := {"name": name, "version": pkg.get("version", "0"), "description": pkg.get("description", ""), "depends": pkg.get("depends", [])}
	for key in ["inetd", "users"]:
		if pkg.has(key):
			control[key] = pkg[key]
	vfs.write_text(root, "%s/%s.control" % [INFO_DIR, name], JSON.stringify(control))
	var db := installed(vfs)
	db[name] = pkg.get("version", "0")
	_write_db(vfs, db)


## Metadata of an installed package: {name, version, description, depends}.
static func control_of(vfs: AgoraVfs, name: String) -> Dictionary:
	var data: Variant = JSON.parse_string(vfs.read_text(AgoraCred.root(), "%s/%s.control" % [INFO_DIR, name]))
	return data if data is Dictionary else {}


static func _write_db(vfs: AgoraVfs, db: Dictionary) -> void:
	var names := db.keys()
	names.sort()
	var lines: PackedStringArray = []
	for n in names:
		lines.append("%s %s" % [n, db[n]])
	vfs.write_text(AgoraCred.root(), DB, "\n".join(lines) + ("\n" if not lines.is_empty() else ""))
