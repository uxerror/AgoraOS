class_name AgoraShParser
extends RefCounted
## Turns lexer tokens into a command list.
##
## Result shape:
## [codeblock]
## items:    [{pipeline, op}]          op joins to the next item: ; && || &
## pipeline: {cmds: [cmd], negate: bool, text: String}
## cmd:      {assigns: [[name, parts]], words: [parts], redirs: [{op, target}]}
## [/codeblock]
## Control flow (if, for, while, functions) is not supported yet. The shape
## leaves room to add those as new node kinds later.

const REDIRS_WITH_TARGET: PackedStringArray = [">", ">>", "<", "2>", "2>>", "&>"]
const REDIRS_DUP: PackedStringArray = ["2>&1", ">&2"]
const SEPARATORS: PackedStringArray = [";", "&&", "||", "&"]


## Returns {"items": Array, "error": String}.
static func parse(tokens: Array) -> Dictionary:
	var items: Array = []
	var cmds: Array = []
	var cmd := _new_cmd()
	var negate := false
	var pending_redir := ""
	var words_text: PackedStringArray = []

	for t: Dictionary in tokens:
		if t.k == "word":
			if not pending_redir.is_empty():
				cmd.redirs.append({"op": pending_redir, "target": t.parts})
				pending_redir = ""
				continue
			if cmd.words.is_empty() and cmd.redirs.is_empty() and cmds.is_empty() \
					and not negate and _is_bang(t.parts):
				negate = true
				continue
			var assign := _as_assignment(t.parts)
			if cmd.words.is_empty() and not assign.is_empty():
				cmd.assigns.append(assign)
			else:
				cmd.words.append(t.parts)
			words_text.append(word_text(t.parts))
			continue

		var op: String = t.op
		if not pending_redir.is_empty():
			return _error(op)
		if REDIRS_WITH_TARGET.has(op):
			pending_redir = op
			words_text.append(op)
			continue
		if REDIRS_DUP.has(op):
			cmd.redirs.append({"op": op, "target": null})
			words_text.append(op)
			continue
		if op == "|":
			if _is_empty(cmd):
				return _error(op)
			cmds.append(cmd)
			cmd = _new_cmd()
			words_text.append("|")
			continue
		# separators
		if _is_empty(cmd):
			if cmds.is_empty() and op == ";" and not negate:
				continue # empty line or stray ";"
			return _error(op)
		cmds.append(cmd)
		items.append({"pipeline": {"cmds": cmds, "negate": negate, "text": " ".join(words_text)}, "op": op})
		cmds = []
		cmd = _new_cmd()
		negate = false
		words_text = []

	if not pending_redir.is_empty():
		return _error("newline")
	if not _is_empty(cmd):
		cmds.append(cmd)
	elif not cmds.is_empty():
		return _error("newline")
	if not cmds.is_empty():
		items.append({"pipeline": {"cmds": cmds, "negate": negate, "text": " ".join(words_text)}, "op": ";"})
	return {"items": items, "error": ""}


static func _new_cmd() -> Dictionary:
	return {"assigns": [], "words": [], "redirs": []}


static func _is_empty(cmd: Dictionary) -> bool:
	return cmd.words.is_empty() and cmd.assigns.is_empty() and cmd.redirs.is_empty()


static func _error(near: String) -> Dictionary:
	return {"items": [], "error": "syntax error near unexpected token `%s'" % near}


static func _is_bang(parts: Array) -> bool:
	return parts.size() == 1 and parts[0].get("q", -1) == 0 and parts[0].get("s", "") == "!"


## "NAME=value" at the start of a command, where NAME is unquoted.
static func _as_assignment(parts: Array) -> Array:
	if parts.is_empty() or parts[0].get("q", -1) != 0 or not parts[0].has("s"):
		return []
	var first: String = parts[0].s
	var eq := first.find("=")
	if eq <= 0 or not is_valid_name(first.substr(0, eq)):
		return []
	var value_parts: Array = []
	var rest := first.substr(eq + 1)
	if not rest.is_empty():
		value_parts.append({"q": 0, "s": rest})
	value_parts.append_array(parts.slice(1))
	return [first.substr(0, eq), value_parts]


static func is_valid_name(name: String) -> bool:
	if name.is_empty() or not (name[0] == "_" or (name[0] >= "A" and name[0] <= "Z") or (name[0] >= "a" and name[0] <= "z")):
		return false
	for c in name:
		if not (c == "_" or (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9")):
			return false
	return true


## Approximate source text of a word, used for job listings.
static func word_text(parts: Array) -> String:
	var out := ""
	for part: Dictionary in parts:
		if part.has("sub"):
			out += "$(" + part.sub + ")"
		elif part.q == 1:
			out += "'" + part.s + "'"
		elif part.q == 2:
			out += "\"" + part.s + "\""
		else:
			out += part.s
	return out
