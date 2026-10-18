class_name AgoraHtmlView
extends Control
## Shows an HTML page the way a 2003 graphical browser did: block and
## inline layout with word wrapping, headings, lists, <pre>, <center>,
## <font> sizes and colors, tables with automatic column widths, cell
## colors and borders, images, links and forms. Form fields are real
## controls placed on the page.
##
## Give it a page with [method set_page]; it lays itself out to its width
## and asks for its height (put it in a ScrollContainer). Clicking a link
## emits [signal link_clicked], sending a form [signal form_submitted].
## Images are fetched by whoever listens to [signal image_wanted] and
## handed back with [method set_image].

signal link_clicked(url: String)
signal link_hovered(url: String)
signal form_submitted(url: String, method: String, body: String)
signal image_wanted(url: String)
## The selection changed (to copy, or to enable a Copy menu item).
signal selection_changed

const SELECTION_BG := Color("#0a246a")
const SELECTION_FG := Color.WHITE

const VOID := ["br", "hr", "img", "input", "meta", "link", "base", "area", "col", "param", "wbr", "isindex"]
const BLOCKS := ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "dt", "dd", "pre", "blockquote",
	"table", "form", "address", "center", "hr", "li", "listing", "xmp", "menu", "dir", "noscript", "fieldset"]
## Elements whose start closes an open <p>.
const CLOSES_P := ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "dl", "pre", "blockquote", "table",
	"form", "address", "center", "hr", "listing", "xmp", "menu", "dir", "fieldset"]
const HEADING_SIZES := {"h1": 32, "h2": 24, "h3": 19, "h4": 16, "h5": 13, "h6": 11}
## <font size=1..7> in pixels.
const FONT_SIZES := [10, 13, 15, 18, 24, 32, 48]
const BASE_SIZE := 15
const INDENT := 40.0
const MARGIN := 8.0
const FIELD_FONT := 13
const FIELD_HEIGHT := 24.0

var url := ""
var title := ""
var base_url := ""
## Colors from <body>.
var background := Color("#c0c0c0")
var text_color := Color.BLACK
var link_color := Color("#0000ee")
var visited_color := Color("#551a8b")
## Whether a URL was visited before (for link colors).
var visited: Callable
## Positions of <a name> anchors after layout: name -> y.
var anchors := {}

var _root := {}
var _forms: Array = []
var _images := {} # url -> Texture2D, or null while unknown/failed
var _asked := {} # image urls already requested
var _controls := {} # field node id -> Control
var _list := _DisplayList.new()
var _laid_width := -1.0
var _hover := ""
var _fonts := {}
var _radio_groups := {}
## The selection: from and to as Vector2i(text item, character), or
## (-1, -1) when nothing is selected.
var _sel_from := Vector2i(-1, -1)
var _sel_to := Vector2i(-1, -1)
var _press_pos := Vector2.ZERO
var _press_link := ""
var _dragging := false

static var _classic: Theme


func _init() -> void:
	theme = classic_theme()
	focus_mode = Control.FOCUS_CLICK
	# Scaled pictures keep sharp pixels, as browsers of the time drew them.
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


## Form controls as pages of the time had them: grey buttons, white fields.
static func classic_theme() -> Theme:
	if _classic:
		return _classic
	var t := Theme.new()
	t.default_font_size = FIELD_FONT
	for type in ["LineEdit", "TextEdit", "Button", "OptionButton", "CheckBox"]:
		t.set_font_size("font_size", type, FIELD_FONT)
		t.set_font("font", type, ThemeDB.fallback_font)
	var face := Color("#d4d0c8")
	var edge := Color("#808080")
	var box := func(bg: Color, h: float, v: float) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.border_color = edge
		sb.set_border_width_all(1)
		sb.content_margin_left = h
		sb.content_margin_right = h
		sb.content_margin_top = v
		sb.content_margin_bottom = v
		return sb
	for type in ["Button", "OptionButton"]:
		t.set_stylebox("normal", type, box.call(face, 8.0, 2.0))
		t.set_stylebox("hover", type, box.call(face.lightened(0.15), 8.0, 2.0))
		t.set_stylebox("pressed", type, box.call(face.darkened(0.12), 8.0, 2.0))
		t.set_stylebox("focus", type, StyleBoxEmpty.new())
		for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
			t.set_color(key, type, Color.BLACK)
	for type in ["LineEdit", "TextEdit"]:
		t.set_stylebox("normal", type, box.call(Color.WHITE, 3.0, 2.0))
		t.set_stylebox("focus", type, box.call(Color.WHITE, 3.0, 2.0))
		t.set_stylebox("read_only", type, box.call(face, 3.0, 2.0))
		t.set_color("font_color", type, Color.BLACK)
		t.set_color("caret_color", type, Color.BLACK)
		t.set_color("selection_color", type, Color("#0a246a"))
		t.set_color("font_selected_color", type, Color.WHITE)
	t.set_color("font_color", "CheckBox", Color.BLACK)
	t.set_color("font_hover_color", "CheckBox", Color.BLACK)
	t.set_color("font_pressed_color", "CheckBox", Color.BLACK)
	for type in ["CheckBox"]:
		for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			t.set_stylebox(state, type, StyleBoxEmpty.new())
	t.set_icon("unchecked", "CheckBox", _tick_icon(false, false))
	t.set_icon("checked", "CheckBox", _tick_icon(true, false))
	t.set_icon("radio_unchecked", "CheckBox", _tick_icon(false, true))
	t.set_icon("radio_checked", "CheckBox", _tick_icon(true, true))
	var arrow := Image.create_empty(9, 5, false, Image.FORMAT_RGBA8)
	for k in 5:
		arrow.fill_rect(Rect2i(k, k, 9 - k * 2, 1), Color.BLACK)
	t.set_icon("arrow", "OptionButton", ImageTexture.create_from_image(arrow))
	t.set_constant("h_separation", "CheckBox", 0)
	t.set_constant("check_v_offset", "CheckBox", 0)
	_classic = t
	return t


## Puts the classic look on [param c] directly (theme overrides apply at
## once; an inherited theme only once the control is in the tree).
static func apply_classic(c: Control) -> void:
	var t := classic_theme()
	var type := c.get_class()
	for n in t.get_stylebox_list(type):
		c.add_theme_stylebox_override(n, t.get_stylebox(n, type))
	for n in t.get_color_list(type):
		c.add_theme_color_override(n, t.get_color(n, type))
	for n in t.get_font_size_list(type):
		c.add_theme_font_size_override(n, t.get_font_size(n, type))
	for n in t.get_font_list(type):
		c.add_theme_font_override(n, t.get_font(n, type))
	for n in t.get_icon_list(type):
		c.add_theme_icon_override(n, t.get_icon(n, type))
	for n in t.get_constant_list(type):
		c.add_theme_constant_override(n, t.get_constant(n, type))


