extends AgoraProgram
## Lynx 2.8.5: the text web browser. On a terminal it takes the whole
## screen: the title on top, the page, a status line and the key help at
## the bottom. Up and Down move between links, Right or Enter follows one,
## Left goes back; Space and b page; g opens a URL; / searches; \ shows the
## source; q quits. On a text field typed characters go into the field and
## Enter submits its form.
##
## lynx -dump URL prints the page as text with numbered links and their
## references; -source prints the HTML; -head the response headers;
## -width=N sets the dump width.

const VERSION := "2.8.5rel.1"
const AGENT := "Lynx/2.8.5rel.1 libwww-FM/2.14"
const HELP_1 := "  Arrow keys: Up and Down to move.  Right to follow a link; Left to go back."
const HELP_2 := " H)elp O)ptions P)rint G)o M)ain screen Q)uit /=search [delete]=history list"
const ABOUT := """<html><head><title>Lynx</title></head><body>
<h1>Lynx %s</h1>
<p>Lynx is a fully-featured World Wide Web browser for users on
character-cell terminals.</p>
<p>Give it a URL to start: <b>lynx http://www.example.org/</b>,
or press <b>g</b> to open one.</p>
<h2>Keys</h2>
<ul>
<li>Up, Down, Tab: move between links and form fields
<li>Right, Enter: follow a link, submit a form
<li>Left: go back to the previous page
<li>Space, b: next and previous page
<li>g: go to a URL; /: search the page; n: search again
<li>\\: toggle the HTML source; =: page information
<li>Ctrl-R: reload; q: quit (Q without asking)
</ul></body></html>
""" % VERSION

var p: AgoraProcess
var _url := ""
var _base := ""
var _html := ""
var _page := {}
var _width := 0
var _source := false
var _top := 0
var _cur := -1
var _history: Array[Dictionary] = []
var _status := ""
var _search := ""
var _quit := false
var _keys := ""


func summary() -> String:
	return "a general purpose distributed information browser for the World Wide Web"


func usage() -> String:
	return "USAGE: lynx [options] [file]\n  -dump  dump the formatted output to stdout\n  -source  dump the source to stdout\n  -head  send a HEAD request\n  -width=N  screen width for -dump"


func main(proc: AgoraProcess) -> int:
	p = proc
	var dump := false
	var source := false
	var head := false
	var width := 79
	var target := ""
	for a in p.argv.slice(1):
		if a == "-dump":
			dump = true
		elif a == "-source":
			source = true
		elif a == "-head":
			head = true
		elif a.begins_with("-width="):
			width = a.get_slice("=", 1).to_int()
		elif a in ["-version", "--version"]:
			p.outln("Lynx Version %s (04 Feb 2004)\nlibwww-FM 2.14, SSL-MM 1.4.1, OpenSSL 0.9.7e" % VERSION)
			return 0
		elif a in ["-help", "--help"]:
			p.outln(usage())
			return 0
		elif a.begins_with("-"):
			continue # other options are accepted
		else:
			target = a
	if dump or source or head:
		if target.is_empty():
			return p.fail("lynx: Can't access startfile", 1)
		return await _batch(target, dump, source, head, width)
	if p.tty == null:
		return p.fail("Your terminal lacks the ability to clear the screen or position the cursor.", 1)
	p.tty.raw = true
	p.signal_handler = func(sig: int) -> bool:
		if sig == AgoraProcess.SIGINT:
			_quit = true
			p.stdin.changed.emit() # wake the key reader
			return true
		return false
	if target.is_empty():
		_show_html("about:lynx", ABOUT)
	elif not await _load(_to_url(target), "GET", "", false):
		_restore()
		return p.fail("lynx: Can't access startfile %s" % _to_url(target), 1)
	_draw()
	while not _quit and not p.is_dead():
		var key := await _key()
		if key.is_empty():
			break
		await _handle(key)
		if not _quit:
			_draw()
	_restore()
	return 0


