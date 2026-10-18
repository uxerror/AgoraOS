extends AgoraGuiProgram
## Kestrel Navigator: the graphical web browser.
##
##   kestrel [URL]
##
## A toolbar (Back, Forward, Reload, Home, Stop), the Location field, the
## page ([AgoraHtmlView]) and a status line that tells what the browser is
## doing. Menus: File (New Window, Open Location, Save As, View Source,
## Close), Go (back and forward, recent pages) and Bookmarks.
##
## /etc/kestrel/kestrel.conf sets "homepage=". Bookmarks are kept in
## ~/.kestrel/bookmarks.html (Netscape's bookmark file format; the first
## start copies /etc/kestrel/bookmarks.html), visited pages in
## ~/.kestrel/history.

const VERSION := "1.0"
const AGENT := "Mozilla/4.0 (compatible; Kestrel/1.0; AgoraOS)"
const CONF := "/etc/kestrel/kestrel.conf"
const DEFAULT_BOOKMARKS := "/etc/kestrel/bookmarks.html"
const IMAGE_TYPES := {"image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/bmp": "bmp", "image/webp": "webp"}

var p: AgoraProcess
var win: AgoraWindow
var view := AgoraHtmlView.new()
## Where we are: {url, method, body}; back and forward stacks of those.
var current := {}
var back_stack: Array = []
var forward_stack: Array = []
## The last response: {url, code, headers, body} or {error}.
var page := {}
var loading := false
var homepage := "about:"

var _root := VBoxContainer.new()
var _location := LineEdit.new()
var _status := Label.new()
var _scroll := ScrollContainer.new()
var _throbber := _Throbber.new()
var _buttons := {}
var _file_menu := MenuButton.new()
var _go_menu := MenuButton.new()
var _bookmarks_menu := MenuButton.new()
var _load_id := 0
var _visited := {}
var _images := {}
var _bookmarks: Array = [] # {url, title}


## The animated logo in the corner: a bird's wing that beats while loading.
class _Throbber:
	extends Control
	var busy := false
	var phase := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(44, 40)

	func _process(delta: float) -> void:
		if busy:
			phase += delta * 6.0
			queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("#1d2a44"))
		var c := size / 2.0
		var beat := sin(phase) * 0.5 if busy else 0.25
		for side in [-1.0, 1.0]:
			var tip := c + Vector2(side * 16.0, -10.0 * beat - 2.0)
			draw_colored_polygon(PackedVector2Array([c + Vector2(0, 2), tip, c + Vector2(side * 10.0, 6.0)]), Color("#d9a441"))
		draw_circle(c + Vector2(0, -1), 3.0, Color("#f0e6c8"))
		if busy:
			for k in 3:
				var a := phase * 1.5 + k * 2.1
				draw_circle(c + Vector2(cos(a), sin(a)) * 15.0, 1.5, Color("#f5d76e"))


func summary() -> String:
	return "the Kestrel Navigator web browser"


func usage() -> String:
	return "usage: kestrel [URL]"


func main(proc: AgoraProcess) -> int:
	p = proc
	homepage = conf_value(p, PackedStringArray([CONF]), "homepage", "about:")
	_load_history()
	_load_bookmarks()
	_build()
	win = open_window(p, _root, {"title": "Kestrel Navigator", "size": Vector2(820, 600), "min_size": Vector2(360, 240)})
	if win == null:
		return 1
	win.focus_target = _location
	var start := p.argv[1] if p.argv.size() > 1 else homepage
	go(start)
	await win.closed
	_load_id += 1
	_disconnect()
	return 0


func _disconnect() -> void:
	for sig: Signal in [view.link_clicked, view.link_hovered, view.form_submitted, view.image_wanted]:
		for c: Dictionary in sig.get_connections():
			sig.disconnect(c.callable)
	view.visited = Callable()


# --- the window ----------------------------------------------------------------