static func _tick_icon(on: bool, round: bool) -> Texture2D:
	var img := Image.create_empty(13, 13, false, Image.FORMAT_RGBA8)
	for y in 13:
		for x in 13:
			var inside := Vector2(x - 6, y - 6).length() <= 6.0 if round else true
			var edge_px := Vector2(x - 6, y - 6).length() > 5.0 if round else (x == 0 or y == 0 or x == 12 or y == 12)
			if inside:
				img.set_pixel(x, y, Color("#808080") if edge_px else Color.WHITE)
	if on:
		if round:
			for y in range(4, 9):
				for x in range(4, 9):
					if Vector2(x - 6, y - 6).length() <= 2.3:
						img.set_pixel(x, y, Color.BLACK)
		else:
			for k in 3:
				img.fill_rect(Rect2i(3 + k, 5 + k, 1, 3), Color.BLACK)
			for k in 4:
				img.fill_rect(Rect2i(6 + k, 6 - k, 1, 3), Color.BLACK)
	return ImageTexture.create_from_image(img)


# --- the page ------------------------------------------------------------------

## Shows [param html], which came from [param page_url].
func set_page(html: String, page_url: String) -> void:
	for c in _controls.values():
		(c as Control).queue_free()
	_controls.clear()
	_radio_groups.clear()
	_images.clear()
	_asked.clear()
	_forms.clear()
	_sel_from = Vector2i(-1, -1)
	_sel_to = Vector2i(-1, -1)
	url = page_url
	base_url = page_url
	title = ""
	background = Color("#c0c0c0")
	text_color = Color.BLACK
	link_color = Color("#0000ee")
	visited_color = Color("#551a8b")
	_root = parse(html)
	title = _root.title
	if _root.has("base"):
		base_url = AgoraHttp.resolve(page_url, _root.base)
	for fn: Dictionary in _root.forms:
		var fa: Dictionary = fn.attrs
		_forms.append({"action": AgoraHttp.resolve(base_url, str(fa.action)) if fa.has("action") else page_url,
			"method": str(fa.get("method", "get")).to_upper()})
	var body: Dictionary = _root.body
	background = _color(body.get("bgcolor", ""), background)
	text_color = _color(body.get("text", ""), text_color)
	link_color = _color(body.get("link", ""), link_color)
	visited_color = _color(body.get("vlink", ""), visited_color)
	_laid_width = -1.0
	relayout()


## Shows plain text in a monospace font, as browsers show text/plain.
func set_text(text: String, page_url: String) -> void:
	set_page("<body bgcolor=\"#ffffff\"><pre>%s</pre></body>" % text.replace("&", "&amp;").replace("<", "&lt;"), page_url)


## Hands over a fetched image (null if it couldn't be had).
func set_image(image_url: String, tex: Texture2D) -> void:
	_images[image_url] = tex
	_laid_width = -1.0
	relayout()


func _resolve(href: String) -> String:
	return AgoraHttp.resolve(base_url, href)


# --- parsing -------------------------------------------------------------------

static var _next_id := 0


static func _node(tag: String, attrs: Dictionary) -> Dictionary:
	_next_id += 1
	return {"tag": tag, "attrs": attrs, "children": [], "id": _next_id}


## A forgiving DOM: {tag: "#root", children, title, body (attrs), base}.
## Text is a node {tag: "#text", text}.
static func parse(html: String) -> Dictionary:
	var root := _node("#root", {})
	root.title = ""
	root.body = {}
	root.forms = []
	var stack: Array = [root]
	var in_title := false
	for t in AgoraHtml.tokenize(html):
		if t is String:
			if in_title:
				root.title += AgoraHtml.decode_entities(t)
			else:
				(stack[-1].children as Array).append({"tag": "#text", "text": t})
			continue
		var tag: String = t.tag
		if tag in ["html", "head", "tbody", "thead", "tfoot", "meta", "link", "frameset"]:
			continue
		if tag == "title":
			in_title = not t.close
			continue
		if tag == "body":
			if not t.close:
				root.body.merge(t.attrs, true)
			continue
		if tag == "base":
			root.base = str(t.attrs.get("href", ""))
			continue
		if t.close:
			_close(stack, tag)
			continue
		# Implied end tags.
		if tag in CLOSES_P:
			_close_in_scope(stack, "p", ["table", "td", "th", "li", "blockquote", "div", "center"])
		match tag:
			"li":
				_close_in_scope(stack, "li", ["ul", "ol", "menu", "dir", "table"])
			"dt", "dd":
				_close_in_scope(stack, "dt", ["dl", "table"])
				_close_in_scope(stack, "dd", ["dl", "table"])
			"tr":
				_close_in_scope(stack, "td", ["table"])
				_close_in_scope(stack, "th", ["table"])
				_close_in_scope(stack, "tr", ["table"])
			"td", "th":
				_close_in_scope(stack, "td", ["tr", "table"])
				_close_in_scope(stack, "th", ["tr", "table"])
				if stack[-1].tag == "table":
					var tr := _node("tr", {})
					(stack[-1].children as Array).append(tr)
					stack.append(tr)
			"option":
				_close_in_scope(stack, "option", ["select"])
		var n := _node(tag, t.attrs)
		if tag == "form":
			n.index = (root.forms as Array).size()
			root.forms.append(n)
		(stack[-1].children as Array).append(n)
		if not tag in VOID:
			stack.append(n)
	return root


static func _close(stack: Array, tag: String) -> void:
	for k in range(stack.size() - 1, 0, -1):
		if stack[k].tag == tag:
			stack.resize(k)
			return
		# An end tag doesn't reach out of a table cell or the table.
		if stack[k].tag in ["td", "th", "table"] and not tag in ["td", "th", "tr", "table"]:
			return


static func _close_in_scope(stack: Array, tag: String, scope: Array) -> void:
	for k in range(stack.size() - 1, 0, -1):
		if stack[k].tag == tag:
			stack.resize(k)
			return
		if stack[k].tag in scope:
			return


static func _color(text: String, default: Color) -> Color:
	text = text.strip_edges()
	if text.is_empty():
		return default
	if not text.begins_with("#") and text.length() == 6 and text.is_valid_hex_number():
		text = "#" + text
	return Color.from_string(text, default)


# --- fonts ---------------------------------------------------------------------

func _font(style: Dictionary) -> Font:
	var key := "%s%s%s" % [style.bold, style.italic, style.mono]
	if not _fonts.has(key):
		var base: Font = AgoraStyle.MONO if style.mono else ThemeDB.fallback_font
		if style.mono and style.bold:
			base = AgoraStyle.MONO_BOLD
		var f := FontVariation.new()
		f.base_font = base
		if style.bold and not style.mono:
			f.variation_embolden = 0.8
		if style.italic:
			f.variation_transform = Transform2D(Vector2(1, 0.2), Vector2(0, 1), Vector2.ZERO)
		_fonts[key] = f
	return _fonts[key]


func _base_style() -> Dictionary:
	return {"size": BASE_SIZE, "bold": false, "italic": false, "mono": false, "color": text_color,
		"link": "", "underline": false, "pre": false, "form": -1, "nowrap": false}


# --- layout --------------------------------------------------------------------

