class_name AgoraUsers
extends RefCounted
## Account database of a machine. Everything lives in ordinary text files:
## /etc/passwd, /etc/group and /etc/shadow. Editing those files by hand (or
## by an intruder) changes the accounts, just like on a real system.
##
## Password hashes look like "$5$<salt>$<sha256 hex>". An empty field means
## no password. A field starting with "!" or "*" means the account is locked.

const PASSWD := "/etc/passwd"
const GROUP := "/etc/group"
const SHADOW := "/etc/shadow"
const FIRST_UID := 1000

var _vfs: AgoraVfs
var _root := AgoraCred.root()


func _init(vfs: AgoraVfs) -> void:
	_vfs = vfs


func _rows(path: String) -> Array[PackedStringArray]:
	var out: Array[PackedStringArray] = []
	for line in _vfs.read_text(_root, path).split("\n", false):
		if line.strip_edges().is_empty() or line.begins_with("#"):
			continue
		out.append(line.split(":"))
	return out


func _write_rows(path: String, rows: Array[PackedStringArray], mode: int) -> void:
	var lines: PackedStringArray = []
	for r in rows:
		lines.append(":".join(r))
	_vfs.write_text(_root, path, "\n".join(lines) + "\n", "/", false, mode)


static func _user_dict(r: PackedStringArray) -> Dictionary:
	if r.size() < 7:
		return {}
	return {"name": r[0], "uid": int(r[2]), "gid": int(r[3]), "gecos": r[4], "home": r[5], "shell": r[6]}


# --- users ------------------------------------------------------------------

func all() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in _rows(PASSWD):
		var u := _user_dict(r)
		if not u.is_empty():
			out.append(u)
	return out


## User record ({name, uid, gid, gecos, home, shell}) or {} if unknown.
func find(user_name: String) -> Dictionary:
	for u in all():
		if u.name == user_name:
			return u
	return {}


func find_uid(uid: int) -> Dictionary:
	for u in all():
		if u.uid == uid:
			return u
	return {}


func name_of(uid: int) -> String:
	var u := find_uid(uid)
	return u.name if not u.is_empty() else str(uid)


func cred_for(user_name: String) -> AgoraCred:
	var u := find(user_name)
	if u.is_empty():
		return null
	return AgoraCred.make(u.uid, u.gid, group_ids_for(user_name))


# --- groups -----------------------------------------------------------------

func all_groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for r in _rows(GROUP):
		if r.size() >= 3:
			var members := r[3].split(",", false) if r.size() > 3 else PackedStringArray()
			out.append({"name": r[0], "gid": int(r[2]), "members": members})
	return out


func find_group(group_name: String) -> Dictionary:
	for g in all_groups():
		if g.name == group_name:
			return g
	return {}


func group_name_of(gid: int) -> String:
	for g in all_groups():
		if g.gid == gid:
			return g.name
	return str(gid)


## Supplementary group ids of a user (groups that list them as a member).
func group_ids_for(user_name: String) -> PackedInt32Array:
	var out: PackedInt32Array = []
	for g in all_groups():
		if (g.members as PackedStringArray).has(user_name):
			out.append(g.gid)
	return out


func add_group(group_name: String, gid: int = -1) -> int:
	if not find_group(group_name).is_empty():
		return AgoraErrno.EEXIST
	if gid < 0:
		gid = FIRST_UID
		for g in all_groups():
			if g.gid >= gid:
				gid = g.gid + 1
	var rows := _rows(GROUP)
	rows.append(PackedStringArray([group_name, "x", str(gid), ""]))
	_write_rows(GROUP, rows, AgoraStat.MODE_FILE)
	return AgoraErrno.OK


func add_to_group(user_name: String, group_name: String) -> int:
	var rows := _rows(GROUP)
	for i in rows.size():
		var r := rows[i] # packed arrays are values: edit a copy, then store it
		if r[0] == group_name:
			while r.size() < 4:
				r.append("")
			var members := r[3].split(",", false)
			if not members.has(user_name):
				members.append(user_name)
			r[3] = ",".join(members)
			rows[i] = r
			_write_rows(GROUP, rows, AgoraStat.MODE_FILE)
			return AgoraErrno.OK
	return AgoraErrno.ENOENT


# --- passwords --------------------------------------------------------------

