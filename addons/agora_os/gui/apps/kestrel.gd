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
const IMAGE_TYPES := {"image/gif": "gif", "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/bmp": "bmp", "image/webp": "webp"}

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
var _edit_menu := MenuButton.new()
var _find_text := ""
var _go_menu := MenuButton.new()
var _bookmarks_menu := MenuButton.new()
var _load_id := 0
var _visited := {}
var _images := {}
var _bookmarks: Array = [] # {url, title}
## The frames of a frameset page: name (or "#n") -> {view, scroll, url}.
var frames := {}
var _frame_root: Control


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
	for pair in [[_file_menu, "File"], [_edit_menu, "Edit"], [_go_menu, "Go"], [_bookmarks_menu, "Bookmarks"]]:
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
	var em := _edit_menu.get_popup()
	for item in ["Copy", "Select All", "", "Find in Page...", "Find Again"]:
		if item.is_empty():
			em.add_separator()
		else:
			em.add_item(item)
	_edit_menu.about_to_popup.connect(func() -> void:
		em.set_item_disabled(0, not view.has_selection())
		em.set_item_disabled(4, _find_text.is_empty()))
	em.index_pressed.connect(_on_edit_menu)
	_root.gui_input.connect(_on_key)
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
	view.gui_input.connect(_on_key)
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
	_render(view, r, final_url)
	if view.frameset.is_empty():
		_clear_frames()
	else:
		_build_frames(view.frameset, final_url)
	_scroll.scroll_vertical = 0
	var frag := str(current.url).get_slice("#", 1) if str(current.url).contains("#") else ""
	if not frag.is_empty() and view.anchors.has(frag):
		_scroll.scroll_vertical = int(view.anchors[frag])
	var t := view.title.strip_edges()
	_set_title(t if not t.is_empty() else final_url)
	_remember(final_url, t)
	_say("Document: Done." if int(r.code) < 400 else "Document: Done (%d %s)." % [r.code, r.get("reason", "")])


## Puts a fetched document into [param target]: HTML, text, an image, or a
## note about a type it can't show.
func _render(target: AgoraHtmlView, r: Dictionary, final_url: String) -> void:
	var type := str(r.headers.get("content-type", "text/html")).get_slice(";", 0).strip_edges().to_lower()
	var text := AgoraWire.encode(str(r.body)).get_string_from_utf8()
	if type == "text/html" or type.is_empty():
		target.set_page(text, final_url)
	elif type.begins_with("text/"):
		target.set_text(text, final_url)
	elif IMAGE_TYPES.has(type):
		_store_image(final_url, type, str(r.body))
		target.set_page("<body bgcolor=\"#ffffff\"><img src=\"%s\"></body>" % final_url, final_url)
		target.title = AgoraPath.basename(AgoraHttp.parse_url(final_url).get("path", final_url))
	else:
		target.set_page("<body bgcolor=\"#ffffff\"><h2>Unknown file type</h2><p>The file <tt>%s</tt> is of type <tt>%s</tt>, which Kestrel can't show. Use <b>File, Save As</b> to keep it.</p></body>" % [final_url, type], final_url)


# --- frames --------------------------------------------------------------------

func _clear_frames() -> void:
	frames.clear()
	if _frame_root:
		_frame_root.queue_free()
		_frame_root = null
	_scroll.visible = true


## A frameset page: the frames side by side or one above another, as
## rows= and cols= say, each loading its own document.
func _build_frames(fs: Dictionary, base: String) -> void:
	_clear_frames()
	_scroll.visible = false
	_frame_root = _frame_box(fs, base)
	_frame_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_frame_root)
	_root.move_child(_frame_root, _scroll.get_index() + 1)


## "20%,*,100" -> [[kind, value]]: "px", "%", "*".
static func frame_sizes(spec: String) -> Array:
	var out: Array = []
	for part in spec.split(",", false):
		var t := part.strip_edges()
		if t.ends_with("%"):
			out.append(["%", t.to_float()])
		elif t.ends_with("*"):
			out.append(["*", maxf(1.0, t.trim_suffix("*").to_float())])
		elif t.is_valid_float():
			out.append(["px", t.to_float()])
		else:
			out.append(["*", 1.0])
	return out


func _frame_box(fs: Dictionary, base: String) -> Control:
	var vertical := not str(fs.rows).is_empty()
	var box: BoxContainer = VBoxContainer.new() if vertical else HBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	var sizes := frame_sizes(str(fs.rows) if vertical else str(fs.cols))
	var pct := 0.0
	var stars := 0.0
	for sz: Array in sizes:
		if sz[0] == "%":
			pct += sz[1]
		elif sz[0] == "*":
			stars += sz[1]
	var children: Array = fs.children
	for k in children.size():
		var child: Dictionary = children[k]
		var c: Control = _frame_box(child, base) if child.has("children") else _make_frame(child, base)
		var sz: Array = sizes[k] if k < sizes.size() else ["*", 1.0]
		match sz[0]:
			"px":
				if vertical:
					c.custom_minimum_size.y = sz[1]
				else:
					c.custom_minimum_size.x = sz[1]
			"%":
				c.size_flags_stretch_ratio = maxf(1.0, sz[1])
			"*":
				c.size_flags_stretch_ratio = maxf(1.0, (100.0 - pct) * sz[1] / maxf(stars, 1.0))
		if sz[0] != "px":
			if vertical:
				c.size_flags_vertical = Control.SIZE_EXPAND_FILL
			else:
				c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		if vertical:
			c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		else:
			c.size_flags_vertical = Control.SIZE_EXPAND_FILL
		box.add_child(c)
	return box


