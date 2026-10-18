class_name AgoraShLexer
extends RefCounted
## Splits shell input into words and operators.
##
## A word is a list of parts, so the expander knows what was quoted:
## - {"q": 0, "s": text}  unquoted: variables, globs and ~ are expanded
## - {"q": 1, "s": text}  single-quoted or backslash-escaped: taken literally
## - {"q": 2, "s": text}  double-quoted: only $ expansions and \ escapes apply
## - {"q": 0, "sub": src} unquoted command substitution $(...) or `...`
##
## - {"q": 0, "arith": expr} unquoted arithmetic expansion $((...))
##
## Operators: | || & && ; ;; ( ) < > >> 2> 2>> &> 2>&1 >&2. A newline is
## kept as its own "\n" token, because the parser needs it in a few places
## (case arms, for word lists); elsewhere it acts like ";".

const _OPS: PackedStringArray = ["2>&1", ">&2", "2>>", "&>", ">>", "&&", "||", ";;", "2>", ">", "<", "|", "&", ";", "(", ")", "\n"]


## Returns {"tokens": Array, "error": String}. Each token is
## {"k": "word", "parts": Array} or {"k": "op", "op": String}.
static func tokenize(src: String) -> Dictionary:
	var tokens: Array = []
	var parts: Array = []
	var raw := ""
	var in_word := false
	var i := 0
	var n := src.length()
	while i < n:
		var c := src[i]
		if c == " " or c == "\t" or c == "\r":
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			if in_word:
				tokens.append({"k": "word", "parts": parts})
				parts = []
				in_word = false
			i += 1
			continue
		if c == "#" and not in_word:
			while i < n and src[i] != "\n":
				i += 1
			continue
		if c == "\\":
			if i + 1 < n and src[i + 1] == "\n":
				i += 2
				continue
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			parts.append({"q": 1, "s": src[i + 1] if i + 1 < n else ""})
			in_word = true
			i += 2
			continue
		if c == "'":
			var close := src.find("'", i + 1)
			if close < 0:
				return {"tokens": [], "error": "unexpected EOF while looking for matching `''"}
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			parts.append({"q": 1, "s": src.substr(i + 1, close - i - 1)})
			in_word = true
			i = close + 1
			continue
		if c == "\"":
			var close := _find_dquote_end(src, i + 1)
			if close < 0:
				return {"tokens": [], "error": "unexpected EOF while looking for matching `\"'"}
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			parts.append({"q": 2, "s": src.substr(i + 1, close - i - 1)})
			in_word = true
			i = close + 1
			continue
		if c == "`":
			# Old-style command substitution: `command`.
			var close := find_backquote_end(src, i + 1)
			if close < 0:
				return {"tokens": [], "error": "unexpected EOF while looking for matching ``'"}
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			parts.append({"q": 0, "sub": unescape_backquoted(src.substr(i + 1, close - i - 1))})
			in_word = true
			i = close + 1
			continue
		if c == "$" and i + 1 < n and src[i + 1] == "(":
			var close := find_paren_end(src, i + 1)
			if close < 0:
				return {"tokens": [], "error": "unexpected EOF while looking for matching `)'"}
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			if src.substr(i + 1, 2) == "((" and src[close - 1] == ")":
				parts.append({"q": 0, "arith": src.substr(i + 3, close - i - 4)})
			else:
				parts.append({"q": 0, "sub": src.substr(i + 2, close - i - 2)})
			in_word = true
			i = close + 1
			continue
		var op := _match_op(src, i, in_word or not raw.is_empty())
		if not op.is_empty():
			if not raw.is_empty():
				parts.append({"q": 0, "s": raw})
				raw = ""
			if in_word:
				tokens.append({"k": "word", "parts": parts})
				parts = []
				in_word = false
			tokens.append({"k": "op", "op": op})
			i += op.length()
			continue
		raw += c
		in_word = true
		i += 1
	if not raw.is_empty():
		parts.append({"q": 0, "s": raw})
	if in_word:
		tokens.append({"k": "word", "parts": parts})
	return {"tokens": tokens, "error": ""}


static func _match_op(src: String, i: int, in_word: bool) -> String:
	for op in _OPS:
		if not src.substr(i, op.length()) == op:
			continue
		# "2>" style operators only count at the start of a word, so "a2>b"
		# stays a word followed by ">".
		if op.begins_with("2") and in_word:
			continue
		return op
	return ""


## Index of the closing quote of a double-quoted string starting at [param from].
static func _find_dquote_end(src: String, from: int) -> int:
	var i := from
	while i < src.length():
		var c := src[i]
		if c == "\\":
			i += 2
			continue
		if c == "\"":
			return i
		if c == "`":
			var end := find_backquote_end(src, i + 1)
			if end < 0:
				return -1
			i = end + 1
			continue
		if c == "$" and i + 1 < src.length() and src[i + 1] == "(":
			var close := find_paren_end(src, i + 1)
			if close < 0:
				return -1
			i = close + 1
			continue
		i += 1
	return -1


## Index of the "`" closing a backquoted command that starts at
## [param from], or -1.
static func find_backquote_end(src: String, from: int) -> int:
	var i := from
	while i < src.length():
		if src[i] == "\\":
			i += 2
			continue
		if src[i] == "`":
			return i
		i += 1
	return -1


## Inside backquotes a backslash only escapes $, ` and \.
static func unescape_backquoted(text: String) -> String:
	return text.replace("\\`", "`").replace("\\$", "$").replace("\\\\", "\\")


## Index of the ")" matching the "(" at [param open], skipping quoted text.
static func find_paren_end(src: String, open: int) -> int:
	var depth := 0
	var i := open
	while i < src.length():
		var c := src[i]
		if c == "\\":
			i += 2
			continue
		if c == "'":
			var close := src.find("'", i + 1)
			if close < 0:
				return -1
			i = close + 1
			continue
		if c == "\"":
			var close := _find_dquote_end(src, i + 1)
			if close < 0:
				return -1
			i = close + 1
			continue
		if c == "(":
			depth += 1
		elif c == ")":
			depth -= 1
			if depth == 0:
				return i
		i += 1
	return -1
