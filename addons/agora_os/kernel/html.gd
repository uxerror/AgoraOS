class_name AgoraHtml
extends RefCounted
## Lays out HTML as text the way Lynx does: paragraphs indented by three,
## headings flush left, bullets for lists, tables read row by row, images
## by their alt text. The result is a list of lines plus where every link
## and form field sits, so a browser can draw and select them.
##
## render() returns {title, base, lines (Array[String]), marks (per line,
## [col, length, link] with link -1 for bold text), links (Array of
## {kind: "link", "text", "password", "submit", "checkbox", "radio",
## "select", "hidden"; url, text, name, value, size, form, line, col,
## length, checked, options}), forms (Array of {action, method})}.

const BLOCKS := ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "dt", "dd", "pre",
	"blockquote", "table", "tr", "form", "address", "center", "hr", "body", "html", "li", "title", "frameset"]
const ENTITIES := {
	"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "copy": "(c)", "reg": "(R)",
	"middot": "·", "raquo": "»", "laquo": "«", "mdash": "--", "ndash": "-", "hellip": "...", "trade": "(TM)",
	"bull": "*", "eacute": "é", "uuml": "ü", "ouml": "ö", "auml": "ä", "szlig": "ß", "deg": "°",
}
const BULLETS := ["*", "+", "o", "#", "@", "-"]


## Decodes character references in [param text].
static func decode_entities(text: String) -> String:
	if not text.contains("&"):
		return text
	var out := ""
	var k := 0
	while k < text.length():
		var c := text[k]
		if c == "&":
			var end := text.find(";", k)
			if end > k and end - k <= 10:
				var name := text.substr(k + 1, end - k - 1)
				var value := ""
				if name.begins_with("#x") or name.begins_with("#X"):
					value = char(("0x" + name.substr(2)).hex_to_int())
				elif name.begins_with("#") and name.substr(1).is_valid_int():
					value = char(name.substr(1).to_int())
				else:
					value = ENTITIES.get(name.to_lower(), "")
				if not value.is_empty():
					out += value
					k = end + 1
					continue
		out += c
		k += 1
	return out


## Tags and text of a page: [{tag, attrs, close}] or a String for text.
static func tokenize(html: String) -> Array:
	var out: Array = []
	var k := 0
	var n := html.length()
	while k < n:
		var lt := html.find("<", k)
		if lt < 0:
			out.append(html.substr(k))
			break
		if lt > k:
			out.append(html.substr(k, lt - k))
		if html.substr(lt, 4) == "<!--":
			var end := html.find("-->", lt + 4)
			k = n if end < 0 else end + 3
			continue
		var gt := html.find(">", lt)
		if gt < 0:
			out.append(html.substr(lt))
			break
		var inner := html.substr(lt + 1, gt - lt - 1).strip_edges()
		k = gt + 1
		if inner.begins_with("!") or inner.begins_with("?") or inner.is_empty():
			continue
		var close := inner.begins_with("/")
		if close:
			inner = inner.substr(1)
		inner = inner.trim_suffix("/").strip_edges()
		var name_end := 0
		while name_end < inner.length() and not inner[name_end] in [" ", "\t", "\n", "\r"]:
			name_end += 1
		var tag := inner.substr(0, name_end).to_lower()
		var attrs := _attributes(inner.substr(name_end))
		out.append({"tag": tag, "attrs": attrs, "close": close})
		if not close and tag in ["script", "style"]:
			var end_tag := html.to_lower().find("</" + tag, k)
			k = n if end_tag < 0 else html.find(">", end_tag) + 1
	return out


static func _attributes(text: String) -> Dictionary:
	var attrs := {}
	var k := 0
	var n := text.length()
	while k < n:
		while k < n and text[k] in [" ", "\t", "\n", "\r"]:
			k += 1
		var start := k
		while k < n and not text[k] in ["=", " ", "\t", "\n", "\r"]:
			k += 1
		var name := text.substr(start, k - start).to_lower()
		if name.is_empty():
			k += 1
			continue
		while k < n and text[k] in [" ", "\t"]:
			k += 1
		var value := ""
		if k < n and text[k] == "=":
			k += 1
			while k < n and text[k] in [" ", "\t"]:
				k += 1
			if k < n and text[k] in ["\"", "'"]:
				var q := text[k]
				var end := text.find(q, k + 1)
				if end < 0:
					end = n
				value = text.substr(k + 1, end - k - 1)
				k = end + 1
			else:
				var s2 := k
				while k < n and not text[k] in [" ", "\t", "\n", "\r"]:
					k += 1
				value = text.substr(s2, k - s2)
		attrs[name] = decode_entities(value)
	return attrs