func _make_frame(f: Dictionary, base: String) -> Control:
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if f.get("scrolling", "auto") == "no":
		scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var fv := AgoraHtmlView.new()
	fv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(fv)
	var name: String = f.name if not str(f.name).is_empty() else "#%d" % frames.size()
	var frame := {"name": name, "view": fv, "scroll": scroll, "url": ""}
	frames[name] = frame
	fv.link_clicked.connect(func(u: String) -> void: _on_frame_link(frame, u))
	fv.link_hovered.connect(func(u: String) -> void: _say(u if not u.is_empty() else _done_text()))
	fv.form_submitted.connect(func(u: String, method: String, body: String) -> void: load_frame(frame, u, method, body))
	fv.image_wanted.connect(func(u: String) -> void: _fetch_image(u, fv))
	fv.visited = func(u: String) -> bool: return _visited.has(u)
	if not str(f.src).is_empty():
		load_frame.call_deferred(frame, AgoraHttp.resolve(base, str(f.src)))
	return scroll


## Loads [param url] into a frame.
func load_frame(frame: Dictionary, url: String, method: String = "GET", body: String = "") -> void:
	var id := _load_id
	frame.url = url
	var r: Dictionary
	if url.begins_with("about:"):
		r = {"url": url, "code": 200, "headers": {"content-type": "text/html"}, "body": _about_page(url)}
	else:
		_say("Connecting to %s..." % AgoraHttp.parse_url(url).get("host", ""))
		r = await AgoraHttp.fetch(p, url, {"method": method, "body": body, "agent": AGENT, "timeout": 60.0})
	if id != _load_id or not win.open or not frames.has(frame.name) or frame.url != url:
		return # another page, or the frame went elsewhere meanwhile
	var fv: AgoraHtmlView = frame.view
	if r.has("error"):
		fv.set_page("<body bgcolor=\"#ffffff\"><p>Kestrel Navigator could not load <b>%s</b>.<p>(%s)</body>" % [url, r.error], url)
	else:
		frame.url = r.url
		_render(fv, r, r.url)
		_remember(r.url, fv.title.strip_edges())
	(frame.scroll as ScrollContainer).scroll_vertical = 0
	_say("Document: Done.")


## A link in a frame goes where its target says: the same frame, another
## one by name, the whole window (_top, _parent) or a new window (_blank,
## or a name no frame has).
func _on_frame_link(frame: Dictionary, url: String) -> void:
	var fv: AgoraHtmlView = frame.view
	var target := str(fv.link_targets.get(url, fv.base_target))
	match target:
		"", "_self":
			await load_frame(frame, url)
		"_top", "_parent":
			await go(url)
		_:
			if frames.has(target):
				await load_frame(frames[target], url)
			else:
				p.spawn(PackedStringArray([p.exe, url]), {"env": p.env, "cred": p.cred})


## The view of frame [param name] (tests), or null.
func frame_view(name: String) -> AgoraHtmlView:
	return frames[name].view if frames.has(name) else null


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
	_clear_frames()
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

func _fetch_image(url: String, into: AgoraHtmlView = null) -> void:
	if into == null:
		into = view
	if _images.has(url):
		into.set_image(url, _images[url])
		return
	var id := _load_id
	var r: Dictionary = await AgoraHttp.fetch(p, url, {"agent": AGENT, "timeout": 30.0})
	if not win or not win.open:
		return
	var tex: Texture2D = null
	if not r.has("error") and int(r.code) == 200:
		var type := str(r.headers.get("content-type", "")).get_slice(";", 0).strip_edges().to_lower()
		tex = _store_image(url, type, str(r.body))
	if into != view and is_instance_valid(into):
		into.set_image(url, tex)
	elif id == _load_id or view.url == str(current.get("url", "")):
		view.set_image(url, tex)


## Decodes image bytes (GIF, PNG, JPEG, BMP, WebP) into a texture.
func _store_image(url: String, type: String, body: String) -> Texture2D:
	var bytes := AgoraWire.encode(body)
	if AgoraGif.is_gif(bytes):
		var gif := AgoraGif.texture(bytes)
		_images[url] = gif
		return gif
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


# --- the Edit menu -------------------------------------------------------------

func _on_edit_menu(index: int) -> void:
	match index:
		0:
			copy()
		1:
			view.select_all()
		3:
			var what: Variant = await AgoraDialog.ask_text(_root, "Find text in page:", _find_text)
			if what != null:
				find(str(what))
		4:
			find(_find_text)


func _on_key(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_F and (event.ctrl_pressed or event.meta_pressed):
		_on_edit_menu(3)
	elif event.keycode == KEY_F3:
		_on_edit_menu(4)


## Copies the selected text. Returns it.
func copy() -> String:
	var text := view.copy()
	_say("Copied %d characters." % text.length() if not text.is_empty() else "Nothing selected.")
	return text


## Finds [param what] on the page and scrolls to it. Returns true if found.
func find(what: String) -> bool:
	_find_text = what
	var y := view.find_text(what)
	if y < 0:
		_say("\"%s\" not found." % what)
		return false
	_scroll.scroll_vertical = int(maxf(0.0, y - _scroll.size.y / 3.0))
	_say("Found \"%s\"." % what)
	return true


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