func _build() -> void:
	_root.add_theme_constant_override("separation", 2)
	var menus := HBoxContainer.new()
	for pair in [[_file_menu, "File"], [_go_menu, "Go"], [_bookmarks_menu, "Bookmarks"]]:
		var m: MenuButton = pair[0]
		m.text = pair[1]
		m.flat = true
		menus.add_child(m)
	var fm := _file_menu.get_popup()
	for item in ["New Window", "Open Location...", "Save As...", "View Source", "", "Close"]:
		if item.is_empty():
			fm.add_separator()
		else:
			fm.add_item(item)
	fm.index_pressed.connect(_on_file_menu)
	_go_menu.about_to_popup.connect(_fill_go_menu)
	_go_menu.get_popup().index_pressed.connect(_on_go_menu)
	_bookmarks_menu.about_to_popup.connect(_fill_bookmarks_menu)
	_bookmarks_menu.get_popup().index_pressed.connect(_on_bookmarks_menu)
	_root.add_child(menus)

	var bar := HBoxContainer.new()
	for name in ["Back", "Forward", "Reload", "Home", "Stop"]:
		var b := Button.new()
		b.text = name
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size = Vector2(64, 34)
		bar.add_child(b)
		_buttons[name] = b
	_buttons.Back.pressed.connect(back)
	_buttons.Forward.pressed.connect(forward)
	_buttons.Reload.pressed.connect(reload)
	_buttons.Home.pressed.connect(func() -> void: go(homepage))
	_buttons.Stop.pressed.connect(stop)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	bar.add_child(_throbber)
	_root.add_child(bar)

	var loc := HBoxContainer.new()
	var label := Label.new()
	label.text = " Location:"
	loc.add_child(label)
	_location.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_location.text_submitted.connect(func(t: String) -> void: go(t))
	loc.add_child(_location)
	_root.add_child(loc)

	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	view.link_clicked.connect(_on_link)
	view.link_hovered.connect(func(u: String) -> void: _say(u if not u.is_empty() else _done_text()))
	view.form_submitted.connect(func(u: String, method: String, body: String) -> void: go(u, method, body))
	view.image_wanted.connect(_fetch_image)
	view.visited = func(u: String) -> bool: return _visited.has(u)
	_scroll.add_child(view)
	_root.add_child(_scroll)

	_status.clip_text = true
	_status.add_theme_font_size_override("font_size", 12)
	_root.add_child(_status)
	_update_buttons()


func _say(text: String) -> void:
	_status.text = " " + text


func _done_text() -> String:
	return "Document: Done." if not loading else _status.text.strip_edges()


func _update_buttons() -> void:
	_buttons.Back.disabled = back_stack.is_empty()
	_buttons.Forward.disabled = forward_stack.is_empty()
	_buttons.Stop.disabled = not loading
	_throbber.busy = loading
	_throbber.queue_redraw()


func _set_title(text: String) -> void:
	if win and win.open:
		win.title = "Kestrel Navigator - [%s]" % text if not text.is_empty() else "Kestrel Navigator"


# --- going places --------------------------------------------------------------

## What the user typed, as a URL: "www.x.org" -> "http://www.x.org/".
static func fix_url(text: String) -> String:
	text = text.strip_edges()
	if text.is_empty() or text.begins_with("about:") or text.begins_with("mailto:"):
		return text
	if text.begins_with("/"):
		return "file://localhost" + text
	if not text.contains("://"):
		text = "http://" + text
	var u := AgoraHttp.parse_url(text)
	return u.url if not u.is_empty() else text


## Loads [param url] (with a form body for POST). Returns the response
## ({url, code, headers, body} or {error}) once the page is shown.
func go(url: String, method: String = "GET", body: String = "", push: bool = true) -> Dictionary:
	url = fix_url(url)
	if url.is_empty():
		return {}
	if push and not current.is_empty():
		back_stack.append(current)
		forward_stack.clear()
	current = {"url": url, "method": method, "body": body}
	_location.text = url
	return await _load()


func back() -> void:
	if back_stack.is_empty():
		return
	forward_stack.append(current)
	current = back_stack.pop_back()
	_location.text = current.url
	await _load()


func forward() -> void:
	if forward_stack.is_empty():
		return
	back_stack.append(current)
	current = forward_stack.pop_back()
	_location.text = current.url
	await _load()


func reload() -> void:
	if not current.is_empty():
		await _load()


func stop() -> void:
	if loading:
		_load_id += 1
		loading = false
		_say("Transfer interrupted!")
		_update_buttons()