## Plain words of a page, for indexing: title and body text.
static func plain_text(html: String) -> String:
	var r := render(html, 1000, false)
	var out: PackedStringArray = []
	for l: String in r.lines:
		if not l.strip_edges().is_empty():
			out.append(l.strip_edges())
	return " ".join(out)


## Lays out [param html] for a screen [param width] wide. With
## [param numbers], each link and field gets "[n]" in front, as lynx -dump.
static func render(html: String, width: int = 80, numbers: bool = false) -> Dictionary:
	var L := _Layout.new()
	L.width = maxi(width, 20)
	L.numbers = numbers
	var in_title := false
	var title := ""
	var base := ""
	var link := -1
	var bold := 0
	var lists: Array = [] # {"ordered", "n"}
	var form := -1
	var select := -1
	var textarea := -1
	for tok: Variant in tokenize(html):
		if tok is String:
			var text := decode_entities(tok)
			if in_title:
				title += text
			elif select >= 0:
				var options: Array = L.links[select].options
				if not options.is_empty():
					options[-1][1] += text.strip_edges()
			elif textarea >= 0:
				L.links[textarea].value += text
			elif L.pre > 0:
				L.preformatted(text, link, bold > 0)
			else:
				L.text(text, link, bold > 0)
			continue
		var tag: String = tok.tag
		var attrs: Dictionary = tok.attrs
		var close: bool = tok.close
		match tag:
			"title":
				in_title = not close
			"base":
				base = attrs.get("href", "")
			"br":
				L.newline(true)
			"p", "div", "address", "dl", "form", "frameset":
				L.blank()
			"center":
				L.newline()
				L.center = not close
			"h1", "h2", "h3", "h4", "h5", "h6":
				L.blank()
				if close:
					bold = maxi(0, bold - 1)
					L.indent = L.base_indent()
				else:
					bold += 1
					L.indent = maxi(0, tag.substr(1).to_int() - 1)
			"pre":
				L.blank()
				L.pre = maxi(0, L.pre + (-1 if close else 1))
			"blockquote":
				L.blank()
				L.quote += -1 if close else 1
				L.indent = L.base_indent()
			"ul", "ol", "menu", "dir":
				if close:
					lists.pop_back()
					if lists.is_empty():
						L.blank()
				else:
					if lists.is_empty():
						L.blank()
					else:
						L.newline()
					lists.append({"ordered": tag == "ol", "n": 0})
				L.depth = lists.size()
				L.indent = L.base_indent()
			"li":
				if not close:
					L.newline()
					var marker := "*"
					if not lists.is_empty():
						var cur: Dictionary = lists[-1]
						cur.n += 1
						marker = "%d." % cur.n if cur.ordered else BULLETS[(lists.size() - 1) % BULLETS.size()]
					L.marker(marker)
			"dt":
				L.newline()
				L.indent = L.base_indent()
			"dd":
				L.newline()
				L.indent = L.base_indent() + 3
			"tr":
				L.newline()
			"td", "th":
				if not close:
					L.space()
			"table":
				L.blank()
			"hr":
				L.newline()
				L.add_line(" ".repeat(L.base_indent()) + "_".repeat(maxi(1, L.width - L.base_indent() * 2)))
			"b", "strong", "em", "i", "u", "th":
				bold = maxi(0, bold + (-1 if close else 1))
			"a":
				if close:
					if link >= 0:
						L.end_link(link)
					link = -1
				elif attrs.has("href"):
					link = L.add_link({"kind": "link", "url": attrs.href, "text": ""})
			"img":
				var alt: Variant = attrs.get("alt")
				var shown: String = "[INLINE]" if alt == null else str(alt)
				if alt == null and link >= 0:
					shown = "[LINK]"
				if not shown.is_empty():
					L.text(shown, link, bold > 0)
			"frame":
				if attrs.has("src"):
					L.newline()
					var f := L.add_link({"kind": "link", "url": attrs.src, "text": ""})
					L.text("FRAME: " + str(attrs.get("name", attrs.src)), f, false)
					L.end_link(f)
					L.newline()
			"input":
				var kind := str(attrs.get("type", "text")).to_lower()
				var entry := {"kind": kind, "name": attrs.get("name", ""), "value": attrs.get("value", ""),
					"form": form, "size": clampi(str(attrs.get("size", "20")).to_int(), 1, L.width - 6),
					"checked": attrs.has("checked")}
				match kind:
					"hidden":
						L.links.append(entry)
					"submit", "image", "button", "reset":
						if kind == "image":
							entry.kind = "submit"
						if str(entry.value).is_empty():
							entry.value = "Submit" if kind != "reset" else "Reset"
						var i := L.add_link(entry)
						L.text(str(entry.value), i, false)
						L.end_link(i)
					"checkbox", "radio":
						var i := L.add_link(entry)
						L.field(i, 3)
					_:
						if kind not in ["text", "password"]:
							entry.kind = "text"
						var i := L.add_link(entry)
						L.field(i, entry.size)
			"textarea":
				if close:
					textarea = -1
				else:
					var i := L.add_link({"kind": "text", "name": attrs.get("name", ""), "value": "", "form": form,
						"size": clampi(str(attrs.get("cols", "40")).to_int(), 1, L.width - 6)})
					L.field(i, L.links[i].size)
					textarea = i
			"select":
				if close:
					var entry: Dictionary = L.links[select]
					var widest := 1
					for o: Array in entry.options:
						widest = maxi(widest, str(o[1]).length())
						if o[2]:
							entry.value = o[0]
					if str(entry.value).is_empty() and not entry.options.is_empty():
						entry.value = entry.options[0][0]
					L.field(select, mini(widest, L.width - 6))
					select = -1
				else:
					select = L.add_link({"kind": "select", "name": attrs.get("name", ""), "value": "", "form": form, "options": []})
			"option":
				if not close and select >= 0:
					(L.links[select].options as Array).append([attrs.get("value", null), "", attrs.has("selected")])
			_:
				pass
		if tag == "form":
			if close:
				form = -1
			else:
				form = L.forms.size()
				L.forms.append({"action": attrs.get("action", ""), "method": str(attrs.get("method", "get")).to_upper()})
		if tag in ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "table", "address"] and close:
			L.blank()
	L.newline()
	# Option values default to their text.
	for entry: Dictionary in L.links:
		if entry.kind == "select":
			for o: Array in entry.options:
				if o[0] == null:
					o[0] = o[1]
			if entry.value == null or str(entry.value).is_empty():
				entry.value = entry.options[0][0] if not entry.options.is_empty() else ""
	while not L.lines.is_empty() and (L.lines[-1] as String).strip_edges().is_empty():
		L.lines.pop_back()
		L.marks.pop_back()
	return {"title": title.strip_edges().replace("\n", " "), "base": base, "lines": L.lines, "marks": L.marks,
		"links": L.links, "forms": L.forms}


