class_name AgoraHostFs
extends AgoraFs
## Exposes a real directory of the player's computer inside a machine, for
## example under /mnt/host. This is the only way in or out of the sandbox.
## Every entry appears to belong to [member owner_uid] with ordinary modes,
## because the host's real permissions don't map onto in-game users.

var host_root: String
var owner_uid := 0
var owner_gid := 0


func _init(p_host_root: String, p_uid: int = 0, p_gid: int = 0) -> void:
	host_root = p_host_root.rstrip("/")
	owner_uid = p_uid
	owner_gid = p_gid
	DirAccess.make_dir_recursive_absolute(host_root)


func fs_type() -> String:
	return "hostfs"


func _abs(rel: String) -> String:
	return host_root if rel.is_empty() else host_root + "/" + rel


func lstat(rel: String) -> AgoraStat:
	var path := _abs(rel)
	var s := AgoraStat.new()
	s.uid = owner_uid
	s.gid = owner_gid
	if DirAccess.dir_exists_absolute(path):
		s.type = AgoraStat.Type.DIR
		s.mode = AgoraStat.MODE_DIR
		s.size = 4096
	elif FileAccess.file_exists(path):
		s.type = AgoraStat.Type.FILE
		s.mode = AgoraStat.MODE_FILE
		var f := FileAccess.open(path, FileAccess.READ)
		s.size = f.get_length() if f else 0
		s.mtime = FileAccess.get_modified_time(path)
	else:
		return null
	return s


func list_dir(rel: String) -> PackedStringArray:
	var d := DirAccess.open(_abs(rel))
	if d == null:
		return []
	d.include_hidden = true
	var out := d.get_directories()
	out.append_array(d.get_files())
	return out


func read_file(rel: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(_abs(rel))


func write_file(rel: String, data: PackedByteArray, append: bool, _mtime: int) -> int:
	if read_only:
		return AgoraErrno.EROFS
	var path := _abs(rel)
	var f: FileAccess
	if append and FileAccess.file_exists(path):
		f = FileAccess.open(path, FileAccess.READ_WRITE)
		if f:
			f.seek_end()
	else:
		f = FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return AgoraErrno.EIO
	f.store_buffer(data)
	return AgoraErrno.OK


func create(rel: String, stat: AgoraStat, _link_target: String = "") -> int:
	if read_only:
		return AgoraErrno.EROFS
	match stat.type:
		AgoraStat.Type.DIR:
			return AgoraErrno.OK if DirAccess.make_dir_absolute(_abs(rel)) == OK else AgoraErrno.EIO
		AgoraStat.Type.FILE:
			return AgoraErrno.OK if FileAccess.open(_abs(rel), FileAccess.WRITE) else AgoraErrno.EIO
	return AgoraErrno.EPERM # symlinks and devices can't be created on the host


func remove(rel: String) -> int:
	if read_only:
		return AgoraErrno.EROFS
	var path := _abs(rel)
	if DirAccess.dir_exists_absolute(path) and not list_dir(rel).is_empty():
		return AgoraErrno.ENOTEMPTY
	return AgoraErrno.OK if DirAccess.remove_absolute(path) == OK else AgoraErrno.EIO


func rename(from_rel: String, to_rel: String) -> int:
	if read_only:
		return AgoraErrno.EROFS
	return AgoraErrno.OK if DirAccess.rename_absolute(_abs(from_rel), _abs(to_rel)) == OK else AgoraErrno.EIO


func set_mode(_rel: String, _mode: int) -> int:
	return AgoraErrno.EPERM


func set_owner(_rel: String, _uid: int, _gid: int) -> int:
	return AgoraErrno.EPERM


func set_mtime(_rel: String, _mtime: int) -> int:
	return AgoraErrno.OK
