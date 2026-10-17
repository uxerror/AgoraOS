class_name AgoraWmTheme
extends RefCounted
## Window decoration theme, read from a plain text file in the machine's
## file system (/usr/share/themes/<name>/wm.theme). One "key = value" per
## line, lines starting with "#" are comments. Unknown keys are ignored, missing keys keep
## their defaults.

var values := {
	"title_height": 24,
	"border": 4,
	"font_size": 14,
	"title_bg": Color("#1f3a5f"),
	"title_bg_inactive": Color("#3a3d42"),
	"title_fg": Color("#f0f0f0"),
	"title_fg_inactive": Color("#a0a4aa"),
	"border_color": Color("#0f1d30"),
	"border_color_inactive": Color("#26282c"),
	"button_fg": Color("#f0f0f0"),
	"button_hover": Color("#ffffff30"),
	"close_hover": Color("#c0392b"),
	"panel_bg": Color("#0f1d30"),
	"panel_fg": Color("#e0e4ea"),
}


static func parse(text: String) -> AgoraWmTheme:
	var t := AgoraWmTheme.new()
	for raw in text.split("\n"):
		# Only whole-line comments: values like "#1f3a5f" contain "#".
		var line := raw.strip_edges()
		if line.begins_with("#"):
			continue
		var eq := line.find("=")
		if eq <= 0:
			continue
		var key := line.substr(0, eq).strip_edges()
		var value := line.substr(eq + 1).strip_edges()
		if not t.values.has(key):
			continue
		if t.values[key] is Color:
			t.values[key] = Color.from_string(value, t.values[key])
		elif t.values[key] is int:
			t.values[key] = int(value)
	return t


## Loads the theme named in ~/.config/wm.conf or /etc/wm.conf ("theme=").
static func load_for(p: AgoraProcess) -> AgoraWmTheme:
	var theme_name := "agora"
	for conf in [p.home() + "/.config/wm.conf", "/etc/wm.conf"]:
		var name := _conf_value(p.read_text(conf), "theme")
		if not name.is_empty():
			theme_name = name
			break
	return parse(p.read_text("/usr/share/themes/%s/wm.theme" % theme_name))


static func _conf_value(text: String, key: String) -> String:
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.begins_with(key + "="):
			return l.substr(key.length() + 1).strip_edges()
	return ""


func color(key: String, active: bool = true) -> Color:
	if not active and values.has(key + "_inactive"):
		return values[key + "_inactive"]
	return values[key]


func num(key: String) -> int:
	return values[key]
