class_name AgoraShParser
extends RefCounted
## Recursive descent parser for sh. Turns lexer tokens into a syntax tree.
##
## [codeblock]
## list:     [{pipeline, op}]          op joins to the next item: ; && || &
## pipeline: {cmds: [command], negate: bool, text: String}
## command:  {t: "simple", assigns: [[name, parts]], words: [parts], redirs}
##           {t: "if", branches: [[cond_list, body_list]], else_body, redirs}
##           {t: "while", until: bool, cond, body, redirs}
##           {t: "for", var: String, words: [parts] or null, body, redirs}
##           {t: "case", word: parts, arms: [{patterns: [parts], body}], redirs}
##           {t: "group", body, redirs}       { list; }
##           {t: "subshell", body, redirs}    ( list )
##           {t: "funcdef", name, body: command}
## redirs:   [{op, target: parts or null}]
## [/codeblock]

const REDIRS_WITH_TARGET: PackedStringArray = [">", ">>", "<", "2>", "2>>", "&>"]
const REDIRS_DUP: PackedStringArray = ["2>&1", ">&2"]
const RESERVED: PackedStringArray = [
	"if", "then", "elif", "else", "fi", "while", "until", "for", "in", "do",
	"done", "case", "esac", "{", "}", "!", "function",
]

var _toks: Array = []
var _pos := 0
var _error := ""
## True when the error is only that the input ended too early, so an
## interactive shell can ask for more lines.
var _incomplete := false


## Returns {"items": list, "error": String, "incomplete": bool}.
static func parse(tokens: Array) -> Dictionary:
	var parser := AgoraShParser.new()
	parser._toks = tokens
	var items := parser._list([], [])
	if parser._error.is_empty() and parser._pos < tokens.size():
		parser._fail_at_current()
	if not parser._error.is_empty():
		return {"items": [], "error": parser._error, "incomplete": parser._incomplete}
	return {"items": items, "error": "", "incomplete": false}


# --- token helpers ----------------------------------------------------------

func _peek() -> Variant:
	return _toks[_pos] if _pos < _toks.size() else null


func _peek_op() -> String:
	var t: Variant = _peek()
	return t.op if t != null and t.k == "op" else ""


## The plain text of the current token if it is an unquoted word ("" otherwise).
func _peek_word() -> String:
	var t: Variant = _peek()
	if t == null or t.k != "word":
		return ""
	return plain_word(t.parts)


func _next() -> Dictionary:
	_pos += 1
	return _toks[_pos - 1]


func _skip_newlines() -> void:
	while _peek_op() == "\n":
		_pos += 1


func _skip_separators() -> void:
	while _peek_op() in ["\n", ";"]:
		_pos += 1


func _expect_word(word: String) -> bool:
	_skip_newlines()
	if _peek_word() == word:
		_pos += 1
		return true
	_fail_at_current()
	return false


func _fail_at_current() -> void:
	if not _error.is_empty():
		return
	var t: Variant = _peek()
	_incomplete = t == null
	var near: String = "newline" if t == null else (word_text(t.parts) if t.k == "word" else ("newline" if t.op == "\n" else t.op))
	_error = "syntax error near unexpected token `%s'" % near


# --- grammar ----------------------------------------------------------------

## Parses commands until one of [param end_words] (reserved words in command
## position) or [param end_ops] comes up.
func _list(end_words: PackedStringArray, end_ops: PackedStringArray) -> Array:
	var items: Array = []
	while _error.is_empty():
		_skip_separators()
		if _peek() == null or end_ops.has(_peek_op()) or end_words.has(_peek_word()):
			break
		var start := _pos
		var pl := _pipeline()
		if not _error.is_empty():
			break
		pl.text = _source_text(start, _pos)
		var op := _peek_op()
		if op in [";", "&", "&&", "||"]:
			_pos += 1
			if op in ["&&", "||"]:
				_skip_newlines()
		elif op == "\n":
			op = ";"
		elif _peek() != null and not end_ops.has(op) and not end_words.has(_peek_word()):
			_fail_at_current()
			break
		else:
			op = ";"
		items.append({"pipeline": pl, "op": op})
	return items


func _pipeline() -> Dictionary:
	var negate := false
	if _peek_word() == "!":
		_pos += 1
		negate = true
	var cmds: Array = [_command()]
	while _error.is_empty() and _peek_op() == "|":
		_pos += 1
		_skip_newlines()
		cmds.append(_command())
	return {"cmds": cmds, "negate": negate, "text": ""}


func _command() -> Dictionary:
	var word := _peek_word()
	var node := {}
	match word:
		"if": node = _if()
		"while", "until": node = _loop()
		"for": node = _for()
		"case": node = _case()
		"{":
			_pos += 1
			node = {"t": "group", "body": _list(["}"], [])}
			_expect_word("}")
		"function":
			_pos += 1
			return _funcdef(_peek_word())
		_:
			if _peek_op() == "(":
				_pos += 1
				node = {"t": "subshell", "body": _list([], [")"])}
				if _peek_op() != ")":
					_fail_at_current()
				else:
					_pos += 1
			elif AgoraShParser.is_valid_name(word) and _op_at(_pos + 1) == "(" and _op_at(_pos + 2) == ")":
				return _funcdef(word)
			elif RESERVED.has(word) and word not in ["!", "in"]:
				_fail_at_current()
				return {}
			else:
				return _simple()
	node["redirs"] = _redirs()
	return node


func _op_at(i: int) -> String:
	return _toks[i].op if i < _toks.size() and _toks[i].k == "op" else ""