func _restore() -> void:
	p.out("\u001b[0m\u001b[H\u001b[2J\u001b[?25h")
	p.tty.raw = false


## A URL from what the user typed: a path, a host or a full URL.
func _to_url(text: String) -> String:
	if text.contains("://"):
		return text
	if text.begins_with("/") or text.begins_with("."):
		return "file://localhost" + AgoraPath.normalize(text, p.cwd)
	if p.exists(text) and not text.contains("/"):
		return "file://localhost" + AgoraPath.normalize(text, p.cwd)
	return "http://" + text + ("" if text.contains("/") else "/")


# --- batch modes -----------------------------------------------------------------

func _batch(target: String, dump: bool, source: bool, head: bool, width: int) -> int:
	var r: Dictionary = await AgoraHttp.fetch(p, _to_url(target), {"agent": AGENT, "method": "HEAD" if head else "GET"})
	if r.has("error"):
		p.errln("")
		p.errln("lynx: Can't access startfile %s" % _to_url(target))
		return 1
	if head:
		p.out(str(r.get("status_line", "HTTP/1.0 200 OK")) + "\n")
		for h: String in r.headers:
			p.outln("%s: %s" % [h.capitalize().replace(" ", "-"), r.headers[h]])
		return 0
	var body := AgoraWire.encode(r.body).get_string_from_utf8()
	if source or not _is_html(r):
		p.out(body)
		return 0
	var page := AgoraHtml.render(body, width, true)
	for l: String in page.lines:
		p.outln(l)
	var refs: PackedStringArray = []
	var base: String = page.base if not str(page.base).is_empty() else str(r.url)
	for entry: Dictionary in page.links:
		if entry.kind == "link":
			refs.append("%4d. %s" % [page.links.find(entry) + 1, AgoraHttp.resolve(base, entry.url)])
	if not refs.is_empty():
		p.outln("\nReferences\n")
		for line in refs:
			p.outln(line)
	return 0


static func _is_html(r: Dictionary) -> bool:
	var type := str(r.headers.get("content-type", "text/html")).to_lower()
	return type.begins_with("text/html") or str(r.url).ends_with(".html") or str(r.url).ends_with("/")


# --- loading -----------------------------------------------------------------------

## Fetches a page and shows it. False (with an alert on the status line)
## if it couldn't be had.
func _load(url: String, method: String, body: String, remember: bool) -> bool:
	_message("Getting %s" % url)
	var r: Dictionary = await AgoraHttp.fetch(p, url, {"agent": AGENT, "method": method, "body": body,
		"status": func(text: String) -> void: _message(text)})
	if r.has("error"):
		match r.stage:
			"resolve":
				_status = "Alert!: Unable to locate remote host %s." % AgoraHttp.parse_url(url).get("host", url)
			"connect":
				_status = "Alert!: Unable to connect to remote host."
			"scheme":
				_status = "Alert!: Unsupported URL scheme!"
			_:
				_status = "Alert!: Unable to access document."
		return false
	if remember and not _url.is_empty():
		_history.append({"url": _url, "html": _html, "base": _base, "top": _top, "cur": _cur})
	var text := AgoraWire.encode(r.body).get_string_from_utf8()
	if not _is_html(r):
		text = "<html><body><pre>%s</pre></body></html>" % text.replace("&", "&amp;").replace("<", "&lt;")
	_show_html(r.url, text)
	_status = ""
	return true


func _show_html(url: String, html: String) -> void:
	_url = url
	_html = html
	_source = false
	_layout()
	_base = str(_page.base) if not str(_page.base).is_empty() else url
	_top = 0
	_cur = _first_link_from(0)


func _layout() -> void:
	_width = p.tty.cols if p.tty else 80
	var text := _html
	if _source:
		text = "<pre>%s</pre>" % _html.replace("&", "&amp;").replace("<", "&lt;")
	var old_values: Array = []
	if not _page.is_empty() and not _source:
		for entry: Dictionary in _page.links:
			old_values.append(entry.get("value", ""))
	_page = AgoraHtml.render(text, maxi(_width - 1, 20))
	if old_values.size() == _page.links.size():
		for k in old_values.size():
			_page.links[k].value = old_values[k]


