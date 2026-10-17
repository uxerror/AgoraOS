class_name AgoraCred
extends RefCounted
## Identity a process acts with. [member uid] is the effective user and is
## used for permission checks. [member ruid] is the real user, which setuid
## programs such as su look at to see who called them.

var uid: int = 0
var gid: int = 0
var ruid: int = 0
var groups: PackedInt32Array = []
var umask: int = 18 # 0o022


static func make(p_uid: int, p_gid: int, p_groups: PackedInt32Array = []) -> AgoraCred:
	var c := AgoraCred.new()
	c.uid = p_uid
	c.ruid = p_uid
	c.gid = p_gid
	c.groups = p_groups
	return c


static func root() -> AgoraCred:
	return make(0, 0)


func is_root() -> bool:
	return uid == 0


func in_group(p_gid: int) -> bool:
	return gid == p_gid or groups.has(p_gid)


func copy() -> AgoraCred:
	var c := AgoraCred.new()
	c.uid = uid
	c.gid = gid
	c.ruid = ruid
	c.groups = groups.duplicate()
	c.umask = umask
	return c
