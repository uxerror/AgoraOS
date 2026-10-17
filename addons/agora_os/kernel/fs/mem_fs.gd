class_name AgoraMemFs
extends AgoraFs
## In-memory file system tree. This is the main storage of a machine. It is
## saved as a whole through [method serialize], so every machine is one
## self-contained image that the game can ship, copy or reset.


class Entry:
	var stat := AgoraStat.new()
	var children := {} # name -> Entry, directories only
	var data := PackedByteArray()
	var target := "" # symlinks only


var _root: Entry


func _init() -> void:
	_root = Entry.new()
	_root.stat.type = AgoraStat.Type.DIR
	_root.stat.mode = AgoraStat.MODE_DIR


func fs_type() -> String:
	return "memfs"


func _find(rel: String) -> Entry:
	var e := _root
	for part in rel.split("/", false):
		if e.stat.type != AgoraStat.Type.DIR or not e.children.has(part):
			return null
		e = e.children[part]
	return e


func _split(rel: String) -> Array:
	var idx := rel.rfind("/")
	if idx < 0:
		return [_root, rel]
	return [_find(rel.substr(0, idx)), rel.substr(idx + 1)]


func lstat(rel: String) -> AgoraStat:
	var e := _find(rel)
	if e == null:
		return null
	var s := e.stat.duplicate_stat()
	match s.type:
		AgoraStat.Type.FILE: s.size = e.data.size()
		AgoraStat.Type.SYMLINK: s.size = e.target.length()
		AgoraStat.Type.DIR: s.size = 4096
	return s


func list_dir(rel: String) -> PackedStringArray:
	var e := _find(rel)
	if e == null or e.stat.type != AgoraStat.Type.DIR:
		return []
	return PackedStringArray(e.children.keys())


func read_file(rel: String) -> PackedByteArray:
	var e := _find(rel)
	return e.data if e != null else PackedByteArray()


func write_file(rel: String, data: PackedByteArray, append: bool, mtime: int) -> int:
	if read_only:
		return AgoraErrno.EROFS
	var e := _find(rel)
	if e == null:
		return AgoraErrno.ENOENT
	if append:
		e.data.append_array(data)
	else:
		e.data = data.duplicate()
	e.stat.mtime = mtime
	return AgoraErrno.OK


func create(rel: String, stat: AgoraStat, link_target: String = "") -> int:
	if read_only:
		return AgoraErrno.EROFS
	var split := _split(rel)
	var parent: Entry = split[0]
	if parent == null or parent.stat.type != AgoraStat.Type.DIR:
		return AgoraErrno.ENOENT
	if parent.children.has(split[1]):
		return AgoraErrno.EEXIST
	var e := Entry.new()
	e.stat = stat.duplicate_stat()
	e.target = link_target
	parent.children[split[1]] = e
	parent.stat.mtime = stat.mtime
	return AgoraErrno.OK


func remove(rel: String) -> int:
	if read_only:
		return AgoraErrno.EROFS
	var split := _split(rel)
	var parent: Entry = split[0]
	if parent == null or not parent.children.has(split[1]):
		return AgoraErrno.ENOENT
	var e: Entry = parent.children[split[1]]
	if e.stat.type == AgoraStat.Type.DIR and not e.children.is_empty():
		return AgoraErrno.ENOTEMPTY
	parent.children.erase(split[1])
	return AgoraErrno.OK


func rename(from_rel: String, to_rel: String) -> int:
	if read_only:
		return AgoraErrno.EROFS
	var src := _split(from_rel)
	var dst := _split(to_rel)
	var src_parent: Entry = src[0]
	var dst_parent: Entry = dst[0]
	if src_parent == null or not src_parent.children.has(src[1]):
		return AgoraErrno.ENOENT
	if dst_parent == null or dst_parent.stat.type != AgoraStat.Type.DIR:
		return AgoraErrno.ENOENT
	var e: Entry = src_parent.children[src[1]]
	src_parent.children.erase(src[1])
	dst_parent.children[dst[1]] = e
	return AgoraErrno.OK


func set_mode(rel: String, mode: int) -> int:
	var e := _find(rel)
	if e == null:
		return AgoraErrno.ENOENT
	e.stat.mode = mode & AgoraStat.PERM_MASK
	return AgoraErrno.OK


func set_owner(rel: String, uid: int, gid: int) -> int:
	var e := _find(rel)
	if e == null:
		return AgoraErrno.ENOENT
	if uid >= 0:
		e.stat.uid = uid
	if gid >= 0:
		e.stat.gid = gid
	return AgoraErrno.OK


func set_mtime(rel: String, mtime: int) -> int:
	var e := _find(rel)
	if e == null:
		return AgoraErrno.ENOENT
	e.stat.mtime = mtime
	return AgoraErrno.OK


func read_link(rel: String) -> String:
	var e := _find(rel)
	return e.target if e != null else ""


func serialize() -> Dictionary:
	return _entry_to_dict(_root)


func deserialize(data: Dictionary) -> void:
	_root = _entry_from_dict(data)


func _entry_to_dict(e: Entry) -> Dictionary:
	var d := {
		"t": e.stat.type, "m": e.stat.mode, "u": e.stat.uid,
		"g": e.stat.gid, "time": e.stat.mtime,
	}
	match e.stat.type:
		AgoraStat.Type.DIR:
			var kids := {}
			for name in e.children:
				kids[name] = _entry_to_dict(e.children[name])
			d["c"] = kids
		AgoraStat.Type.SYMLINK:
			d["l"] = e.target
		_:
			d["d"] = e.data
	return d


func _entry_from_dict(d: Dictionary) -> Entry:
	var e := Entry.new()
	e.stat.type = d.get("t", AgoraStat.Type.FILE)
	e.stat.mode = d.get("m", AgoraStat.MODE_FILE)
	e.stat.uid = d.get("u", 0)
	e.stat.gid = d.get("g", 0)
	e.stat.mtime = d.get("time", 0)
	e.target = d.get("l", "")
	e.data = d.get("d", PackedByteArray())
	var kids: Dictionary = d.get("c", {})
	for name in kids:
		e.children[name] = _entry_from_dict(kids[name])
	return e