## Items placed on the page, in page coordinates.
class _DisplayList:
	var rects: Array = [] # [Rect2, Color]
	var frames: Array = [] # [Rect2, Color light, Color dark, width]
	var texts: Array = [] # [Vector2 baseline, text, Font, size, Color, underline]
	var images: Array = [] # [Rect2, Texture2D or null, alt]
	var lines: Array = [] # [from, to, Color]
	var links: Array = [] # [Rect2, url]
	var fields: Array = [] # [Rect2, id]
	var anchors := {}

	func append(other: _DisplayList, d: Vector2) -> void:
		for r in other.rects:
			rects.append([Rect2(r[0].position + d, r[0].size), r[1]])
		for r in other.frames:
			frames.append([Rect2(r[0].position + d, r[0].size), r[1], r[2], r[3]])
		for t in other.texts:
			texts.append([t[0] + d, t[1], t[2], t[3], t[4], t[5]])
		for i in other.images:
			images.append([Rect2(i[0].position + d, i[0].size), i[1], i[2]])
		for l in other.lines:
			lines.append([l[0] + d, l[1] + d, l[2]])
		for l in other.links:
			links.append([Rect2(l[0].position + d, l[0].size), l[1]])
		for f in other.fields:
			fields.append([Rect2(f[0].position + d, f[0].size), f[1]])
		for a: String in other.anchors:
			anchors[a] = other.anchors[a] + d.y


## A block formatting context: lines of inline items stacked downwards.
class _Ctx:
	var dl := _DisplayList.new()
	var left := 0.0
	var width := 0.0
	var y := 0.0
	var max_right := 0.0
	var line: Array = [] # {w, asc, desc, kind, ...}
	var line_w := 0.0
	var space := false
	## The style of the text the pending space came with.
	var space_style: Dictionary = {}
	var margin := 0.0
	var align := "left"
	var started := false
	var marker: Dictionary = {}
	var view: AgoraHtmlView

	func _init(p_view: AgoraHtmlView, p_left: float, p_width: float) -> void:
		view = p_view
		left = p_left
		width = p_width
		max_right = p_left

	## A vertical gap before the next thing (gaps don't add up).
	func gap(m: float) -> void:
		margin = maxf(margin, m)

	func _apply_margin() -> void:
		if started:
			y += margin
		margin = 0.0
		started = true

	func add_item(item: Dictionary, breakable_before: bool) -> void:
		if breakable_before and not line.is_empty() and line_w + item.w > width:
			flush()
		line.append(item)
		line_w += item.w

	func add_space(style: Dictionary) -> void:
		if line.is_empty():
			return
		var f := view._font(style)
		var w := f.get_string_size(" ", HORIZONTAL_ALIGNMENT_LEFT, -1, style.size).x
		line.append({"kind": "space", "w": w, "asc": f.get_ascent(style.size), "desc": f.get_descent(style.size), "style": style})
		line_w += w

	func flush(force: bool = false, style: Dictionary = {}) -> void:
		# Trailing spaces don't count.
		while not line.is_empty() and line[-1].kind == "space":
			line_w -= line[-1].w
			line.pop_back()
		if line.is_empty() and not force and marker.is_empty():
			return
		_apply_margin()
		var asc := 0.0
		var desc := 0.0
		if line.is_empty():
			var s: Dictionary = style if not style.is_empty() else view._base_style()
			var f := view._font(s)
			asc = f.get_ascent(s.size)
			desc = f.get_descent(s.size)
		for it: Dictionary in line:
			asc = maxf(asc, it.asc)
			desc = maxf(desc, it.desc)
		var x := left
		if align == "center":
			x += maxf(0.0, (width - line_w) / 2.0)
		elif align == "right":
			x += maxf(0.0, width - line_w)
		var base := y + asc
		if not marker.is_empty():
			var mf := view._font(marker.style)
			var mw := mf.get_string_size(marker.text, HORIZONTAL_ALIGNMENT_LEFT, -1, marker.style.size).x
			dl.texts.append([Vector2(left - mw - 6.0, base), marker.text, mf, marker.style.size, marker.style.color, false])
			marker = {}
		for it: Dictionary in line:
			match it.kind:
				"text", "space":
					var s: Dictionary = it.style
					if it.kind == "text":
						dl.texts.append([Vector2(x, base), it.text, view._font(s), s.size, view._style_color(s), s.underline or not str(s.link).is_empty()])
					elif not str(s.link).is_empty():
						dl.lines.append([Vector2(x, base + 2), Vector2(x + it.w, base + 2), view._style_color(s)])
					if not str(s.link).is_empty():
						dl.links.append([Rect2(x, base - it.asc, it.w, it.asc + it.desc), s.link])
				"image":
					var r := Rect2(x + it.hspace, base - it.asc + it.vspace, it.w - it.hspace * 2, it.asc - it.vspace * 2)
					if it.border > 0:
						dl.rects.append([r.grow(it.border), it.border_color])
					dl.images.append([r, it.tex, it.alt])
					if not str(it.link).is_empty():
						dl.links.append([r, it.link])
				"field":
					dl.fields.append([Rect2(x, base - it.asc, it.w, it.asc + it.desc), it.id])
				"anchor":
					dl.anchors[it.name] = y
			x += it.w
		max_right = maxf(max_right, x)
		y += asc + desc + 1.0
		line.clear()
		line_w = 0.0
		space = false

	## Content that is a block of its own (a table, a rule): [param h] high.
	func place_block(h: float) -> void:
		flush()
		_apply_margin()
		y += h


func _style_color(s: Dictionary) -> Color:
	if not str(s.link).is_empty() and not s.get("link_color_set", false):
		return visited_color if visited.is_valid() and visited.call(s.link) else link_color
	return s.color


## Lays the page out again for the current width.
func relayout() -> void:
	if _root.is_empty():
		return
	var w := maxf(size.x, 200.0)
	if is_equal_approx(w, _laid_width):
		return
	_laid_width = w
	clear_selection()
	var ctx := _Ctx.new(self, MARGIN, w - MARGIN * 2)
	ctx.y = MARGIN
	_blocks(_root, ctx, _base_style())
	ctx.flush()
	_list = ctx.dl
	anchors = _list.anchors
	custom_minimum_size.y = ctx.y + MARGIN
	_place_controls()
	# New controls know their real minimum size only once in the tree.
	_place_controls.call_deferred()
	queue_redraw()


## The height the page needs at [param width] (for tests and printing).
func layout_height() -> float:
	return custom_minimum_size.y


func _blocks(node: Dictionary, ctx: _Ctx, style: Dictionary) -> void:
	for child: Dictionary in node.children:
		_element(child, ctx, style)


