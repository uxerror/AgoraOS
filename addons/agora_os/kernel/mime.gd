class_name AgoraMime
extends RefCounted
## File types and default applications, freedesktop style:
## - /etc/mime.types maps extensions to types ("text/plain txt md log")
## - /usr/share/applications/*.desktop list the types an app opens
##   ("MimeType=text/plain;text/*;")
## - ~/.config/mimeapps.list picks a default per type
##   ("text/plain=edit.desktop"), overriding the system choice
## Everything is read from files at the time of the call.

const DIRECTORY := "inode/directory"
const DEVICE := "inode/chardevice"
const EXECUTABLE := "application/x-executable"
const BINARY := "application/octet-stream"
const TEXT := "text/plain"
const APPS_DIR := "/usr/share/applications"


## MIME type of [param path] as seen by [param p] (follows symlinks).
static func type_of(p: AgoraProcess, path: String) -> String:
	var st := p.stat(path)
	if st == null:
		return ""
	if st.is_dir():
		return DIRECTORY
	if st.is_device():
		return DEVICE
	var ext := AgoraPath.basename(path).get_extension().to_lower()
	if not ext.is_empty():
		for line in p.read_text("/etc/mime.types").split("\n", false):
			if line.begins_with("#"):
				continue
			var words := line.split(" ", false)
			if words.size() > 1 and words.slice(1).has(ext):
				return words[0]
	var head := p.read_bytes(path).slice(0, 512)
	if head.has(0):
		return BINARY
	var text := head.get_string_from_utf8()
	if text.begins_with(AgoraMachine.EXEC_MAGIC) or (text.begins_with("#!") and st.mode & 73):
		return EXECUTABLE
	return TEXT


## The .desktop entry (as a dictionary, with "_id" set to its file name)
## that opens [param mime], or {} if none does.
static func app_for(p: AgoraProcess, mime: String) -> Dictionary:
	var wanted := _user_default(p, mime)
	var entries := applications(p)
	if not wanted.is_empty():
		for e in entries:
			if e._id == wanted:
				return e
	var fallback := {}
	for e in entries:
		var types := (e.get("MimeType", "") as String).split(";", false)
		if types.has(mime):
			return e
		var family := mime.get_slice("/", 0) + "/*"
		if fallback.is_empty() and types.has(family):
			fallback = e
	return fallback


## Every .desktop entry in /usr/share/applications.
static func applications(p: AgoraProcess) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for name in p.list_dir(APPS_DIR):
		if not name.ends_with(".desktop"):
			continue
		var e := parse_entry(p.read_text(APPS_DIR + "/" + name))
		if e.has("Exec"):
			e["_id"] = name
			out.append(e)
	return out


static func parse_entry(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with("#") or l.begins_with("["):
			continue
		var eq := l.find("=")
		if eq > 0:
			out[l.substr(0, eq).strip_edges()] = l.substr(eq + 1).strip_edges()
	return out


## Command line for opening [param path] with [param entry]: "%f" in Exec is
## replaced by the path, or the path is appended if there is no "%f".
static func command_for(entry: Dictionary, path: String) -> PackedStringArray:
	var argv := (entry.get("Exec", "") as String).split(" ", false)
	var placed := false
	for i in argv.size():
		if argv[i] in ["%f", "%F", "%u", "%U"]:
			argv[i] = path
			placed = true
	if not placed and not path.is_empty():
		argv.append(path)
	return argv


static func _user_default(p: AgoraProcess, mime: String) -> String:
	for line in p.read_text(p.home() + "/.config/mimeapps.list").split("\n", false):
		var l := line.strip_edges()
		if l.begins_with(mime + "="):
			return l.substr(mime.length() + 1).get_slice(";", 0)
	return ""
