class_name AgoraPackages
extends RefCounted
## Installs and removes packages (see [AgoraDistro] for the format) on a
## file system, and keeps the database of what is installed:
##   /var/lib/apkg/installed        "name version" per line
##   /var/lib/apkg/info/<name>.list  files the package put on disk
##   /var/lib/apkg/info/<name>.control  version, description, depends (JSON)

const DB := "/var/lib/apkg/installed"
const INFO_DIR := "/var/lib/apkg/info"


## The configuration files of a package: what it puts under /etc, plus
## any it lists in "conffiles".
static func conffiles_of(pkg: Dictionary) -> PackedStringArray:
	var out: PackedStringArray = []
	for path: String in pkg.get("files", {}):
		if path.begins_with("/etc/") or (pkg.get("conffiles", []) as Array).has(path):
			out.append(path)
	return out


## Configuration files that the user changed and [param pkg] changes too:
## the ones an upgrade has to ask about.
static func changed_conffiles(vfs: AgoraVfs, pkg: Dictionary) -> PackedStringArray:
	var root := AgoraCred.root()
	var old_conf: Dictionary = control_of(vfs, str(pkg.name)).get("conffiles", {})
	var files: Dictionary = pkg.get("files", {})
	var out: PackedStringArray = []
	for path in conffiles_of(pkg):
		if not old_conf.has(path) or not vfs.exists(root, path):
			continue
		var shipped := _md5_text(str(files[path][0]))
		var current := _md5_text(vfs.read_text(root, path))
		if current != str(old_conf[path]) and current != shipped and shipped != str(old_conf[path]):
			out.append(path)
	return out


## Installs [param pkg] onto [param vfs] as root, over an older (or the
## same) version if there is one. With [param only_missing], files that
## already exist are left alone (a system brought up to date at boot).
##
## Configuration files are handled as dpkg does: one the user hasn't
## changed is replaced; a changed one stays, and the new version is put
## next to it as FILE.dpkg-dist, unless [param keep_conf] (called with the
## path) returns false: then the new one is installed and the old moved to
## FILE.dpkg-old;
## one the user deleted stays deleted. Files of the old version that the
## new one doesn't have are removed. Returns what dpkg would have said.
static func install(vfs: AgoraVfs, pkg: Dictionary, only_missing: bool = false, keep_conf: Callable = Callable()) -> PackedStringArray:
	var root := AgoraCred.root()
	var notes: PackedStringArray = []
	var name: String = pkg.name
	var old := control_of(vfs, name)
	var old_conf: Dictionary = old.get("conffiles", {})
	var old_files := files_of(vfs, name) if not old.is_empty() else PackedStringArray()
	var conf := conffiles_of(pkg)
	var conf_md5 := {}
	var owned: PackedStringArray = []
	var dirs: Dictionary = pkg.get("dirs", {})
	for path: String in dirs:
		if not vfs.exists(root, path):
			vfs.make_dirs(root, path)
			vfs.chmod(root, path, dirs[path])
	var files: Dictionary = pkg.get("files", {})
	for path: String in files:
		owned.append(path)
		var entry: Array = files[path]
		var exists := vfs.stat(root, path, "/", false) != null
		if conf.has(path):
			var shipped := _md5_text(str(entry[0]))
			conf_md5[path] = shipped
			if old_conf.has(path):
				if not exists:
					continue # deleted on purpose: dpkg doesn't bring it back
				var current := _md5_text(vfs.read_text(root, path))
				if current != str(old_conf[path]) and current != shipped:
					if shipped == str(old_conf[path]):
						continue # changed here, not by the package: keep it quietly
					notes.append("Configuration file `%s'" % path)
					notes.append(" ==> Modified (by you or by a script) since installation.")
					notes.append(" ==> Package distributor has shipped an updated version.")
					if keep_conf.is_valid() and not keep_conf.call(path):
						notes.append(" ==> Installing new version of config file %s ..." % path)
						vfs.rename(root, path, path + ".dpkg-old")
					else:
						notes.append(" ==> Keeping old config file as default.")
						_write(vfs, path + ".dpkg-dist", entry)
						continue
		if only_missing and exists:
			continue
		_write(vfs, path, entry)
	for prog: String in pkg.get("programs", []):
		var path := AgoraPrograms.path_for(prog)
		owned.append(path)
		if only_missing and vfs.stat(root, path, "/", false) != null:
			continue
		write_binary(vfs, prog, path)
	# What the old version had and this one doesn't.
	# (Old configuration files stay, as dpkg keeps them.)
	for path in old_files:
		if owned.has(path) or (pkg.get("links", {}) as Dictionary).has(path) or old_conf.has(path):
			continue
		var st := vfs.stat(root, path, "/", false)
		if st != null and not st.is_dir():
			vfs.unlink(root, path)
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
	_record(vfs, pkg, owned, conf_md5)
	return notes