func _load() -> Dictionary:
	_load_id += 1
	var id := _load_id
	loading = true
	_update_buttons()
	var url: String = current.url
	var r: Dictionary
	if url.begins_with("about:"):
		r = {"url": url, "code": 200, "headers": {"content-type": "text/html"}, "body": _about_page(url)}
	else:
		var host := AgoraHttp.parse_url(url).get("host", "")
		_say("Connecting to %s..." % host if not str(host).is_empty() else "Opening file...")
		r = await AgoraHttp.fetch(p, url, {"method": current.method, "body": current.body, "agent": AGENT, "timeout": 60.0,
			"status": _on_step.bind(id, str(host))})
	if id != _load_id or not win.open:
		return r # stopped, or another page was asked for
	page = r
	loading = false
	if r.has("error"):
		_show_error(url, r)
	else:
		_show(r)
	_update_buttons()
	return r


func _on_step(step: String, id: int, host: String) -> void:
	if id == _load_id:
		_say(_status_text(step, host))


## lynx-style steps, in the words Netscape used.
static func _status_text(step: String, host: String) -> String:
	if step.begins_with("Looking up"):
		return "Looking up host: %s..." % host
	if step.begins_with("Making HTTP"):
		return "Connect: Contacting host: %s..." % host
	if step.begins_with("HTTP request sent"):
		return "Host contacted. Waiting for reply..."
	return step


func _show(r: Dictionary) -> void:
	var final_url: String = r.url
	if final_url != current.url:
		current.url = final_url
	_location.text = final_url
	var type := str(r.headers.get("content-type", "text/html")).get_slice(";", 0).strip_edges().to_lower()
	var text := AgoraWire.encode(str(r.body)).get_string_from_utf8()
	if type == "text/html" or type.is_empty():
		view.set_page(text, final_url)
	elif type.begins_with("text/"):
		view.set_text(text, final_url)
	elif IMAGE_TYPES.has(type):
		_store_image(final_url, type, str(r.body))
		view.set_page("<body bgcolor=\"#ffffff\"><img src=\"%s\"></body>" % final_url, final_url)
		view.title = AgoraPath.basename(AgoraHttp.parse_url(final_url).get("path", final_url))
	else:
		view.set_page("<body bgcolor=\"#ffffff\"><h2>Unknown file type</h2><p>The file <tt>%s</tt> is of type <tt>%s</tt>, which Kestrel can't show. Use <b>File, Save As</b> to keep it.</p></body>" % [final_url, type], final_url)
	_scroll.scroll_vertical = 0
	var frag := str(current.url).get_slice("#", 1) if str(current.url).contains("#") else ""
	if not frag.is_empty() and view.anchors.has(frag):
		_scroll.scroll_vertical = int(view.anchors[frag])
	var t := view.title.strip_edges()
	_set_title(t if not t.is_empty() else final_url)
	_remember(final_url, t)
	_say("Document: Done." if int(r.code) < 400 else "Document: Done (%d %s)." % [r.code, r.get("reason", "")])


func _show_error(url: String, r: Dictionary) -> void:
	var host := str(AgoraHttp.parse_url(url).get("host", url))
	var text := ""
	match str(r.get("stage", "")):
		"resolve":
			text = "Kestrel Navigator is unable to locate the server <b>%s</b>.<p>The server does not have a DNS entry. Check the server name in the Location (URL) and try again." % host
		"connect":
			if r.get("code_errno", 0) == AgoraErrno.ECONNREFUSED:
				text = "Kestrel Navigator is unable to connect to the server <b>%s</b>.<p>The server may not be accepting connections or may be busy. Try connecting again later." % host
			else:
				text = "There was no response. The server <b>%s</b> could be down or is not responding.<p>(%s)" % [host, r.error]
		"scheme":
			text = "Kestrel Navigator doesn't know how to open <b>%s</b>." % url
		_:
			text = "A network error occurred while Kestrel Navigator was receiving data from <b>%s</b>.<p>(%s)<p>Try connecting again." % [host, r.error]
	view.set_page("<body bgcolor=\"#ffffff\"><table width=\"100%%\" cellpadding=\"8\"><tr><td bgcolor=\"#ffffcc\"><font size=\"+1\"><b>Kestrel Navigator</b></font><p>%s</td></tr></table></body>" % text, url)
	_set_title("Error")
	_say("Document: Done.")