func _element(n: Dictionary, ctx: _Ctx, style: Dictionary) -> void:
	var tag: String = n.tag
	if tag == "#text":
		_text(str(n.text), ctx, style)
		return
	var s := style.duplicate()
	var a: Dictionary = n.attrs
	match tag:
		"b", "strong":
			s.bold = true
		"i", "em", "cite", "var", "dfn":
			s.italic = true
		"u", "ins":
			s.underline = true
		"tt", "code", "kbd", "samp":
			s.mono = true
		"big":
			s.size = int(s.size * 1.2)
		"small":
			s.size = maxi(9, int(s.size * 0.83))
		"sup", "sub":
			s.size = maxi(9, int(s.size * 0.75))
		"font":
			if a.has("size"):
				s.size = _font_size(str(a.size), s.size)
			if a.has("color"):
				s.color = _color(str(a.color), s.color)
				s.link_color_set = true
			if a.has("face") and str(a.face).to_lower().contains("courier"):
				s.mono = true
		"a":
			if a.has("href"):
				s.link = _resolve(str(a.href))
				s.link_color_set = false
			if a.has("name"):
				ctx.add_item({"kind": "anchor", "w": 0.0, "asc": 0.0, "desc": 0.0, "name": str(a.name)}, false)
		"br":
			if ctx.line.is_empty():
				ctx.flush(true, s)
			else:
				ctx.flush()
			return
		"img":
			_image(n, ctx, s)
			return
		"input", "select", "textarea", "button":
			_field(n, ctx, s)
			return
		"hr":
			_hr(n, ctx)
			return
		"table":
			_table(n, ctx, s)
			return
		"form":
			s.form = int(n.index)
			ctx.flush()
			_blocks(n, ctx, s)
			ctx.flush()
			ctx.gap(s.size * 0.8)
			return
		"script", "style", "noframes", "map", "option":
			return
		"nobr":
			s.nowrap = true
	if tag in BLOCKS:
		_block(n, ctx, s)
		return
	_blocks(n, ctx, s)


func _font_size(text: String, current: int) -> int:
	text = text.strip_edges()
	var level := 3
	var cur := FONT_SIZES.find(current)
	if cur < 0:
		cur = 2
	if text.begins_with("+") or text.begins_with("-"):
		level = cur + 1 + text.to_int()
	else:
		level = text.to_int()
	return FONT_SIZES[clampi(level, 1, 7) - 1]


func _block(n: Dictionary, ctx: _Ctx, s: Dictionary) -> void:
	var tag: String = n.tag
	var a: Dictionary = n.attrs
	var em: float = s.size
	ctx.flush()
	var old_align := ctx.align
	var old_left := ctx.left
	var old_width := ctx.width
	var top := 0.0
	var bottom := 0.0
	match tag:
		"p":
			top = em * 0.9
			bottom = em * 0.9
		"h1", "h2", "h3", "h4", "h5", "h6":
			s.size = HEADING_SIZES[tag]
			s.bold = true
			top = s.size * 0.6
			bottom = s.size * 0.6
		"ul", "ol", "menu", "dir":
			var nested: bool = s.get("list_depth", 0) > 0
			top = 0.0 if nested else em * 0.9
			bottom = top
			ctx.left += INDENT
			ctx.width -= INDENT
			s.list_depth = s.get("list_depth", 0) + 1
			s.list_kind = "ol" if tag == "ol" else "ul"
			s.list_type = str(a.get("type", ""))
			var number := str(a.get("start", "1")).to_int()
			for child: Dictionary in n.children:
				if child.tag == "li":
					child.number = number
					number += 1
		"li":
			var kind: String = s.get("list_kind", "ul")
			var marker := ""
			if kind == "ol":
				marker = "%d." % int(n.get("number", 1))
			else:
				marker = ["•", "◦", "▪"][(int(s.get("list_depth", 1)) - 1) % 3]
			var ms := s.duplicate()
			ms.link = ""
			ctx.marker = {"text": marker, "style": ms}
		"dl":
			top = em * 0.9
			bottom = top
		"dd":
			ctx.left += INDENT
			ctx.width -= INDENT
		"blockquote":
			top = em * 0.9
			bottom = top
			ctx.left += INDENT
			ctx.width -= INDENT * 2
		"pre", "listing", "xmp":
			s.pre = true
			s.mono = true
			s.size = 13
			top = em * 0.9
			bottom = top
		"center":
			ctx.align = "center"
		"address":
			s.italic = true
		"div":
			pass
	var al := str(a.get("align", "")).to_lower()
	if al in ["center", "middle"]:
		ctx.align = "center"
	elif al == "right":
		ctx.align = "right"
	elif al == "left":
		ctx.align = "left"
	ctx.gap(top)
	_blocks(n, ctx, s)
	ctx.flush()
	if not ctx.marker.is_empty():
		ctx.flush(true, s)
	ctx.gap(bottom)
	ctx.align = old_align
	ctx.left = old_left
	ctx.width = old_width


func _text(text: String, ctx: _Ctx, s: Dictionary) -> void:
	var f := _font(s)
	var asc := f.get_ascent(s.size)
	var desc := f.get_descent(s.size)
	if s.pre:
		var lines := AgoraHtml.decode_entities(text).replace("\r", "").split("\n")
		for k in lines.size():
			if k > 0:
				ctx.flush(true, s)
			var line := lines[k].replace("\t", "        ")
			if not line.is_empty():
				ctx.add_item({"kind": "text", "text": line, "style": s, "asc": asc, "desc": desc,
					"w": f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, s.size).x}, false)
		return
	var words := text.replace("\n", " ").replace("\t", " ").replace("\r", " ")
	if words.begins_with(" ") and not ctx.space:
		ctx.space = true
		ctx.space_style = s
	var parts := words.split(" ", false)
	for k in parts.size():
		var word := AgoraHtml.decode_entities(parts[k])
		if k == 0 and ctx.space:
			ctx.add_space(ctx.space_style if not ctx.space_style.is_empty() else s)
		elif k > 0:
			ctx.add_space(s)
		ctx.space = false
		var w := f.get_string_size(word, HORIZONTAL_ALIGNMENT_LEFT, -1, s.size).x
		var after_space: bool = ctx.line.is_empty() or ctx.line[-1].kind == "space"
		ctx.add_item({"kind": "text", "text": word, "style": s, "asc": asc, "desc": desc, "w": w}, after_space and not s.nowrap)
	if words.ends_with(" ") and not parts.is_empty():
		ctx.space = true
		ctx.space_style = s


func _hr(n: Dictionary, ctx: _Ctx) -> void:
	var a: Dictionary = n.attrs
	ctx.flush()
	ctx.gap(6.0)
	ctx._apply_margin()
	var w := ctx.width
	var wa := str(a.get("width", ""))
	if wa.ends_with("%"):
		w = ctx.width * clampf(wa.to_float() / 100.0, 0.0, 1.0)
	elif wa.is_valid_int():
		w = minf(ctx.width, wa.to_float())
	var h := maxf(2.0, str(a.get("size", "2")).to_float())
	var x := ctx.left + (ctx.width - w) / 2.0
	if str(a.get("align", "")).to_lower() == "left":
		x = ctx.left
	ctx.dl.frames.append([Rect2(x, ctx.y, w, h), background.darkened(0.45), background.lightened(0.5), 1.0])
	ctx.max_right = maxf(ctx.max_right, x + w)
	ctx.y += h
	ctx.gap(6.0)