static func _write(vfs: AgoraVfs, path: String, entry: Array) -> void:
	var root := AgoraCred.root()
	vfs.make_dirs(root, AgoraPath.dirname(path))
	vfs.write_text(root, path, entry[0], "/", false, entry[1])
	vfs.chmod(root, path, entry[1])


static func _md5_text(text: String) -> String:
	return text.md5_text()


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


## Removes the files of an installed package. Directories stay, and so
## do its configuration files unless [param purge]: the package is then
## left in the "config-files" state, and a later install finds them.
## Purging a package that was removed takes the rest.
static func remove(vfs: AgoraVfs, name: String, purge: bool = false) -> int:
	var root := AgoraCred.root()
	var control := control_of(vfs, name)
	if not installed(vfs).has(name) and not (purge and not control.is_empty()):
		return AgoraErrno.ENOENT
	var conf: Dictionary = control.get("conffiles", {})
	for path in files_of(vfs, name):
		if conf.has(path) and not purge:
			continue
		var st := vfs.stat(root, path, "/", false)
		if st != null and not st.is_dir():
			vfs.unlink(root, path)
		for extra in [".dpkg-dist", ".dpkg-old"]:
			if purge and vfs.exists(root, path + extra):
				vfs.unlink(root, path + extra)
	for line: String in control.get("inetd", []):
		_inetd_remove(vfs, line)
	if purge:
		vfs.unlink(root, "%s/%s.list" % [INFO_DIR, name])
		vfs.unlink(root, "%s/%s.control" % [INFO_DIR, name])
	else:
		# Keep the record of the configuration files.
		vfs.write_text(root, "%s/%s.list" % [INFO_DIR, name], "\n".join(PackedStringArray(conf.keys())) + ("\n" if not conf.is_empty() else ""))
		control.status = "config-files"
		vfs.write_text(root, "%s/%s.control" % [INFO_DIR, name], JSON.stringify(control))
	var db := installed(vfs)
	db.erase(name)
	_write_db(vfs, db)
	return AgoraErrno.OK


## Packages removed but not purged: their configuration files are still there.
static func config_only(vfs: AgoraVfs) -> PackedStringArray:
	var out: PackedStringArray = []
	var db := installed(vfs)
	for f in vfs.list_dir(AgoraCred.root(), INFO_DIR):
		if f.ends_with(".control") and not db.has(f.trim_suffix(".control")):
			out.append(f.trim_suffix(".control"))
	out.sort()
	return out


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
		# "a | b (>= 1.0)": the first alternative there is.
		for alt in dep.split("|", false):
			var dep_name := alt.get_slice("(", 0).strip_edges()
			if not (lookup.call(dep_name) as Dictionary).is_empty():
				_resolve_one(dep_name, lookup, out, seen)
				break
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


static func _record(vfs: AgoraVfs, pkg: Dictionary, owned: PackedStringArray, conf_md5: Dictionary = {}) -> void:
	var root := AgoraCred.root()
	var name: String = pkg.name
	vfs.make_dirs(root, INFO_DIR)
	vfs.write_text(root, "%s/%s.list" % [INFO_DIR, name], "\n".join(owned) + "\n")
	var control := {"name": name, "version": pkg.get("version", "0"), "description": pkg.get("description", ""), "depends": pkg.get("depends", [])}
	for key in ["inetd", "users", "provides", "conflicts", "replaces", "maintainer"]:
		if pkg.has(key):
			control[key] = pkg[key]
	if not conf_md5.is_empty():
		control.conffiles = conf_md5
	vfs.write_text(root, "%s/%s.control" % [INFO_DIR, name], JSON.stringify(control))
	var db := installed(vfs)
	db[name] = pkg.get("version", "0")
	_write_db(vfs, db)


## Metadata of an installed package: {name, version, description, depends}.
static func control_of(vfs: AgoraVfs, name: String) -> Dictionary:
	var text := vfs.read_text(AgoraCred.root(), "%s/%s.control" % [INFO_DIR, name])
	if text.is_empty():
		return {}
	var data: Variant = JSON.parse_string(text)
	return data if data is Dictionary else {}


static func _write_db(vfs: AgoraVfs, db: Dictionary) -> void:
	var names := db.keys()
	names.sort()
	var lines: PackedStringArray = []
	for n in names:
		lines.append("%s %s" % [n, db[n]])
	vfs.write_text(AgoraCred.root(), DB, "\n".join(lines) + ("\n" if not lines.is_empty() else ""))