func _about_page(url: String) -> String:
	if url == "about:blank":
		return "<body bgcolor=\"#ffffff\"></body>"
	return """<html><head><title>About Kestrel Navigator</title></head>
<body bgcolor="#ffffff"><center><font size="+3" color="#1d2a44"><b>Kestrel Navigator</b></font><br>
<i>Version %s for AgoraOS</i><p>
<table border="1" cellpadding="6"><tr><td>
<b>Browsing tips</b><ul>
<li>Type an address in the Location field and press Enter.
<li>Bookmarks keep the sites you like; Go remembers where you have been.
<li>Pages travel as plain text over HTTP, port 80.
</ul></td></tr></table></center></body></html>""" % VERSION


func _on_link(url: String) -> void:
	if url.begins_with("mailto:"):
		await AgoraDialog.message(_root, "To write to %s, use your mail program." % url.substr(7).get_slice("?", 0))
		return
	var here := str(current.get("url", "")).get_slice("#", 0)
	if url.contains("#") and url.get_slice("#", 0) == here:
		var frag := url.get_slice("#", 1)
		if view.anchors.has(frag):
			_scroll.scroll_vertical = int(view.anchors[frag])
		return
	await go(url)


# --- images --------------------------------------------------------------------

func _fetch_image(url: String) -> void:
	if _images.has(url):
		view.set_image(url, _images[url])
		return
	var id := _load_id
	var r: Dictionary = await AgoraHttp.fetch(p, url, {"agent": AGENT, "timeout": 30.0})
	if not win or not win.open:
		return
	var tex: Texture2D = null
	if not r.has("error") and int(r.code) == 200:
		var type := str(r.headers.get("content-type", "")).get_slice(";", 0).strip_edges().to_lower()
		tex = _store_image(url, type, str(r.body))
	if id == _load_id or view.url == str(current.get("url", "")):
		view.set_image(url, tex)


## Decodes image bytes (PNG, JPEG, BMP, WebP) into a texture.
func _store_image(url: String, type: String, body: String) -> Texture2D:
	var bytes := AgoraWire.encode(body)
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	match IMAGE_TYPES.get(type, url.get_extension().to_lower()):
		"png": err = img.load_png_from_buffer(bytes)
		"jpg", "jpeg": err = img.load_jpg_from_buffer(bytes)
		"bmp": err = img.load_bmp_from_buffer(bytes)
		"webp": err = img.load_webp_from_buffer(bytes)
	var tex: Texture2D = ImageTexture.create_from_image(img) if err == OK and not img.is_empty() else null
	_images[url] = tex
	return tex


# --- history -------------------------------------------------------------------

func _dir() -> String:
	return p.home() + "/.kestrel"


func _load_history() -> void:
	for line in p.read_text(_dir() + "/history").split("\n", false):
		var f := line.split("\t")
		if f.size() >= 2:
			_visited[f[1]] = f[2] if f.size() > 2 else ""


func _remember(url: String, page_title: String) -> void:
	if url.begins_with("about:"):
		return
	_visited[url] = page_title
	p.make_dirs(_dir())
	p.write_text(_dir() + "/history", "%d\t%s\t%s\n" % [int(p.machine.clock.now()), url, page_title.replace("\t", " ")], true)


func _fill_go_menu() -> void:
	var m := _go_menu.get_popup()
	m.clear()
	m.add_item("Back")
	m.set_item_disabled(0, back_stack.is_empty())
	m.add_item("Forward")
	m.set_item_disabled(1, forward_stack.is_empty())
	m.add_item("Home")
	m.add_separator()
	var recent := back_stack.slice(maxi(0, back_stack.size() - 10))
	recent.reverse()
	for e: Dictionary in recent:
		var t: String = _visited.get(e.url, "")
		m.add_item(t if not t.is_empty() else str(e.url))
		m.set_item_metadata(m.item_count - 1, e.url)


func _on_go_menu(index: int) -> void:
	match index:
		0: back()
		1: forward()
		2: go(homepage)
		_:
			var u: Variant = _go_menu.get_popup().get_item_metadata(index)
			if u != null:
				go(str(u))


# --- bookmarks -----------------------------------------------------------------

func _bookmarks_file() -> String:
	return _dir() + "/bookmarks.html"


