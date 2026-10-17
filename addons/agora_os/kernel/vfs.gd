class_name AgoraVfs
extends RefCounted
## Virtual file system of one machine: a single tree rooted at "/", built from
## mounted [AgoraFs] backends.
##
## Every operation takes the caller's [AgoraCred] and current directory, and
## checks Unix permissions the way the real calls do. Operations return an
## errno code, or a value with the code left in [member errno]. Calls are
## synchronous, so reading [member errno] right after a call is safe even
## with many coroutine-based processes running.

const MAX_SYMLINKS := 16


## Outcome of resolving a path.
class Resolved:
	var err: int = AgoraErrno.OK
	## Canonical absolute path (symlinks resolved, except the last component
	## when it was resolved without following).
	var path := ""
	## Metadata of the entry, or null when it doesn't exist.
	var stat: AgoraStat
	## True when the parent directory exists and is searchable. Together with
	## err == ENOENT this means the entry can be created.
	var parent_ok := false
	var fs: AgoraFs
	var rel := ""


var errno: int = AgoraErrno.OK

var _mounts := {} # mount point -> AgoraFs
var _sources := {} # mount point -> device or label shown in /proc/mounts
var _now: Callable


## [param now_func] returns the current Unix time used for timestamps.
func _init(now_func: Callable) -> void:
	_now = now_func


# --- mounts -----------------------------------------------------------------

func mount(point: String, fs: AgoraFs, source: String = "") -> int:
	point = AgoraPath.normalize(point)
	if _mounts.has(point):
		return _status(AgoraErrno.EBUSY)
	_mounts[point] = fs
	_sources[point] = source if not source.is_empty() else fs.fs_type()
	return _status(AgoraErrno.OK)


func get_source(point: String) -> String:
	return _sources.get(point, "none")


## Unmounts [param fs] wherever it is mounted (media pulled out).
func unmount_fs(fs: AgoraFs) -> void:
	if fs == null:
		return
	for point: String in _mounts.keys():
		if _mounts[point] == fs and point != "/":
			_mounts.erase(point)
			_sources.erase(point)


## Mount point where [param fs] is mounted, or "".
func mount_point_of(fs: AgoraFs) -> String:
	for point: String in _mounts:
		if _mounts[point] == fs:
			return point
	return ""


func unmount(point: String) -> int:
	point = AgoraPath.normalize(point)
	if point == "/" or not _mounts.has(point):
		return _status(AgoraErrno.EINVAL)
	_mounts.erase(point)
	_sources.erase(point)
	return _status(AgoraErrno.OK)


func mount_points() -> PackedStringArray:
	var points := PackedStringArray(_mounts.keys())
	points.sort()
	return points


func get_mount(point: String) -> AgoraFs:
	return _mounts.get(point)


func is_mount_point(path: String) -> bool:
	return _mounts.has(path)


func _locate(abs_path: String) -> Array:
	var best := "/"
	for point: String in _mounts:
		if point.length() > best.length() and AgoraPath.is_inside(abs_path, point):
			best = point
	var rel := abs_path.substr(best.length()).lstrip("/")
	return [_mounts[best], rel]


func _lstat_abs(abs_path: String) -> AgoraStat:
	var loc := _locate(abs_path)
	return (loc[0] as AgoraFs).lstat(loc[1])


# --- permissions ------------------------------------------------------------

## True if [param cred] may access the entry described by [param st] with the
## [param want] bits ([constant AgoraStat.R], [constant AgoraStat.W],
## [constant AgoraStat.X]). Root may do anything, except execute a file that
## has no execute bit at all.
static func can_access(cred: AgoraCred, st: AgoraStat, want: int) -> bool:
	if cred.uid == 0:
		if want & AgoraStat.X and not st.is_dir():
			return st.mode & 73 != 0 # 0o111
		return true
	var bits: int
	if cred.uid == st.uid:
		bits = (st.mode >> 6) & 7
	elif cred.in_group(st.gid):
		bits = (st.mode >> 3) & 7
	else:
		bits = st.mode & 7
	return bits & want == want


# --- resolution -------------------------------------------------------------

func resolve(cred: AgoraCred, path: String, cwd: String = "/", follow_last: bool = true) -> Resolved:
	return _resolve(cred, path, cwd, follow_last, 0)