func _image(n: Dictionary, ctx: _Ctx, s: Dictionary) -> void:
	var a: Dictionary = n.attrs
	var src := _resolve(str(a.get("src", "")))
	var tex: Texture2D = _images.get(src)
	if not str(a.get("src", "")).is_empty() and not _asked.has(src):
		_asked[src] = true
		image_wanted.emit.call_deferred(src)
	var alt := AgoraHtml.decode_entities(str(a.get("alt", "")))
	var w := str(a.get("width", "")).to_float()
	var h := str(a.get("height", "")).to_float()
	if tex:
		if w <= 0 and h <= 0:
			w = tex.get_width()
			h = tex.get_height()
		elif w <= 0:
			w = tex.get_width() * h / tex.get_height()
		elif h <= 0:
			h = tex.get_height() * w / tex.get_width()
	else:
		var f := _font(s)
		if w <= 0:
			w = maxf(24.0, f.get_string_size(alt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 22.0) if not alt.is_empty() else 24.0
		if h <= 0:
			h = 24.0
	var hspace := str(a.get("hspace", "0")).to_float()
	var vspace := str(a.get("vspace", "0")).to_float()
	var border := str(a.get("border", "2" if not str(s.link).is_empty() else "0")).to_int()
	ctx.add_item({"kind": "image", "w": w + hspace * 2 + border * 2, "asc": h + vspace * 2 + border * 2, "desc": 0.0,
		"tex": tex, "alt": alt, "link": s.link, "hspace": hspace + border, "vspace": vspace + border, "border": border,
		"border_color": _style_color(s)}, true)
	ctx.space = false


# --- tables --------------------------------------------------------------------

func _cells(table: Dictionary) -> Array:
	var rows: Array = []
	for tr: Dictionary in table.children:
		if tr.tag != "tr":
			continue
		var row: Array = []
		for td: Dictionary in tr.children:
			if td.tag in ["td", "th"]:
				row.append(td)
		rows.append({"tr": tr, "cells": row})
	return rows


## {min, max} widths of a cell's content.
func _measure(cell: Dictionary, s: Dictionary) -> Vector2:
	var lo := _Ctx.new(self, 0.0, 1.0)
	_blocks(cell, lo, s)
	lo.flush()
	var hi := _Ctx.new(self, 0.0, 100000.0)
	_blocks(cell, hi, s)
	hi.flush()
	return Vector2(lo.max_right, hi.max_right)


func _cell_style(td: Dictionary, row: Dictionary, s: Dictionary) -> Dictionary:
	var cs := s.duplicate()
	cs.pre = false
	cs.list_depth = 0
	if td.tag == "th":
		cs.bold = true
	if td.attrs.has("nowrap"):
		cs.nowrap = true
	return cs


func _table(n: Dictionary, ctx: _Ctx, s: Dictionary) -> void:
	var a: Dictionary = n.attrs
	ctx.flush()
	var border := str(a.get("border", "0")).to_int() if a.has("border") else 0
	if a.has("border") and str(a.border).is_empty():
		border = 1
	var pad := str(a.get("cellpadding", "1")).to_float()
	var spacing := str(a.get("cellspacing", "2")).to_float()
	var rows := _cells(n)
	if rows.is_empty():
		return
	# The columns, with colspans.
	var ncols := 0
	for row: Dictionary in rows:
		var c := 0
		for td: Dictionary in row.cells:
			c += maxi(1, str(td.attrs.get("colspan", "1")).to_int())
		ncols = maxi(ncols, c)
	var col_min: Array = []
	var col_max: Array = []
	var col_fixed: Array = []
	col_min.resize(ncols)
	col_max.resize(ncols)
	col_fixed.resize(ncols)
	col_min.fill(0.0)
	col_max.fill(0.0)
	col_fixed.fill(0.0)
	var spans: Array = []
	var extra := pad * 2 + (2.0 if border > 0 else 0.0)
	for row: Dictionary in rows:
		var c := 0
		for td: Dictionary in row.cells:
			var span := maxi(1, str(td.attrs.get("colspan", "1")).to_int())
			var m := _measure(td, _cell_style(td, row, s)) + Vector2(extra, extra)
			var wa := str(td.attrs.get("width", ""))
			if wa.is_valid_float() and not wa.ends_with("%") and span == 1:
				var fw := wa.to_float() + extra
				m = Vector2(maxf(m.x, fw), maxf(m.x, fw))
				col_fixed[c] = maxf(col_fixed[c], fw)
			if span == 1:
				col_min[c] = maxf(col_min[c], m.x)
				col_max[c] = maxf(col_max[c], m.y)
			else:
				spans.append([c, span, m])
			c += span
	for sp: Array in spans:
		var have_min := 0.0
		var have_max := 0.0
		for k in range(sp[0], mini(ncols, sp[0] + sp[1])):
			have_min += col_min[k]
			have_max += col_max[k]
		var m: Vector2 = sp[2]
		var gap: float = spacing * (sp[1] - 1)
		for k in range(sp[0], mini(ncols, sp[0] + sp[1])):
			if m.x > have_min + gap:
				col_min[k] += (m.x - have_min - gap) / sp[1]
			if m.y > have_max + gap:
				col_max[k] += (m.y - have_max - gap) / sp[1]
	for k in ncols:
		col_max[k] = maxf(col_max[k], col_min[k])
	var chrome := spacing * (ncols + 1) + border * 2
	var sum_min := 0.0
	var sum_max := 0.0
	for k in ncols:
		sum_min += col_min[k]
		sum_max += col_max[k]
	var avail := ctx.width
	var wa := str(a.get("width", ""))
	var target := -1.0
	if wa.ends_with("%"):
		target = avail * clampf(wa.to_float() / 100.0, 0.0, 1.0)
	elif wa.is_valid_float():
		target = wa.to_float()
	var total: float
	if target > 0:
		total = maxf(target, sum_min + chrome)
	else:
		total = clampf(sum_max + chrome, sum_min + chrome, maxf(avail, sum_min + chrome))
	var inner := total - chrome
	var widths: Array = []
	widths.resize(ncols)
	if inner >= sum_max:
		# Room to spare: columns without a fixed width share it.
		var flexible := 0.0
		for k in ncols:
			if col_fixed[k] <= 0:
				flexible += col_max[k]
		for k in ncols:
			widths[k] = col_max[k]
			if col_fixed[k] <= 0 and flexible > 0:
				widths[k] += (inner - sum_max) * col_max[k] / flexible
			elif flexible <= 0:
				widths[k] += (inner - sum_max) / ncols
	else:
		var span_range := maxf(sum_max - sum_min, 0.001)
		for k in ncols:
			widths[k] = col_min[k] + (col_max[k] - col_min[k]) * (inner - sum_min) / span_range
	var x0 := ctx.left
	var al := str(a.get("align", "")).to_lower()
	if al == "center" or (al.is_empty() and ctx.align == "center"):
		x0 += maxf(0.0, (ctx.width - total) / 2.0)
	elif al == "right":
		x0 += maxf(0.0, ctx.width - total)
	ctx._apply_margin()
	var top := ctx.y
	var table_bg := _color(str(a.get("bgcolor", "")), Color(0, 0, 0, 0))
	var body := _DisplayList.new()
	var y := top + border + spacing
	for row: Dictionary in rows:
		var tr: Dictionary = row.tr
		var row_bg := _color(str(tr.attrs.get("bgcolor", "")), Color(0, 0, 0, 0))
		var placed: Array = []
		var height := 0.0
		var c := 0
		var x := x0 + border + spacing
		for td: Dictionary in row.cells:
			var span := maxi(1, str(td.attrs.get("colspan", "1")).to_int())
			var w := 0.0
			for k in range(c, mini(ncols, c + span)):
				w += widths[k]
			w += spacing * (mini(ncols, c + span) - c - 1)
			var cs := _cell_style(td, row, s)
			var cell := _Ctx.new(self, pad + (1.0 if border > 0 else 0.0), w - extra)
			var calign := str(td.attrs.get("align", tr.attrs.get("align", "center" if td.tag == "th" else ""))).to_lower()
			cell.align = "center" if calign in ["center", "middle"] else ("right" if calign == "right" else "left")
			_blocks(td, cell, cs)
			cell.flush()
			var ch := cell.y + pad + (1.0 if border > 0 else 0.0)
			var hattr := str(td.attrs.get("height", ""))
			if hattr.is_valid_float():
				ch = maxf(ch, hattr.to_float())
			height = maxf(height, ch)
			placed.append([td, cell, x, w, ch])
			x += w + spacing
			c += span
		for pl: Array in placed:
			var td: Dictionary = pl[0]
			var cell: _Ctx = pl[1]
			var cx: float = pl[2]
			var cw: float = pl[3]
			var bg := _color(str(td.attrs.get("bgcolor", "")), row_bg if row_bg.a > 0 else table_bg)
			var rect := Rect2(cx, y, cw, height)
			if bg.a > 0:
				body.rects.append([rect, bg])
			if border > 0:
				body.frames.append([rect, Color(0.45, 0.45, 0.45), Color(0.92, 0.92, 0.92), 1.0])
			var valign := str(td.attrs.get("valign", row.tr.attrs.get("valign", "middle"))).to_lower()
			var dy := 0.0
			var content_h: float = pl[4]
			if valign == "middle" or valign == "center":
				dy = (height - content_h) / 2.0
			elif valign == "bottom":
				dy = height - content_h
			body.append(cell.dl, Vector2(cx, y + dy))
		y += height + spacing
	var total_h := y - top + border
	if table_bg.a > 0:
		ctx.dl.rects.append([Rect2(x0, top, total, total_h), table_bg])
	if border > 0:
		ctx.dl.frames.append([Rect2(x0, top, total, total_h), Color(0.92, 0.92, 0.92), Color(0.4, 0.4, 0.4), float(border)])
	ctx.dl.append(body, Vector2.ZERO)
	ctx.max_right = maxf(ctx.max_right, x0 + total)
	ctx.y = top + total_h
	ctx.gap(0.0)


# --- forms ---------------------------------------------------------------------

func _field(n: Dictionary, ctx: _Ctx, s: Dictionary) -> void:
	var a: Dictionary = n.attrs
	var type: String = str(a.get("type", "text")).to_lower() if n.tag == "input" else n.tag
	if type == "hidden":
		return
	var c: Control = _controls.get(n.id)
	if c == null:
		c = _make_control(n, type, s)
		if c == null:
			return
		_controls[n.id] = c
		add_child(c)
	var sz := field_size(c, type, a)
	var f := _font(s)
	var desc := f.get_descent(s.size)
	ctx.add_item({"kind": "field", "id": n.id, "w": sz.x + 4.0, "asc": sz.y - desc + 2.0, "desc": desc + 2.0}, true)


## How big a form control is on the page (fixed by its kind and text, so
## pages lay out the same everywhere).
static func field_size(c: Control, type: String, a: Dictionary) -> Vector2:
	var f := ThemeDB.fallback_font
	var tw := func(t: String) -> float: return f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, FIELD_FONT).x
	match type:
		"text", "password":
			return Vector2(maxi(1, str(a.get("size", "20")).to_int()) * 8.0 + 10.0, FIELD_HEIGHT)
		"checkbox", "radio":
			return Vector2(17, 17)
		"textarea":
			return Vector2(maxi(1, str(a.get("cols", "40")).to_int()) * 8.0 + 16.0, maxi(1, str(a.get("rows", "4")).to_int()) * 17.0 + 10.0)
		"select":
			var widest := 20.0
			var o := c as OptionButton
			for k in o.item_count:
				widest = maxf(widest, tw.call(o.get_item_text(k)))
			return Vector2(widest + 34.0, FIELD_HEIGHT)
	return Vector2(tw.call((c as Button).text) + 18.0, FIELD_HEIGHT)