class _Layout:
	var width := 80
	var numbers := false
	var lines: Array[String] = []
	var marks: Array = []
	var links: Array = []
	var forms: Array = []
	var cur := ""
	var cur_marks: Array = []
	var indent := 3
	var depth := 0
	var quote := 0
	var pre := 0
	var center := false
	var _space := false
	var _hang := ""

	func base_indent() -> int:
		return 3 + quote * 3 + depth * 4

	func add_link(entry: Dictionary) -> int:
		links.append(entry)
		return links.size() - 1

	func _start_line() -> void:
		if cur.is_empty():
			cur = " ".repeat(indent)
			if not _hang.is_empty():
				var at := maxi(0, indent - _hang.length() - 1)
				cur = " ".repeat(at) + _hang + " ".repeat(maxi(1, indent - at - _hang.length()))
				_hang = ""

	func _mark(start: int, length: int, link: int, bold: bool) -> void:
		if link >= 0:
			var entry: Dictionary = links[link]
			if not entry.has("line"):
				entry.line = lines.size()
				entry.col = start
				entry.length = length
			_append_mark(start, length, link)
		elif bold:
			_append_mark(start, length, -1)

	## Words of one link (or bold run) separated by a space make one mark.
	func _append_mark(start: int, length: int, link: int) -> void:
		if not cur_marks.is_empty():
			var last: Array = cur_marks[-1]
			if last[2] == link and last[0] + last[1] + 1 == start and cur.substr(last[0] + last[1], 1) == " ":
				last[1] += length + 1
				return
		cur_marks.append([start, length, link])

	func _word(w: String, link: int, bold: bool) -> void:
		_start_line()
		var blank_line := cur.strip_edges().is_empty()
		var need := w.length() + (1 if _space and not blank_line else 0)
		if not blank_line and cur.length() + need > width:
			flush()
			_start_line()
			_space = false
		if _space and not cur.strip_edges().is_empty():
			cur += " "
		_mark(cur.length(), w.length(), link, bold)
		cur += w
		_space = false

	func text(t: String, link: int, bold: bool) -> void:
		if t.is_empty():
			return
		var normalized := t.replace("\n", " ").replace("\t", " ").replace("\r", " ")
		if normalized.begins_with(" "):
			_space = true
		for w in normalized.split(" ", false):
			if link >= 0 and numbers and str(links[link].get("text", "")).is_empty() and not links[link].get("_numbered", false):
				links[link]._numbered = true
				_word("[%d]%s" % [link + 1, w], link, bold)
			else:
				_word(w, link, bold)
			if link >= 0:
				links[link].text = (str(links[link].get("text", "")) + " " + w).strip_edges()
			_space = true
		if not normalized.ends_with(" "):
			_space = false

	func preformatted(t: String, link: int, bold: bool) -> void:
		var parts := t.replace("\r", "").split("\n")
		for k in parts.size():
			if k > 0:
				lines.append(cur)
				marks.append(cur_marks)
				cur = ""
				cur_marks = []
			var piece := parts[k].replace("\t", "        ")
			if piece.is_empty():
				continue
			_mark(cur.length(), piece.length(), link, bold)
			cur += piece
			if link >= 0:
				links[link].text = (str(links[link].get("text", "")) + piece).strip_edges()

	func space() -> void:
		_space = true

	func end_link(i: int) -> void:
		if numbers and not links[i].get("_numbered", false):
			links[i]._numbered = true
			_word("[%d]" % (i + 1), i, false)

	## A form field [param size] wide: underscores to draw over.
	func field(i: int, size: int) -> void:
		var label := ("[%d]" % (i + 1)) if numbers else ""
		if numbers:
			_word(label, -1, false)
			_space = false # the field follows its number directly
		_start_line()
		if _space and not cur.strip_edges().is_empty():
			cur += " "
		if cur.length() + size > width and not cur.strip_edges().is_empty():
			flush()
			_start_line()
		_mark(cur.length(), size, i, false)
		var shown := "_".repeat(size)
		var entry: Dictionary = links[i]
		match entry.kind:
			"checkbox":
				shown = "[X]" if entry.checked else "[ ]"
			"radio":
				shown = "(*)" if entry.checked else "( )"
		cur += shown
		_space = true

	func marker(m: String) -> void:
		_hang = m

	func flush() -> void:
		var line := cur.rstrip(" ")
		if center:
			var shift := maxi(0, (width - line.strip_edges().length()) / 2) - (line.length() - line.strip_edges(true, false).length())
			if shift > 0:
				line = " ".repeat(shift) + line
				for m: Array in cur_marks:
					m[0] += shift
				for entry: Dictionary in links:
					if entry.get("line", -1) == lines.size():
						entry.col += shift
		lines.append(line)
		marks.append(cur_marks)
		cur = ""
		cur_marks = []

	func newline(force: bool = false) -> void:
		if not cur.strip_edges().is_empty() or not cur_marks.is_empty():
			flush()
		elif force:
			lines.append("")
			marks.append([])
			cur = ""
		_space = false

	func blank() -> void:
		newline()
		if not lines.is_empty() and not (lines[-1] as String).strip_edges().is_empty():
			lines.append("")
			marks.append([])
		indent = base_indent()

	func add_line(text: String) -> void:
		lines.append(text)
		marks.append([])