func _funcdef(name: String) -> Dictionary:
	if not AgoraShParser.is_valid_name(name):
		_fail_at_current()
		return {}
	_pos += 1
	if _peek_op() == "(":
		_pos += 1
		if _peek_op() != ")":
			_fail_at_current()
			return {}
		_pos += 1
	_skip_newlines()
	var body := _command()
	if body.get("t", "simple") == "simple":
		_fail_at_current()
	return {"t": "funcdef", "name": name, "body": body}


func _if() -> Dictionary:
	_pos += 1
	var branches: Array = []
	var cond := _list(["then"], [])
	if not _expect_word("then"):
		return {}
	branches.append([cond, _list(["elif", "else", "fi"], [])])
	var else_body = null
	while _error.is_empty():
		var w := _peek_word()
		if w == "elif":
			_pos += 1
			var c := _list(["then"], [])
			if not _expect_word("then"):
				return {}
			branches.append([c, _list(["elif", "else", "fi"], [])])
		elif w == "else":
			_pos += 1
			else_body = _list(["fi"], [])
		else:
			break
	_expect_word("fi")
	return {"t": "if", "branches": branches, "else_body": else_body}


func _loop() -> Dictionary:
	var until: bool = _next().parts[0].s == "until"
	var cond := _list(["do"], [])
	if not _expect_word("do"):
		return {}
	var body := _list(["done"], [])
	_expect_word("done")
	return {"t": "while", "until": until, "cond": cond, "body": body}


func _for() -> Dictionary:
	_pos += 1
	var name := _peek_word()
	if not AgoraShParser.is_valid_name(name):
		_fail_at_current()
		return {}
	_pos += 1
	var words = null
	_skip_newlines()
	if _peek_word() == "in":
		_pos += 1
		words = []
		while _peek() != null and _peek()["k"] == "word":
			words.append(_next().parts)
	if _peek_op() in [";", "\n"]:
		_pos += 1
	if not _expect_word("do"):
		return {}
	var body := _list(["done"], [])
	_expect_word("done")
	return {"t": "for", "var": name, "words": words, "body": body}


func _case() -> Dictionary:
	_pos += 1
	var t: Variant = _peek()
	if t == null or t.k != "word":
		_fail_at_current()
		return {}
	var word: Array = _next().parts
	if not _expect_word("in"):
		return {}
	var arms: Array = []
	while _error.is_empty():
		_skip_separators()
		if _peek_word() == "esac" or _peek() == null:
			break
		if _peek_op() == "(":
			_pos += 1
		var patterns: Array = []
		while true:
			var pt: Variant = _peek()
			if pt == null or pt.k != "word":
				_fail_at_current()
				return {}
			patterns.append(_next().parts)
			if _peek_op() == "|":
				_pos += 1
				continue
			break
		if _peek_op() != ")":
			_fail_at_current()
			return {}
		_pos += 1
		var body := _list(["esac"], [";;"])
		arms.append({"patterns": patterns, "body": body})
		if _peek_op() == ";;":
			_pos += 1
	_expect_word("esac")
	return {"t": "case", "word": word, "arms": arms}


func _simple() -> Dictionary:
	var cmd := {"t": "simple", "assigns": [], "words": [], "redirs": []}
	while _error.is_empty():
		var t: Variant = _peek()
		if t == null:
			break
		if t.k == "word":
			_pos += 1
			var assign := _as_assignment(t.parts)
			if cmd.words.is_empty() and not assign.is_empty():
				cmd.assigns.append(assign)
			else:
				cmd.words.append(t.parts)
			continue
		if REDIRS_WITH_TARGET.has(t.op) or REDIRS_DUP.has(t.op):
			cmd.redirs.append_array(_redirs())
			continue
		break
	if cmd.words.is_empty() and cmd.assigns.is_empty() and cmd.redirs.is_empty():
		_fail_at_current()
	return cmd


func _redirs() -> Array:
	var out: Array = []
	while _error.is_empty():
		var op := _peek_op()
		if REDIRS_DUP.has(op):
			_pos += 1
			out.append({"op": op, "target": null})
		elif REDIRS_WITH_TARGET.has(op):
			_pos += 1
			var t: Variant = _peek()
			if t == null or t.k != "word":
				_fail_at_current()
				break
			out.append({"op": op, "target": _next().parts})
		else:
			break
	return out


## Rebuilds approximate source text of tokens [from, to), for job listings.
func _source_text(from: int, to: int) -> String:
	var out: PackedStringArray = []
	for i in range(from, mini(to, _toks.size())):
		var t: Dictionary = _toks[i]
		if t.k == "word":
			out.append(word_text(t.parts))
		elif t.op != "\n":
			out.append(t.op)
	return " ".join(out)


# --- static helpers ---------------------------------------------------------

## The word's text if it is a single unquoted part, else "".
static func plain_word(parts: Array) -> String:
	if parts.size() == 1 and parts[0].get("q", -1) == 0 and parts[0].has("s"):
		return parts[0].s
	return ""


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


## Approximate source text of a word.
static func word_text(parts: Array) -> String:
	var out := ""
	for part: Dictionary in parts:
		if part.has("sub"):
			out += "$(" + part.sub + ")"
		elif part.has("arith"):
			out += "$((" + part.arith + "))"
		elif part.q == 1:
			out += "'" + part.s + "'"
		elif part.q == 2:
			out += "\"" + part.s + "\""
		else:
			out += part.s
	return out