func _make_control(n: Dictionary, type: String, s: Dictionary) -> Control:
	var a: Dictionary = n.attrs
	var c: Control
	match type:
		"text", "password":
			var e := LineEdit.new()
			e.text = str(a.get("value", ""))
			e.secret = type == "password"
			if a.has("maxlength"):
				e.max_length = str(a.maxlength).to_int()
			e.text_submitted.connect(func(_t: String) -> void: _submit(int(s.form), n))
			c = e
		"submit", "image", "button", "reset":
			var b := Button.new()
			var default_label: String = {"submit": "Submit Query", "image": "Submit", "reset": "Reset", "button": ""}[type]
			b.text = str(a.get("value", a.get("alt", default_label)))
			if type == "submit" or type == "image":
				b.pressed.connect(func() -> void: _submit(int(s.form), n))
			elif type == "reset":
				b.pressed.connect(func() -> void: _reset(int(s.form)))
			c = b
		"checkbox", "radio":
			var b := CheckBox.new()
			b.button_pressed = a.has("checked")
			if type == "radio":
				var key := "%d:%s" % [int(s.form), a.get("name", "")]
				if not _radio_groups.has(key):
					_radio_groups[key] = ButtonGroup.new()
					(_radio_groups[key] as ButtonGroup).allow_unpress = false
				b.button_group = _radio_groups[key]
			c = b
		"select":
			var o := OptionButton.new()
			for opt: Dictionary in _options(n):
				o.add_item(opt.text)
				o.set_item_metadata(o.item_count - 1, opt.value)
				if opt.selected:
					o.select(o.item_count - 1)
			c = o
		"textarea":
			var t := TextEdit.new()
			var text := ""
			for ch: Dictionary in n.children:
				if ch.tag == "#text":
					text += AgoraHtml.decode_entities(str(ch.text))
			t.text = text.trim_prefix("\n")
			c = t
		_:
			return null
	apply_classic(c)
	c.set_meta("field", {"node": n, "type": type, "form": s.form, "initial": _value_of(c, type)})
	return c


static func _options(select: Dictionary) -> Array:
	var out: Array = []
	for o: Dictionary in select.children:
		if o.tag != "option":
			continue
		var text := ""
		for ch: Dictionary in o.children:
			if ch.tag == "#text":
				text += str(ch.text)
		text = AgoraHtml.decode_entities(text).strip_edges()
		out.append({"text": text, "value": str(o.attrs.get("value", text)), "selected": o.attrs.has("selected")})
	return out


static func _value_of(c: Control, type: String) -> Variant:
	match type:
		"text", "password":
			return (c as LineEdit).text
		"checkbox", "radio":
			return (c as CheckBox).button_pressed
		"select":
			return (c as OptionButton).selected
		"textarea":
			return (c as TextEdit).text
	return null


