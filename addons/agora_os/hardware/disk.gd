class_name AgoraDisk
extends RefCounted
## A storage device: hard disk, CD-ROM, USB stick or router flash.
##
## A disk holds at most one file system (think of it as a single partition),
## or none until it is formatted with mkfs. Its contents live in an
## [AgoraMemFs], so a disk can be moved between machines, copied, or shipped
## by the game as a ready-made image.

enum Kind { HDD, CDROM, USB, FLASH }

var model := "Generic disk"
var kind: Kind = Kind.HDD
## Nominal size shown by lsblk. Not enforced yet.
var capacity_mb := 40960
var removable := false
var read_only := false
var label := ""
## The file system, or null while unformatted.
var fs: AgoraMemFs


static func make(p_kind: Kind, p_model: String, p_capacity_mb: int) -> AgoraDisk:
	var d := AgoraDisk.new()
	d.kind = p_kind
	d.model = p_model
	d.capacity_mb = p_capacity_mb
	d.removable = p_kind in [Kind.CDROM, Kind.USB]
	d.read_only = p_kind == Kind.CDROM
	return d


func is_formatted() -> bool:
	return fs != null


## Creates an empty file system, losing whatever was there.
func format() -> void:
	fs = AgoraMemFs.new()
	fs.read_only = read_only


## True if firmware can boot from it: it has a kernel at /boot/vmlinuz.
func is_bootable() -> bool:
	return fs != null and fs.lstat("boot/vmlinuz") != null


func size_text() -> String:
	if capacity_mb >= 1024:
		return "%dG" % (capacity_mb / 1024)
	return "%dM" % capacity_mb


func serialize() -> Dictionary:
	return {
		"model": model, "kind": kind, "capacity_mb": capacity_mb, "removable": removable,
		"read_only": read_only, "label": label, "fs": fs.serialize() if fs else null,
	}


static func deserialize(data: Dictionary) -> AgoraDisk:
	var d := AgoraDisk.new()
	d.model = data.get("model", d.model)
	d.kind = data.get("kind", Kind.HDD)
	d.capacity_mb = data.get("capacity_mb", d.capacity_mb)
	d.removable = data.get("removable", false)
	d.read_only = data.get("read_only", false)
	d.label = data.get("label", "")
	if data.get("fs") != null:
		d.fs = AgoraMemFs.new()
		d.fs.deserialize(data.fs)
		d.fs.read_only = d.read_only
	return d