func _rows() -> int:
	return maxi(3, (p.tty.rows if p.tty else 24) - 4)


func _selectable(entry: Dictionary) -> bool:
	return entry.kind != "hidden" and entry.has("line")


func _first_link_from(line: int) -> int:
	for k in _page.links.size():
		var e: Dictionary = _page.links[k]
		if _selectable(e) and e.line >= line and e.line < line + _rows():
			return k
	return -1


# --- drawing -----------------------------------------------------------------------

func _draw() -> void:
	if p.tty and p.tty.cols != _width:
		_layout()
	var rows := _rows()
	var lines: Array = _page.lines
	var pages := maxi(1, ceili(float(lines.size()) / rows))
	var title := str(_page.title) if not str(_page.title).is_empty() else _url
	if pages > 1:
		title += " (p%d of %d)" % [_top / rows + 1, pages]
	var w := _width
	var out := "\u001b[?25l\u001b[0m\u001b[H\u001b[2J"
	out += "\u001b[1;1H" + " ".repeat(maxi(0, w - title.length() - 1)) + title.left(w - 1)
	for i in rows:
		var li := _top + i
		if li >= lines.size():
			break
		out += "\u001b[%d;1H%s" % [i + 2, _draw_line(li)]
	var status := _status
	if status.is_empty():
		status = _link_status()
	if status.is_empty() and _top + rows < lines.size():
		status = "-- press space for next page --"
	out += "\u001b[%d;1H\u001b[0m%s" % [rows + 2, status.left(w - 1)]
	out += "\u001b[%d;1H%s\u001b[%d;1H%s" % [rows + 3, HELP_1.left(w - 1), rows + 4, HELP_2.left(w - 1)]
	var focus := _focused_field()
	if not focus.is_empty():
		var col: int = focus.col + mini(str(focus.value).length(), focus.length - 1)
		out += "\u001b[%d;%dH\u001b[?25h" % [focus.line - _top + 2, col + 1]
	p.out(out)


func _focused_field() -> Dictionary:
	if _cur < 0:
		return {}
	var e: Dictionary = _page.links[_cur]
	return e if e.kind in ["text", "password"] else {}


func _link_status() -> String:
	if _cur < 0:
		return ""
	var e: Dictionary = _page.links[_cur]
	match e.kind:
		"text", "password":
			return "(Text entry field) Enter text.  Use UP or DOWN arrows or tab to move off."
		"submit":
			return "(Form submit button) Use right-arrow or <return> to submit."
		"checkbox":
			return "(Checkbox Field)   Use right-arrow or <return> to toggle."
		"radio":
			return "(Radio Button)   Use right-arrow or <return> to toggle."
		"select":
			return "(Option list) Hit return and use arrow keys and return to select option."
	return AgoraHttp.resolve(_base, str(e.url))


## One page line with links highlighted and fields filled in.
func _draw_line(li: int) -> String:
	var text: String = _page.lines[li]
	var marks: Array = _page.marks[li]
	var out := ""
	var col := 0
	for m: Array in marks:
		var start: int = m[0]
		var length: int = m[1]
		if start < col:
			continue
		out += text.substr(col, start - col)
		var piece := text.substr(start, length)
		var style := "\u001b[1m"
		if m[2] >= 0:
			var e: Dictionary = _page.links[m[2]]
			style = "\u001b[7m" if m[2] == _cur else "\u001b[1;34m"
			match e.kind:
				"text", "password":
					var v := str(e.value) if e.kind == "text" else "*".repeat(str(e.value).length())
					piece = (v + "_".repeat(length)).left(length)
					style = "\u001b[7m" if m[2] == _cur else "\u001b[4m"
				"checkbox":
					piece = "[X]" if e.checked else "[ ]"
				"radio":
					piece = "(*)" if e.checked else "( )"
				"select":
					var shown := ""
					for o: Array in e.options:
						if o[0] == e.value:
							shown = o[1]
					piece = (shown + "_".repeat(length)).left(length)
		out += style + piece + "\u001b[0m"
		col = start + length
	return out + text.substr(col)


