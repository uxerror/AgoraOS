class_name AgoraUnits
extends RefCounted
## Reading systemd-style unit files, shared by systemd and systemctl.
##
## Units are INI-like text files found in SEARCH_PATHS (earlier paths win, so
## /etc overrides the vendor files in /lib). A unit is enabled by a symlink in
## /etc/systemd/system/<target>.wants/. Runtime state lives in plain files
## under /run/systemd/units/, so anyone can read it.

const SEARCH_PATHS: PackedStringArray = ["/etc/systemd/system", "/run/systemd/system", "/lib/systemd/system"]
const ADMIN_DIR := "/etc/systemd/system"
const STATE_DIR := "/run/systemd/units"
const JOURNAL := "/var/log/journal/system.journal"


## "sshd" -> "sshd.service".
static func normalize(name: String) -> String:
	return name if name.contains(".") else name + ".service"


## Path of the unit file, or "".
static func find(p: AgoraProcess, name: String) -> String:
	for dir in SEARCH_PATHS:
		var path := dir + "/" + name
		var st := p.stat(path)
		if st != null and st.is_file():
			return path
	return ""


## {name, path, sections: {Section: {Key: [values]}}} or {} if not found.
static func read_unit(p: AgoraProcess, name: String) -> Dictionary:
	var path := find(p, name)
	if path.is_empty():
		return {}
	return {"name": name, "path": path, "sections": parse(p.read_text(path))}


static func parse(text: String) -> Dictionary:
	var sections := {}
	var current := ""
	for raw in text.split("\n"):
		var line := raw.strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with(";"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			current = line.substr(1, line.length() - 2)
			if not sections.has(current):
				sections[current] = {}
			continue
		var eq := line.find("=")
		if eq <= 0 or current.is_empty():
			continue
		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		if not sections[current].has(key):
			sections[current][key] = []
		sections[current][key].append(value)
	return sections


static func value(unit: Dictionary, section: String, key: String, default: String = "") -> String:
	var values: Array = unit.get("sections", {}).get(section, {}).get(key, [])
	return values[-1] if not values.is_empty() else default


## All whitespace-separated words of every [param key] line.
static func list(unit: Dictionary, section: String, key: String) -> PackedStringArray:
	var out: PackedStringArray = []
	for v: String in unit.get("sections", {}).get(section, {}).get(key, []):
		out.append_array(v.split(" ", false))
	return out


## Units linked from <name>.wants/ (or .requires/) directories.
static func linked(p: AgoraProcess, name: String, kind: String = "wants") -> PackedStringArray:
	var out: PackedStringArray = []
	for dir in SEARCH_PATHS:
		for entry in p.list_dir("%s/%s.%s" % [dir, name, kind]):
			if not out.has(entry):
				out.append(entry)
	return out


## "enabled", "disabled" or "static" (no [Install] section).
static func enablement(p: AgoraProcess, unit: Dictionary) -> String:
	for target in list(unit, "Install", "WantedBy"):
		if p.stat("%s/%s.wants/%s" % [ADMIN_DIR, target, unit.name], false) != null:
			return "enabled"
	if list(unit, "Install", "WantedBy").is_empty():
		return "static"
	return "disabled"


## Runtime state of a unit from /run/systemd/units/<name>, as a dictionary.
static func state(p: AgoraProcess, name: String) -> Dictionary:
	var out := {}
	for line in p.read_text(STATE_DIR + "/" + name).split("\n", false):
		var eq := line.find("=")
		if eq > 0:
			out[line.substr(0, eq)] = line.substr(eq + 1)
	return out


## Splits an Exec line into argv. Double quotes group words. A leading "-"
## (ignore failure) is dropped.
static func split_command(line: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur := ""
	var quoted := false
	var has := false
	for c in line.trim_prefix("-"):
		if c == "\"":
			quoted = not quoted
			has = true
		elif c == " " and not quoted:
			if has:
				out.append(cur)
			cur = ""
			has = false
		else:
			cur += c
			has = true
	if has:
		out.append(cur)
	return out