func _place_controls() -> void:
	if not is_instance_valid(self):
		return
	var shown := {}
	for f: Array in _list.fields:
		var c: Control = _controls.get(f[1])
		if c:
			var r: Rect2 = f[0]
			c.position = r.position + Vector2(2, 2)
			c.size = r.size - Vector2(4, 4)
			c.visible = true
			shown[f[1]] = true
	for id: int in _controls:
		if not shown.has(id):
			(_controls[id] as Control).visible = false


## The name=value pairs of a form, as a browser sends them; [param button]
## is the submit button pressed (or the field Enter was pressed in).
func form_fields(form: int, button: Dictionary = {}) -> Array:
	var out: Array = []
	_collect_fields(_root, form, button, out, [-1])
	return out


func _collect_fields(node: Dictionary, form: int, button: Dictionary, out: Array, current: Array) -> void:
	for n: Dictionary in node.get("children", []):
		if n.tag == "form":
			var before: int = current[0]
			current[0] = int(n.index)
			_collect_fields(n, form, button, out, current)
			current[0] = before
			continue
		if n.tag in ["input", "select", "textarea"] and current[0] == form:
			var a: Dictionary = n.attrs
			var name := str(a.get("name", ""))
			var type: String = str(a.get("type", "text")).to_lower() if n.tag == "input" else n.tag
			if name.is_empty() and type != "image":
				continue
			var c: Control = _controls.get(n.id)
			match type:
				"hidden":
					out.append([name, str(a.get("value", ""))])
				"text", "password":
					out.append([name, (c as LineEdit).text if c else str(a.get("value", ""))])
				"checkbox", "radio":
					if c and (c as CheckBox).button_pressed:
						out.append([name, str(a.get("value", "on"))])
				"select":
					if c and (c as OptionButton).selected >= 0:
						out.append([name, str((c as OptionButton).get_item_metadata((c as OptionButton).selected))])
				"textarea":
					out.append([name, (c as TextEdit).text.replace("\n", "\r\n") if c else ""])
				"submit":
					if not button.is_empty() and button.id == n.id:
						out.append([name, str(a.get("value", "Submit Query"))])
				"image":
					if not button.is_empty() and button.id == n.id:
						var prefix := name + "." if not name.is_empty() else ""
						out.append([prefix + "x", "1"])
						out.append([prefix + "y", "1"])
		else:
			_collect_fields(n, form, button, out, current)


func _submit(form: int, button: Dictionary) -> void:
	if form < 0 or form >= _forms.size():
		return
	var f: Dictionary = _forms[form]
	var b := button if button.get("tag", "") == "input" and str(button.attrs.get("type", "")).to_lower() in ["submit", "image"] else {}
	var body := AgoraHttp.form_encode(form_fields(form, b))
	if f.method == "POST":
		form_submitted.emit(f.action, "POST", body)
	else:
		form_submitted.emit(str(f.action).get_slice("?", 0) + "?" + body, "GET", "")


## Submits the first form on the page (tests, Enter in a search box).
func submit_form(form: int = 0) -> void:
	_submit(form, {})


func _reset(form: int) -> void:
	for c: Control in _controls.values():
		var meta: Dictionary = c.get_meta("field")
		if meta.form != form:
			continue
		match meta.type:
			"text", "password": (c as LineEdit).text = meta.initial
			"checkbox", "radio": (c as CheckBox).button_pressed = meta.initial
			"select": (c as OptionButton).select(meta.initial)
			"textarea": (c as TextEdit).text = meta.initial


## The control of the [param k]-th field named [param name] (tests).
func field(name: String, k: int = 0) -> Control:
	var seen := 0
	var ids := _controls.keys()
	ids.sort()
	for id: int in ids:
		var c: Control = _controls[id]
		if str(c.get_meta("field").node.attrs.get("name", "")) == name:
			if seen == k:
				return c
			seen += 1
	return null


# --- what the page shows -------------------------------------------------------

## The page's words in reading order, one line per laid-out line (tests).
func visible_text() -> String:
	var rows := {}
	for t: Array in _list.texts:
		var y := int(round(t[0].y))
		if not rows.has(y):
			rows[y] = []
		rows[y].append([t[0].x, str(t[1])])
	var ys := rows.keys()
	ys.sort()
	var out: PackedStringArray = []
	for y: int in ys:
		var items: Array = rows[y]
		items.sort_custom(func(p: Array, q: Array) -> bool: return p[0] < q[0])
		var words: PackedStringArray = []
		for it: Array in items:
			words.append(it[1])
		out.append(" ".join(words))
	return "\n".join(out)


## Links on the page: [{url, rect}].
func links() -> Array:
	var out: Array = []
	for l: Array in _list.links:
		out.append({"url": l[1], "rect": l[0]})
	return out


## The link under [param pos], or "".
func link_at(pos: Vector2) -> String:
	for l: Array in _list.links:
		if (l[0] as Rect2).grow(1.0).has_point(pos):
			return l[1]
	return ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		relayout()


func _process(_delta: float) -> void:
	# Animated pictures move on.
	for i: Array in _list.images:
		if i[1] is AgoraGifTexture and (i[1] as AgoraGifTexture).is_playing():
			queue_redraw()
			return


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if _dragging:
			_sel_to = position_at(event.position)
			queue_redraw()
		var l := link_at(event.position)
		if l != _hover:
			_hover = l
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if not l.is_empty() else Control.CURSOR_IBEAM
			link_hovered.emit(l)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if is_inside_tree():
				grab_focus()
			if event.double_click:
				select_word_at(event.position)
				_dragging = false
				_press_link = ""
				return
			_press_pos = event.position
			_press_link = link_at(event.position)
			_dragging = true
			_sel_from = position_at(event.position)
			_sel_to = _sel_from
			queue_redraw()
		else:
			_dragging = false
			# A click (not a drag) on a link follows it.
			if event.position.distance_to(_press_pos) < 4.0:
				clear_selection()
				if not _press_link.is_empty() and link_at(event.position) == _press_link:
					accept_event()
					link_clicked.emit(_press_link)
			else:
				selection_changed.emit()
			_press_link = ""
	elif event is InputEventKey and event.pressed and (event.ctrl_pressed or event.meta_pressed):
		if event.keycode == KEY_C:
			copy()
			accept_event()
		elif event.keycode == KEY_A:
			select_all()
			accept_event()


# --- selecting and copying -----------------------------------------------------

## The box of text item [param k]: its words' rectangle on the page.
func _text_rect(k: int) -> Rect2:
	var t: Array = _list.texts[k]
	var f: Font = t[2]
	var w := f.get_string_size(t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, t[3]).x
	var asc := f.get_ascent(t[3])
	return Rect2(t[0].x, t[0].y - asc, w, asc + f.get_descent(t[3]))


func _char_x(k: int, offset: int) -> float:
	var t: Array = _list.texts[k]
	return t[0].x + (t[2] as Font).get_string_size(str(t[1]).left(offset), HORIZONTAL_ALIGNMENT_LEFT, -1, t[3]).x