static func hash_password(password: String, salt: String = "") -> String:
	if salt.is_empty():
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		salt = "%08x" % rng.randi()
	return "$5$%s$%s" % [salt, (salt + password).sha256_text()]


func _shadow_field(user_name: String) -> Variant:
	for r in _rows(SHADOW):
		if r[0] == user_name:
			return r[1] if r.size() > 1 else ""
	return null


func check_password(user_name: String, password: String) -> bool:
	var field: Variant = _shadow_field(user_name)
	if field == null:
		return false
	var h: String = field
	if h.is_empty():
		return true
	if h.begins_with("!") or h.begins_with("*"):
		return false
	var parts := h.split("$")
	if parts.size() != 4:
		return false
	return hash_password(password, parts[2]) == h


func is_locked(user_name: String) -> bool:
	var field: Variant = _shadow_field(user_name)
	return field == null or (field as String).begins_with("!") or (field as String).begins_with("*")


## Sets a password. An empty [param password] removes it (login without one).
## Locks the account: "*" in /etc/shadow, as for system accounts.
func lock(user_name: String) -> int:
	set_password(user_name, "")
	var rows := _rows(SHADOW)
	for i in rows.size():
		if rows[i][0] == user_name:
			var r := rows[i]
			r[1] = "*"
			rows[i] = r
	_write_rows(SHADOW, rows, AgoraStat.MODE_PRIVATE_FILE)
	return AgoraErrno.OK


func set_password(user_name: String, password: String) -> int:
	var rows := _rows(SHADOW)
	var value := "" if password.is_empty() else hash_password(password)
	for i in rows.size():
		var r := rows[i]
		if r[0] == user_name:
			r[1] = value
			rows[i] = r
			_write_rows(SHADOW, rows, AgoraStat.MODE_PRIVATE_FILE)
			return AgoraErrno.OK
	rows.append(PackedStringArray([user_name, value]))
	_write_rows(SHADOW, rows, AgoraStat.MODE_PRIVATE_FILE)
	return AgoraErrno.OK


# --- account creation -------------------------------------------------------

## Creates a user with a private group of the same name, a home directory
## seeded from /etc/skel, and the given password. Returns the uid, or a
## negative errno.
func add_user(user_name: String, password: String = "", opts: Dictionary = {}) -> int:
	if not AgoraPath.is_valid_name(user_name) or user_name.contains(":"):
		return -AgoraErrno.EINVAL
	if not find(user_name).is_empty():
		return -AgoraErrno.EEXIST
	var uid: int = opts.get("uid", -1)
	if uid < 0:
		uid = FIRST_UID
		for u in all():
			if u.uid >= uid and u.uid < 60000:
				uid = u.uid + 1
	var gid := uid
	if find_group(user_name).is_empty():
		add_group(user_name, gid)
	else:
		gid = find_group(user_name).gid
	var home: String = opts.get("home", "/root" if uid == 0 else "/home/" + user_name)
	var shell: String = opts.get("shell", "/bin/sh")
	var rows := _rows(PASSWD)
	rows.append(PackedStringArray([user_name, "x", str(uid), str(gid), opts.get("gecos", ""), home, shell]))
	_write_rows(PASSWD, rows, AgoraStat.MODE_FILE)
	set_password(user_name, password)
	for g: String in opts.get("groups", []):
		add_to_group(user_name, g)
	if not _vfs.exists(_root, home):
		_vfs.make_dirs(_root, home)
		_copy_tree("/etc/skel", home, uid, gid)
		_vfs.chown(_root, home, uid, gid)
		_vfs.chmod(_root, home, AgoraStat.MODE_DIR)
	return uid


func _copy_tree(from: String, to: String, uid: int, gid: int) -> void:
	for name in _vfs.list_dir(_root, from):
		var src := from + "/" + name
		var dst := to + "/" + name
		var st := _vfs.stat(_root, src, "/", false)
		if st == null:
			continue
		if st.is_dir():
			_vfs.mkdir(_root, dst, "/", st.mode)
			_copy_tree(src, dst, uid, gid)
		elif st.is_file():
			_vfs.write_file(_root, dst, _vfs.read_file(_root, src), "/", false, st.mode)
		else:
			continue
		_vfs.chown(_root, dst, uid, gid, "/", false)