func _resolve(cred: AgoraCred, path: String, cwd: String, follow_last: bool, depth: int) -> Resolved:
	var r := Resolved.new()
	if path.is_empty():
		r.err = AgoraErrno.ENOENT
		return r
	var cur := "/" if path.begins_with("/") else cwd
	var cur_stat := _lstat_abs(cur)
	if cur_stat == null or not cur_stat.is_dir():
		r.err = AgoraErrno.ENOENT
		return r
	var parts := AgoraPath.components(path)
	for i in parts.size():
		var name := parts[i]
		var last := i == parts.size() - 1
		if not cur_stat.is_dir():
			r.err = AgoraErrno.ENOTDIR
			return r
		if name == ".":
			continue
		if name == "..":
			cur = AgoraPath.dirname(cur)
			cur_stat = _lstat_abs(cur)
			continue
		if not can_access(cred, cur_stat, AgoraStat.X):
			r.err = AgoraErrno.EACCES
			return r
		if name.length() > AgoraPath.MAX_NAME:
			r.err = AgoraErrno.ENAMETOOLONG
			return r
		var next := AgoraPath.join(cur, name)
		var st := _lstat_abs(next)
		if st == null:
			r.err = AgoraErrno.ENOENT
			if last:
				r.parent_ok = true
				r.path = next
				_fill_location(r)
			return r
		if st.is_symlink() and (follow_last or not last):
			if depth >= MAX_SYMLINKS:
				r.err = AgoraErrno.ELOOP
				return r
			var loc := _locate(next)
			var target := (loc[0] as AgoraFs).read_link(loc[1])
			var rest := "/".join(parts.slice(i + 1))
			var new_path := target if rest.is_empty() else target + "/" + rest
			return _resolve(cred, new_path, cur, follow_last, depth + 1)
		cur = next
		cur_stat = st
	r.path = cur
	r.stat = cur_stat
	r.parent_ok = true
	_fill_location(r)
	return r


func _fill_location(r: Resolved) -> void:
	var loc := _locate(r.path)
	r.fs = loc[0]
	r.rel = loc[1]


## Records [param code] in errno and returns it.
func _status(code: int) -> int:
	errno = code
	return code


func _check_parent_writable(cred: AgoraCred, path: String) -> int:
	var parent_stat := _lstat_abs(AgoraPath.dirname(path))
	if parent_stat == null:
		return AgoraErrno.ENOENT
	if not can_access(cred, parent_stat, AgoraStat.W | AgoraStat.X):
		return AgoraErrno.EACCES
	return AgoraErrno.OK


## Removing or renaming an entry needs write access to its directory. In a
## sticky directory such as /tmp, only the owner of the entry or of the
## directory (or root) may do it.
func _check_removable(cred: AgoraCred, r: Resolved) -> int:
	var parent_stat := _lstat_abs(AgoraPath.dirname(r.path))
	if parent_stat == null:
		return AgoraErrno.ENOENT
	if not can_access(cred, parent_stat, AgoraStat.W | AgoraStat.X):
		return AgoraErrno.EACCES
	if parent_stat.mode & AgoraStat.S_ISVTX and not cred.is_root() \
			and cred.uid != r.stat.uid and cred.uid != parent_stat.uid:
		return AgoraErrno.EPERM
	return AgoraErrno.OK


func _new_stat(cred: AgoraCred, type: AgoraStat.Type, mode: int) -> AgoraStat:
	var st := AgoraStat.new()
	st.type = type
	st.mode = mode & ~cred.umask & AgoraStat.PERM_MASK
	st.uid = cred.uid
	st.gid = cred.gid
	st.mtime = _now.call()
	return st


# --- queries ----------------------------------------------------------------

func stat(cred: AgoraCred, path: String, cwd: String = "/", follow: bool = true) -> AgoraStat:
	var r := resolve(cred, path, cwd, follow)
	_status(r.err)
	return r.stat if r.err == AgoraErrno.OK else null


func exists(cred: AgoraCred, path: String, cwd: String = "/") -> bool:
	return stat(cred, path, cwd) != null


func is_dir(cred: AgoraCred, path: String, cwd: String = "/") -> bool:
	var st := stat(cred, path, cwd)
	return st != null and st.is_dir()


## Canonical absolute path of an existing entry, or "" with errno set.
func realpath(cred: AgoraCred, path: String, cwd: String = "/") -> String:
	var r := resolve(cred, path, cwd)
	_status(r.err)
	return r.path if r.err == AgoraErrno.OK else ""


func list_dir(cred: AgoraCred, path: String, cwd: String = "/") -> PackedStringArray:
	var r := resolve(cred, path, cwd)
	if r.err != AgoraErrno.OK:
		_status(r.err)
		return []
	if not r.stat.is_dir():
		_status(AgoraErrno.ENOTDIR)
		return []
	if not can_access(cred, r.stat, AgoraStat.R):
		_status(AgoraErrno.EACCES)
		return []
	var names := r.fs.list_dir(r.rel)
	names.sort()
	_status(AgoraErrno.OK)
	return names


