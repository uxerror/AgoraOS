class_name AgoraIrc
extends RefCounted
## IRC lines (RFC 1459): ":prefix COMMAND param param :trailing", ending
## in CR LF. Shared by ircd, ircbot and Parley.

const PORT := 6667


## A line taken apart: {prefix, nick (from the prefix), cmd, params}; the
## last parameter may hold spaces.
static func parse(text: String) -> Dictionary:
	text = text.trim_suffix("\r")
	var prefix := ""
	if text.begins_with(":"):
		prefix = text.substr(1).get_slice(" ", 0)
		text = text.substr(prefix.length() + 2)
	var params: PackedStringArray = []
	while not text.is_empty():
		if text.begins_with(":"):
			params.append(text.substr(1))
			break
		var sp := text.find(" ")
		if sp < 0:
			params.append(text)
			break
		if sp > 0:
			params.append(text.substr(0, sp))
		text = text.substr(sp + 1)
	var cmd := params[0].to_upper() if not params.is_empty() else ""
	return {"prefix": prefix, "nick": prefix.get_slice("!", 0), "cmd": cmd, "params": params.slice(1)}


static func is_channel(name: String) -> bool:
	return name.begins_with("#") or name.begins_with("&")


## CTCP ACTION (/me): "\u0001ACTION waves\u0001" -> "waves", else "".
static func action(text: String) -> String:
	if text.begins_with("\u0001ACTION ") and text.ends_with("\u0001"):
		return text.substr(8, text.length() - 9)
	return ""
