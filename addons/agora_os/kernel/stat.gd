class_name AgoraStat
extends RefCounted
## Metadata of a file system entry, like the result of stat(2).
## GDScript has no octal literals, so permission constants are decimal
## with the octal value in a comment.

enum Type { FILE, DIR, SYMLINK, DEVICE }

const S_ISUID := 2048 # 0o4000
const S_ISGID := 1024 # 0o2000
const S_ISVTX := 512 # 0o1000 (sticky)
const PERM_MASK := 4095 # 0o7777

const MODE_DIR := 493 # 0o755
const MODE_FILE := 420 # 0o644
const MODE_EXEC := 493 # 0o755
const MODE_PRIVATE_DIR := 448 # 0o700
const MODE_PRIVATE_FILE := 384 # 0o600
const MODE_TMP := 1023 # 0o1777
const MODE_SYMLINK := 511 # 0o777

const R := 4
const W := 2
const X := 1

var type: Type = Type.FILE
var mode: int = MODE_FILE
var uid: int = 0
var gid: int = 0
var size: int = 0
var mtime: int = 0


func is_file() -> bool:
	return type == Type.FILE


func is_dir() -> bool:
	return type == Type.DIR


func is_symlink() -> bool:
	return type == Type.SYMLINK


func is_device() -> bool:
	return type == Type.DEVICE


func duplicate_stat() -> AgoraStat:
	var s := AgoraStat.new()
	s.type = type
	s.mode = mode
	s.uid = uid
	s.gid = gid
	s.size = size
	s.mtime = mtime
	return s


## "drwxr-xr-x" style string, including setuid/setgid/sticky markers.
func mode_string() -> String:
	var t := "-"
	match type:
		Type.DIR: t = "d"
		Type.SYMLINK: t = "l"
		Type.DEVICE: t = "c"
	var chars := "rwxrwxrwx"
	var out: PackedStringArray = [t]
	for i in 9:
		out.append(chars[i] if mode & (1 << (8 - i)) else "-")
	if mode & S_ISUID:
		out[3] = "s" if out[3] == "x" else "S"
	if mode & S_ISGID:
		out[6] = "s" if out[6] == "x" else "S"
	if mode & S_ISVTX:
		out[9] = "t" if out[9] == "x" else "T"
	return "".join(out)


## Formats a permission value as an octal string, for example 493 -> "755".
static func to_octal(value: int) -> String:
	if value == 0:
		return "0"
	var out := ""
	while value > 0:
		out = str(value & 7) + out
		value >>= 3
	return out


## Parses an octal string such as "0755" or "644". Returns -1 if invalid.
static func parse_octal(text: String) -> int:
	if text.is_empty() or text.length() > 5:
		return -1
	var value := 0
	for c in text:
		if c < "0" or c > "7":
			return -1
		value = value * 8 + int(c)
	return value