func read_link(cred: AgoraCred, path: String, cwd: String = "/") -> String:
	var r := resolve(cred, path, cwd, false)
	if r.err != AgoraErrno.OK:
		_status(r.err)
		return ""
	if not r.stat.is_symlink():
		_status(AgoraErrno.EINVAL)
		return ""
	_status(AgoraErrno.OK)
	return r.fs.read_link(r.rel)


# --- file contents ----------------------------------------------------------

func read_file(cred: AgoraCred, path: String, cwd: String = "/") -> PackedByteArray:
	var r := resolve(cred, path, cwd)
	if r.err != AgoraErrno.OK:
		_status(r.err)
		return PackedByteArray()
	if r.stat.is_dir():
		_status(AgoraErrno.EISDIR)
		return PackedByteArray()
	if not can_access(cred, r.stat, AgoraStat.R):
		_status(AgoraErrno.EACCES)
		return PackedByteArray()
	_status(AgoraErrno.OK)
	return r.fs.read_file(r.rel)


func read_text(cred: AgoraCred, path: String, cwd: String = "/") -> String:
	return read_file(cred, path, cwd).get_string_from_utf8()


## Writes [param data] to a file, creating it with [param mode] (minus the
## umask) if it doesn't exist.
func write_file(cred: AgoraCred, path: String, data: PackedByteArray, cwd: String = "/",
		append: bool = false, mode: int = AgoraStat.MODE_FILE) -> int:
	var r := resolve(cred, path, cwd)
	if r.err == AgoraErrno.OK:
		if r.stat.is_dir():
			return _status(AgoraErrno.EISDIR)
		if not can_access(cred, r.stat, AgoraStat.W):
			return _status(AgoraErrno.EACCES)
		return _status(r.fs.write_file(r.rel, data, append, _now.call()))
	if r.err != AgoraErrno.ENOENT or not r.parent_ok:
		return _status(r.err)
	var e := _check_parent_writable(cred, r.path)
	if e != AgoraErrno.OK:
		return _status(e)
	e = r.fs.create(r.rel, _new_stat(cred, AgoraStat.Type.FILE, mode))
	if e != AgoraErrno.OK:
		return _status(e)
	return _status(r.fs.write_file(r.rel, data, false, _now.call()))


func write_text(cred: AgoraCred, path: String, text: String, cwd: String = "/",
		append: bool = false, mode: int = AgoraStat.MODE_FILE) -> int:
	return write_file(cred, path, text.to_utf8_buffer(), cwd, append, mode)


# --- tree changes -----------------------------------------------------------

func mkdir(cred: AgoraCred, path: String, cwd: String = "/", mode: int = AgoraStat.MODE_DIR) -> int:
	var r := resolve(cred, path, cwd, false)
	if r.err == AgoraErrno.OK:
		return _status(AgoraErrno.EEXIST)
	if r.err != AgoraErrno.ENOENT or not r.parent_ok:
		return _status(r.err)
	var e := _check_parent_writable(cred, r.path)
	if e != AgoraErrno.OK:
		return _status(e)
	return _status(r.fs.create(r.rel, _new_stat(cred, AgoraStat.Type.DIR, mode)))


## Like "mkdir -p": creates missing parents and accepts existing directories.
func make_dirs(cred: AgoraCred, path: String, cwd: String = "/", mode: int = AgoraStat.MODE_DIR) -> int:
	var full := AgoraPath.normalize(path, cwd)
	var cur := ""
	for part in AgoraPath.components(full):
		cur += "/" + part
		var st := stat(cred, cur)
		if st != null:
			if not st.is_dir():
				return _status(AgoraErrno.ENOTDIR)
			continue
		if mkdir(cred, cur, "/", mode) != AgoraErrno.OK:
			return errno
	return _status(AgoraErrno.OK)


func unlink(cred: AgoraCred, path: String, cwd: String = "/") -> int:
	var r := resolve(cred, path, cwd, false)
	if r.err != AgoraErrno.OK:
		return _status(r.err)
	if r.stat.is_dir():
		return _status(AgoraErrno.EISDIR)
	var e := _check_removable(cred, r)
	if e != AgoraErrno.OK:
		return _status(e)
	return _status(r.fs.remove(r.rel))


