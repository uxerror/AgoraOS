class_name AgoraFs
extends RefCounted
## Base class for a mountable file system backend.
##
## Paths given to a backend are relative to its mount root ("" is the root,
## "etc/passwd" a file) and are already resolved: they never contain ".", ".."
## or symlinks in the middle. Permission checks are done by [AgoraVfs] before
## any backend call, so backends only store and fetch data.

## A read-only backend makes every write fail with EROFS.
var read_only := false


## Short type label shown in /proc/mounts.
func fs_type() -> String:
	return "none"


## Metadata of the entry, or null if it doesn't exist. Doesn't follow symlinks.
func lstat(_rel: String) -> AgoraStat:
	return null


func list_dir(_rel: String) -> PackedStringArray:
	return []


func read_file(_rel: String) -> PackedByteArray:
	return PackedByteArray()


## Writes into an existing regular file or device.
func write_file(_rel: String, _data: PackedByteArray, _append: bool, _mtime: int) -> int:
	return AgoraErrno.EROFS


## Creates a new entry. [param stat] carries type, mode, uid, gid and mtime.
## [param link_target] is only used for symlinks.
func create(_rel: String, _stat: AgoraStat, _link_target: String = "") -> int:
	return AgoraErrno.EROFS


## Removes a file, symlink or empty directory.
func remove(_rel: String) -> int:
	return AgoraErrno.EROFS


func rename(_from_rel: String, _to_rel: String) -> int:
	return AgoraErrno.EROFS


func set_mode(_rel: String, _mode: int) -> int:
	return AgoraErrno.EROFS


func set_owner(_rel: String, _uid: int, _gid: int) -> int:
	return AgoraErrno.EROFS


func set_mtime(_rel: String, _mtime: int) -> int:
	return AgoraErrno.EROFS


func read_link(_rel: String) -> String:
	return ""


## Persistent backends return their whole state here so the machine can be
## saved. Volatile ones (proc, dev, host) return an empty dictionary.
func serialize() -> Dictionary:
	return {}


func deserialize(_data: Dictionary) -> void:
	pass
