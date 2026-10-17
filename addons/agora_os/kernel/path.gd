class_name AgoraPath
extends RefCounted
## Pure string helpers for absolute Unix paths. They never touch a file system,
## so ".." is resolved lexically here. The VFS resolves symlinks properly.

const MAX_NAME := 255


## Joins [param path] to [param cwd] if relative and collapses ".", ".." and
## repeated slashes. The result always starts with "/" and has no trailing slash.
static func normalize(path: String, cwd: String = "/") -> String:
	var full := path if path.begins_with("/") else cwd + "/" + path
	var out: PackedStringArray = []
	for part in full.split("/", false):
		if part == ".":
			continue
		if part == "..":
			if not out.is_empty():
				out.remove_at(out.size() - 1)
			continue
		out.append(part)
	return "/" + "/".join(out)


static func join(base: String, name: String) -> String:
	if name.begins_with("/"):
		return name
	if base.ends_with("/"):
		return base + name
	return base + "/" + name


static func dirname(path: String) -> String:
	var p := path.rstrip("/")
	if p.is_empty():
		return "/"
	var idx := p.rfind("/")
	if idx < 0:
		return "."
	if idx == 0:
		return "/"
	return p.substr(0, idx)


static func basename(path: String) -> String:
	var p := path.rstrip("/")
	if p.is_empty():
		return "/"
	return p.substr(p.rfind("/") + 1)


static func components(path: String) -> PackedStringArray:
	return path.split("/", false)


## True if [param name] is usable as a single directory entry name.
static func is_valid_name(name: String) -> bool:
	return not name.is_empty() and name != "." and name != ".." \
		and not name.contains("/") and name.length() <= MAX_NAME


## True if [param path] equals [param ancestor] or lies below it.
static func is_inside(path: String, ancestor: String) -> bool:
	if ancestor == "/":
		return true
	return path == ancestor or path.begins_with(ancestor + "/")
