class_name AgoraGuiProgram
extends AgoraProgram
## Base for programs with windows. Like X11 clients, they find their display
## through the DISPLAY environment variable, so a shell on a headless server
## (or an ssh session) can't open windows.


## The display named by $DISPLAY, or null.
static func display_for(p: AgoraProcess) -> AgoraDisplay:
	var d := p.machine.display
	var wanted := p.getenv("DISPLAY")
	if d == null or wanted.is_empty() or wanted != d.name:
		return null
	return d


## Opens a window, or prints "cannot open display" and returns null.
func open_window(p: AgoraProcess, content: Control, opts: Dictionary = {}) -> AgoraWindow:
	var d := display_for(p)
	if d == null:
		content.free()
		p.fail("cannot open display: %s" % (p.getenv("DISPLAY") if not p.getenv("DISPLAY").is_empty() else "DISPLAY is not set"))
		return null
	return d.open_window(p, content, opts)


## Reads "key=value" from the first config file that has it.
static func conf_value(p: AgoraProcess, files: PackedStringArray, key: String, default: String = "") -> String:
	for f in files:
		for line in p.read_text(f).split("\n", false):
			var l := line.strip_edges()
			if l.begins_with(key + "="):
				return l.substr(key.length() + 1).strip_edges()
	return default


## Parses a freedesktop-style .desktop file into a dictionary of its keys.
static func parse_desktop_entry(text: String) -> Dictionary:
	var out := {}
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with("#") or l.begins_with("["):
			continue
		var eq := l.find("=")
		if eq > 0:
			out[l.substr(0, eq).strip_edges()] = l.substr(eq + 1).strip_edges()
	return out