func rmdir(cred: AgoraCred, path: String, cwd: String = "/") -> int:
	var r := resolve(cred, path, cwd, false)
	if r.err != AgoraErrno.OK:
		return _status(r.err)
	if not r.stat.is_dir():
		return _status(AgoraErrno.ENOTDIR)
	if r.path == "/" or _mounts.has(r.path):
		return _status(AgoraErrno.EBUSY)
	var e := _check_removable(cred, r)
	if e != AgoraErrno.OK:
		return _status(e)
	return _status(r.fs.remove(r.rel))


## rename(2): atomically renames or moves an entry within one file system,
## replacing a target file or empty directory.
func rename(cred: AgoraCred, from_path: String, to_path: String, cwd: String = "/") -> int:
	var a := resolve(cred, from_path, cwd, false)
	if a.err != AgoraErrno.OK:
		return _status(a.err)
	var b := resolve(cred, to_path, cwd, false)
	if b.err != AgoraErrno.OK and not (b.err == AgoraErrno.ENOENT and b.parent_ok):
		return _status(b.err)
	if a.path == "/" or _mounts.has(a.path) or _mounts.has(b.path):
		return _status(AgoraErrno.EBUSY)
	if a.fs != b.fs:
		return _status(AgoraErrno.EXDEV)
	if a.path == b.path:
		return _status(AgoraErrno.OK)
	if a.stat.is_dir() and AgoraPath.is_inside(b.path, a.path):
		return _status(AgoraErrno.EINVAL)
	var e := _check_removable(cred, a)
	if e != AgoraErrno.OK:
		return _status(e)
	e = _check_parent_writable(cred, b.path)
	if e != AgoraErrno.OK:
		return _status(e)
	if b.stat != null:
		if b.stat.is_dir() and not a.stat.is_dir():
			return _status(AgoraErrno.EISDIR)
		if not b.stat.is_dir() and a.stat.is_dir():
			return _status(AgoraErrno.ENOTDIR)
		e = _check_removable(cred, b)
		if e != AgoraErrno.OK:
			return _status(e)
		e = b.fs.remove(b.rel)
		if e != AgoraErrno.OK:
			return _status(e)
	return _status(a.fs.rename(a.rel, b.rel))


func symlink(cred: AgoraCred, target: String, link_path: String, cwd: String = "/") -> int:
	var r := resolve(cred, link_path, cwd, false)
	if r.err == AgoraErrno.OK:
		return _status(AgoraErrno.EEXIST)
	if r.err != AgoraErrno.ENOENT or not r.parent_ok:
		return _status(r.err)
	var e := _check_parent_writable(cred, r.path)
	if e != AgoraErrno.OK:
		return _status(e)
	var st := _new_stat(cred, AgoraStat.Type.SYMLINK, AgoraStat.MODE_SYMLINK)
	st.mode = AgoraStat.MODE_SYMLINK
	return _status(r.fs.create(r.rel, st, target))


# --- metadata changes -------------------------------------------------------

func chmod(cred: AgoraCred, path: String, mode: int, cwd: String = "/") -> int:
	var r := resolve(cred, path, cwd)
	if r.err != AgoraErrno.OK:
		return _status(r.err)
	if not cred.is_root() and cred.uid != r.stat.uid:
		return _status(AgoraErrno.EPERM)
	return _status(r.fs.set_mode(r.rel, mode))


## Changes owner and/or group (-1 keeps the current value). Only root may give
## files away. An owner may change the group to one they belong to.
func chown(cred: AgoraCred, path: String, uid: int, gid: int, cwd: String = "/", follow: bool = true) -> int:
	var r := resolve(cred, path, cwd, follow)
	if r.err != AgoraErrno.OK:
		return _status(r.err)
	if not cred.is_root():
		var giving_away := uid >= 0 and uid != r.stat.uid
		var bad_group := gid >= 0 and (cred.uid != r.stat.uid or not cred.in_group(gid))
		if giving_away or bad_group:
			return _status(AgoraErrno.EPERM)
	return _status(r.fs.set_owner(r.rel, uid, gid))


func touch_time(cred: AgoraCred, path: String, mtime: int = -1, cwd: String = "/") -> int:
	var r := resolve(cred, path, cwd)
	if r.err != AgoraErrno.OK:
		return _status(r.err)
	if not cred.is_root() and cred.uid != r.stat.uid and not can_access(cred, r.stat, AgoraStat.W):
		return _status(AgoraErrno.EACCES)
	return _status(r.fs.set_mtime(r.rel, _now.call() if mtime < 0 else mtime))