## The text position nearest to [param point]: Vector2i(item, character).
func position_at(point: Vector2) -> Vector2i:
	var best := -1
	var best_score := INF
	for k in _list.texts.size():
		var r := _text_rect(k)
		var dy := 0.0 if point.y >= r.position.y and point.y <= r.end.y else minf(absf(point.y - r.position.y), absf(point.y - r.end.y))
		var dx := 0.0 if point.x >= r.position.x and point.x <= r.end.x else minf(absf(point.x - r.position.x), absf(point.x - r.end.x))
		var score := dy * 1000.0 + dx
		if score < best_score:
			best_score = score
			best = k
	if best < 0:
		return Vector2i(-1, -1)
	var text := str(_list.texts[best][1])
	var offset := text.length()
	for c in text.length():
		var mid := (_char_x(best, c) + _char_x(best, c + 1)) / 2.0
		if point.x < mid:
			offset = c
			break
	return Vector2i(best, offset)


func _ordered() -> Array:
	var a := _sel_from
	var b := _sel_to
	if b.x < a.x or (b.x == a.x and b.y < a.y):
		var t := a
		a = b
		b = t
	return [a, b]


func has_selection() -> bool:
	return _sel_from.x >= 0 and _sel_from != _sel_to


func clear_selection() -> void:
	if _sel_from.x >= 0:
		_sel_from = Vector2i(-1, -1)
		_sel_to = Vector2i(-1, -1)
		queue_redraw()
		selection_changed.emit()


func select_all() -> void:
	if _list.texts.is_empty():
		return
	_sel_from = Vector2i(0, 0)
	_sel_to = Vector2i(_list.texts.size() - 1, str(_list.texts[-1][1]).length())
	queue_redraw()
	selection_changed.emit()


func select_word_at(point: Vector2) -> void:
	var p := position_at(point)
	if p.x < 0:
		return
	_sel_from = Vector2i(p.x, 0)
	_sel_to = Vector2i(p.x, str(_list.texts[p.x][1]).length())
	queue_redraw()
	selection_changed.emit()


## The page's text from [param a] to [param b], with spaces between words
## and line breaks between lines, plus where each character came from.
func _flatten(a: Vector2i, b: Vector2i) -> Dictionary:
	var out := ""
	var map := PackedInt32Array() # per character: item * 65536 + offset
	var prev := -1
	for k in range(maxi(a.x, 0), mini(b.x + 1, _list.texts.size())):
		var t: Array = _list.texts[k]
		var text := str(t[1])
		var from := a.y if k == a.x else 0
		var to := b.y if k == b.x else text.length()
		if prev >= 0:
			var p: Array = _list.texts[prev]
			var sep := ""
			if absf(p[0].y - t[0].y) > 1.0:
				sep = "\n"
			elif t[0].x - (_char_x(prev, str(p[1]).length())) > 1.0:
				sep = " "
			out += sep
			for c in sep.length():
				map.append(k * 65536)
		for c in range(from, to):
			map.append(k * 65536 + c)
		out += text.substr(from, to - from)
		prev = k
	return {"text": out, "map": map}


func selected_text() -> String:
	if not has_selection():
		return ""
	var ab := _ordered()
	return _flatten(ab[0], ab[1]).text


## Puts the selection on the clipboard. Returns what was copied.
func copy() -> String:
	var text := selected_text()
	if not text.is_empty():
		DisplayServer.clipboard_set(text)
	return text


## Selects the next place [param what] appears after the selection (or
## from the top), ignoring case. Returns its y, or -1 if it isn't there.
func find_text(what: String) -> float:
	if what.is_empty() or _list.texts.is_empty():
		return -1.0
	var all := _flatten(Vector2i(0, 0), Vector2i(_list.texts.size() - 1, str(_list.texts[-1][1]).length()))
	var text: String = all.text
	var map: PackedInt32Array = all.map
	var start := 0
	if has_selection():
		var b: Vector2i = _ordered()[1]
		var key := b.x * 65536 + b.y
		for c in map.size():
			if map[c] >= key:
				start = c
				break
	var at := text.findn(what, start)
	if at < 0 and start > 0:
		at = text.findn(what, 0)
	if at < 0:
		return -1.0
	var first := map[at]
	var last := map[at + what.length() - 1]
	_sel_from = Vector2i(first / 65536, first % 65536)
	_sel_to = Vector2i(last / 65536, last % 65536 + 1)
	queue_redraw()
	selection_changed.emit()
	return _text_rect(_sel_from.x).position.y


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), background)
	for r: Array in _list.rects:
		draw_rect(r[0], r[1])
	for f: Array in _list.frames:
		var r: Rect2 = f[0]
		var w: float = f[3]
		draw_rect(Rect2(r.position, Vector2(r.size.x, w)), f[1])
		draw_rect(Rect2(r.position, Vector2(w, r.size.y)), f[1])
		draw_rect(Rect2(r.position + Vector2(0, r.size.y - w), Vector2(r.size.x, w)), f[2])
		draw_rect(Rect2(r.position + Vector2(r.size.x - w, 0), Vector2(w, r.size.y)), f[2])
	for i: Array in _list.images:
		var r: Rect2 = i[0]
		if i[1]:
			draw_texture_rect(i[1], r, false)
		else:
			# Not loaded (or broken): a framed box with the alt text.
			draw_rect(r, Color(0.5, 0.5, 0.5), false, 1.0)
			draw_rect(Rect2(r.position + Vector2(3, 3), Vector2(12, 12)), Color("#7a9a5a"))
			if not str(i[2]).is_empty():
				draw_string(ThemeDB.fallback_font, r.position + Vector2(18, 15), str(i[2]), HORIZONTAL_ALIGNMENT_LEFT, r.size.x - 20, 12, Color(0.2, 0.2, 0.2))
	var sel := _ordered() if has_selection() else []
	for k in _list.texts.size():
		var t: Array = _list.texts[k]
		draw_string(t[2], t[0], t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, t[3], t[4])
		if t[5]:
			var w: float = (t[2] as Font).get_string_size(t[1], HORIZONTAL_ALIGNMENT_LEFT, -1, t[3]).x
			draw_line(t[0] + Vector2(0, 2), t[0] + Vector2(w, 2), t[4], 1.0)
		if not sel.is_empty() and k >= sel[0].x and k <= sel[1].x:
			var text := str(t[1])
			var from: int = sel[0].y if k == sel[0].x else 0
			var to: int = sel[1].y if k == sel[1].x else text.length()
			if to <= from and k == sel[1].x:
				continue
			var r := _text_rect(k)
			var x0 := _char_x(k, from)
			var x1 := _char_x(k, to)
			# Fill the gap to the next selected word on the same line too.
			if k < sel[1].x and absf(_list.texts[k + 1][0].y - t[0].y) <= 1.0 and to == text.length():
				x1 = maxf(x1, _list.texts[k + 1][0].x)
			draw_rect(Rect2(x0, r.position.y, x1 - x0, r.size.y), SELECTION_BG)
			draw_string(t[2], Vector2(x0, t[0].y), text.substr(from, to - from), HORIZONTAL_ALIGNMENT_LEFT, -1, t[3], SELECTION_FG)
	for l: Array in _list.lines:
		draw_line(l[0], l[1], l[2], 1.0)