func _message(text: String) -> void:
	if p.tty == null:
		return
	p.out("\u001b[%d;1H\u001b[0m\u001b[K%s" % [_rows() + 2, text.left(_width - 1)])


# --- keys --------------------------------------------------------------------------

## The next key: a character or an escape sequence like "\e[A".
func _key() -> String:
	while true:
		if not _keys.is_empty():
			var k := _take_key()
			if not k.is_empty():
				return k
		var chunk: Variant = await p.stdin.read_some(func() -> bool: return p.is_dead() or _quit)
		if chunk == null:
			return "" if _keys.is_empty() else _take_key()
		_keys += chunk
	return ""


func _take_key() -> String:
	if _keys.begins_with("\u001b["):
		var end := 2
		while end < _keys.length() and not (_keys.unicode_at(end) >= 0x40 and _keys.unicode_at(end) <= 0x7e):
			end += 1
		if end >= _keys.length():
			return "" # the rest is on its way
		var seq := _keys.substr(0, end + 1)
		_keys = _keys.substr(end + 1)
		return seq
	var k := _keys.left(1)
	_keys = _keys.substr(1)
	return k


func _handle(key: String) -> void:
	_status = ""
	var focus := _focused_field()
	if not focus.is_empty():
		if key == char(0x7f) or key == "\b":
			focus.value = str(focus.value).left(maxi(0, str(focus.value).length() - 1))
			return
		if key == "\n" or key == "\r":
			await _submit(focus.form, {})
			return
		if key.length() == 1 and key.unicode_at(0) >= 32:
			if str(focus.value).length() < 256:
				focus.value = str(focus.value) + key
			return
	match key:
		"\u001b[B", "\t":
			_move(1)
		"\u001b[A":
			_move(-1)
		"\u001b[C", "\n", "\r":
			await _activate()
		"\u001b[D":
			_back()
		" ", "\u001b[6~", "+":
			_page_by(1)
		"b", "\u001b[5~", "-":
			_page_by(-1)
		"\u001b[H":
			_top = 0
			_cur = _first_link_from(0)
		"\u001b[F":
			_top = maxi(0, (_page.lines as Array).size() - _rows())
			_cur = _first_link_from(_top)
		"g", "G":
			var url: Variant = await _prompt("URL to open: ")
			if url != null and not str(url).strip_edges().is_empty():
				await _load(_to_url(str(url).strip_edges()), "GET", "", true)
		"q":
			var answer: Variant = await _prompt("Are you sure you want to quit? (y) ", true)
			if answer != null and (str(answer).is_empty() or str(answer).to_lower() == "y"):
				_quit = true
		"Q":
			_quit = true
		"\\":
			_source = not _source
			_layout()
			_top = 0
			_cur = _first_link_from(0)
		"/":
			var text: Variant = await _prompt("Enter a search string: ")
			if text != null and not str(text).is_empty():
				_search = str(text)
				_find(_search)
		"n":
			if not _search.is_empty():
				_find(_search)
		"=":
			_status = "URL: %s  (%d lines, %d links)" % [_url, (_page.lines as Array).size(), _page.links.size()]
		"h", "H", "?":
			if not _url.begins_with("about:"):
				_history.append({"url": _url, "html": _html, "base": _base, "top": _top, "cur": _cur})
			_show_html("about:lynx", ABOUT)
		"m", "M":
			pass
		"\u0012": # Ctrl-R
			if not _url.begins_with("about:"):
				var top := _top
				if await _load(_url, "GET", "", false):
					_top = mini(top, maxi(0, (_page.lines as Array).size() - 1))
		"\u000c": # Ctrl-L
			pass