func _load_bookmarks() -> void:
	var text := p.read_text(_bookmarks_file())
	if text.is_empty():
		text = p.read_text(DEFAULT_BOOKMARKS)
		if not text.is_empty():
			p.make_dirs(_dir())
			p.write_text(_bookmarks_file(), text)
	_bookmarks = parse_bookmarks(text)


## The links of a Netscape bookmark file: [{url, title}].
static func parse_bookmarks(text: String) -> Array:
	var out: Array = []
	var href := ""
	var title := ""
	for t in AgoraHtml.tokenize(text):
		if t is String:
			if not href.is_empty():
				title += t
		elif t.tag == "a" and not t.close:
			href = str(t.attrs.get("href", ""))
			title = ""
		elif t.tag == "a" and t.close and not href.is_empty():
			out.append({"url": href, "title": AgoraHtml.decode_entities(title).strip_edges()})
			href = ""
	return out


static func bookmarks_text(list: Array, now: int) -> String:
	var out := "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<!-- This is an automatically generated file.\nIt will be read and overwritten.\nDo Not Edit! -->\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n\n<DL><p>\n"
	for b: Dictionary in list:
		out += "    <DT><A HREF=\"%s\" ADD_DATE=\"%d\">%s</A>\n" % [str(b.url).replace("\"", "%22"), now, str(b.title).replace("&", "&amp;").replace("<", "&lt;")]
	return out + "</DL><p>\n"


func add_bookmark() -> void:
	if current.is_empty():
		return
	var t := view.title.strip_edges()
	_bookmarks.append({"url": current.url, "title": t if not t.is_empty() else current.url})
	p.make_dirs(_dir())
	p.write_text(_bookmarks_file(), bookmarks_text(_bookmarks, int(p.machine.clock.now())))
	_say("Bookmark added.")


func bookmarks() -> Array:
	return _bookmarks


func _fill_bookmarks_menu() -> void:
	var m := _bookmarks_menu.get_popup()
	m.clear()
	m.add_item("Add Bookmark")
	m.add_separator()
	for b: Dictionary in _bookmarks:
		m.add_item(str(b.title).left(60))


func _on_bookmarks_menu(index: int) -> void:
	if index == 0:
		add_bookmark()
	elif index >= 2 and index - 2 < _bookmarks.size():
		go(str(_bookmarks[index - 2].url))


# --- the File menu -------------------------------------------------------------

func _on_file_menu(index: int) -> void:
	match index:
		0:
			p.spawn(PackedStringArray([AgoraPrograms.path_for("kestrel"), str(current.get("url", homepage))]), {"stdin": AgoraStream.empty()})
		1:
			var u: Variant = await AgoraDialog.ask_text(_root, "Open location:", str(current.get("url", "")))
			if u != null:
				go(str(u))
		2:
			await save_as_dialog()
		3:
			view_source()
		5:
			win.close()


## The file name a page would be saved under.
func suggested_name() -> String:
	var path := str(AgoraHttp.parse_url(str(current.get("url", ""))).get("path", "/"))
	var name := AgoraPath.basename(path)
	return name if not name.is_empty() and name != "/" else "index.html"


func save_as_dialog() -> void:
	var answer: Variant = await AgoraDialog.ask_text(_root, "Save as:", p.home() + "/" + suggested_name())
	if answer != null and not str(answer).strip_edges().is_empty():
		var e := save_page(str(answer).strip_edges())
		_say("Saved %s." % answer if e == AgoraErrno.OK else "Cannot save %s: %s" % [answer, AgoraErrno.describe(e)])


## Writes the page as it came from the server. Returns an errno.
func save_page(path: String) -> int:
	if page.is_empty() or page.has("error"):
		return AgoraErrno.ENOENT
	return p.write_bytes(p.abspath(path), AgoraWire.encode(str(page.body)))


func view_source() -> void:
	if page.is_empty() or page.has("error"):
		return
	var code := CodeEdit.new()
	code.text = AgoraWire.encode(str(page.body)).get_string_from_utf8()
	code.editable = false
	code.add_theme_font_override("font", AgoraStyle.MONO)
	code.add_theme_font_size_override("font_size", 13)
	open_window(p, code, {"title": "Source of: %s" % current.url, "size": Vector2(700, 480)})