func _move(dir: int) -> void:
	var k := _cur + dir
	while k >= 0 and k < _page.links.size() and not _selectable(_page.links[k]):
		k += dir
	if k < 0 or k >= _page.links.size():
		_page_by(dir)
		return
	_cur = k
	var line: int = _page.links[k].line
	if line < _top or line >= _top + _rows():
		_top = clampi(line - (0 if dir > 0 else _rows() - 1), 0, maxi(0, (_page.lines as Array).size() - 1))


func _page_by(dir: int) -> void:
	var total := (_page.lines as Array).size()
	var top := clampi(_top + dir * _rows(), 0, maxi(0, total - 1))
	if dir > 0 and _top + _rows() >= total:
		return
	_top = top
	_cur = _first_link_from(_top)


func _back() -> void:
	if _history.is_empty():
		_status = "You are already at the first document"
		return
	var h: Dictionary = _history.pop_back()
	_show_html(h.url, h.html)
	_base = h.base
	_top = h.top
	_cur = h.cur


func _activate() -> void:
	if _cur < 0:
		return
	var e: Dictionary = _page.links[_cur]
	match e.kind:
		"link":
			var url := AgoraHttp.resolve(_base, str(e.url))
			if url.begins_with("mailto:"):
				_status = "Alert!: Mail is not supported here."
				return
			await _load(url, "GET", "", true)
		"submit":
			await _submit(e.form, e)
		"checkbox":
			e.checked = not e.checked
		"radio":
			for other: Dictionary in _page.links:
				if other.kind == "radio" and other.form == e.form and other.name == e.name:
					other.checked = false
			e.checked = true
		"select":
			var options: Array = e.options
			for k in options.size():
				if options[k][0] == e.value:
					e.value = options[(k + 1) % options.size()][0]
					return


## Sends form [param form], pressed with [param button] (or {} for Enter
## in a field).
func _submit(form: int, button: Dictionary) -> void:
	if form < 0 or form >= _page.forms.size():
		return
	var f: Dictionary = _page.forms[form]
	var fields: Array = []
	for e: Dictionary in _page.links:
		if e.get("form", -1) != form or str(e.get("name", "")).is_empty():
			continue
		match e.kind:
			"text", "password", "hidden", "select":
				fields.append([e.name, e.value])
			"checkbox", "radio":
				if e.checked:
					fields.append([e.name, e.value if not str(e.value).is_empty() else "on"])
			"submit":
				if e == button:
					fields.append([e.name, e.value])
	var data := AgoraHttp.form_encode(fields)
	var action := AgoraHttp.resolve(_base, str(f.action) if not str(f.action).is_empty() else _url)
	if f.method == "POST":
		await _load(action, "POST", data, true)
	else:
		await _load(action.get_slice("?", 0) + "?" + data, "GET", "", true)


func _find(text: String) -> void:
	var lines: Array = _page.lines
	var start := _top + 1
	for k in lines.size():
		var li := (start + k) % lines.size()
		if (lines[li] as String).to_lower().contains(text.to_lower()):
			_top = li
			_cur = _first_link_from(li)
			return
	_status = "'%s' could not be found in this document" % text


## Reads a line on the status line. Null if cancelled (Ctrl-G, Esc).
func _prompt(question: String, one_key: bool = false) -> Variant:
	var text := ""
	while true:
		p.out("\u001b[%d;1H\u001b[0m\u001b[K%s%s\u001b[?25h" % [_rows() + 2, question, text])
		var key := await _key()
		if key.is_empty():
			return null
		if key in ["\n", "\r"]:
			return text
		if key in ["\u0007", "\u001b"]:
			return null
		if key == char(0x7f) or key == "\b":
			text = text.left(maxi(0, text.length() - 1))
		elif key.length() == 1 and key.unicode_at(0) >= 32:
			text += key
			if one_key:
				return text
	return null
