class_name AgoraStyle
extends RefCounted
## Shared look for graphical programs: the bundled monospace font and file
## icons. Icons are drawn in code at first use, so the OS ships no image
## assets of its own.

const MONO := preload("fonts/DejaVuSansMono.ttf")
const MONO_BOLD := preload("fonts/DejaVuSansMono-Bold.ttf")

## Icon kinds understood by [method icon].
const KINDS: PackedStringArray = ["folder", "file", "text", "exec", "image", "link", "device", "up"]

static var _icons := {}


## Icon kind for a file, from its stat and MIME type.
static func kind_for(st: AgoraStat, mime: String) -> String:
	if st == null:
		return "file"
	if st.is_dir():
		return "folder"
	if st.is_device():
		return "device"
	if mime == "application/x-executable":
		return "exec"
	if mime.begins_with("image/"):
		return "image"
	if mime.begins_with("text/"):
		return "text"
	return "file"


## A square icon of [param kind] at [param px] pixels.
static func icon(kind: String, px: int = 48) -> Texture2D:
	var key := "%s@%d" % [kind, px]
	if not _icons.has(key):
		_icons[key] = ImageTexture.create_from_image(_draw_icon(kind, px))
	return _icons[key]


static func _draw_icon(kind: String, px: int) -> Image:
	var img := Image.create_empty(48, 48, false, Image.FORMAT_RGBA8)
	match kind:
		"folder":
			_box(img, Rect2i(4, 10, 18, 6), Color("#d9a441"), Color("#8a6420"))
			_box(img, Rect2i(4, 14, 40, 26), Color("#f0c05a"), Color("#8a6420"))
		"exec":
			_box(img, Rect2i(5, 8, 38, 32), Color("#1b1f24"), Color("#6b7785"))
			img.fill_rect(Rect2i(6, 9, 36, 5), Color("#3a5a80"))
			for i in 4: # a ">" prompt
				img.fill_rect(Rect2i(10 + i, 18 + i, 2, 2), Color("#5fd35f"))
				img.fill_rect(Rect2i(10 + i, 24 - i, 2, 2), Color("#5fd35f"))
			img.fill_rect(Rect2i(18, 25, 8, 2), Color("#5fd35f"))
		"device":
			_box(img, Rect2i(10, 10, 28, 28), Color("#4a4f57"), Color("#22252a"))
			for i in 5:
				img.fill_rect(Rect2i(13 + i * 5, 6, 2, 4), Color("#b0b5bd"))
				img.fill_rect(Rect2i(13 + i * 5, 38, 2, 4), Color("#b0b5bd"))
		"up":
			for i in 14:
				img.fill_rect(Rect2i(24 - i, 10 + i, i * 2 + 1, 1), Color("#d0d4da"))
			img.fill_rect(Rect2i(19, 24, 11, 14), Color("#d0d4da"))
		_:
			_page(img)
			match kind:
				"text":
					for i in 6:
						img.fill_rect(Rect2i(14, 16 + i * 4, 20 - (i % 3) * 4, 2), Color("#7a8494"))
				"image":
					img.fill_rect(Rect2i(13, 18, 22, 16), Color("#6aa7d8"))
					for i in 8:
						img.fill_rect(Rect2i(14 + i, 33 - i, 16 - i * 2, 1), Color("#4c9a4c"))
					img.fill_rect(Rect2i(28, 21, 4, 4), Color("#f5d76e"))
				"link":
					for i in 8:
						img.fill_rect(Rect2i(16, 30 - i, 2, 1), Color("#3b6fb6"))
						img.fill_rect(Rect2i(16 + i, 22, 1, 2), Color("#3b6fb6"))
					for i in 5:
						img.fill_rect(Rect2i(24 - i, 20 + i, 1, 1), Color("#3b6fb6"))
						img.fill_rect(Rect2i(24 - i, 24 - i, 1, 1), Color("#3b6fb6"))
	if px != 48:
		img.resize(px, px, Image.INTERPOLATE_BILINEAR)
	return img


static func _box(img: Image, r: Rect2i, fill: Color, outline: Color) -> void:
	img.fill_rect(r, outline)
	img.fill_rect(r.grow(-1), fill)


static func _page(img: Image) -> void:
	var outline := Color("#6b7380")
	_box(img, Rect2i(10, 4, 28, 40), Color("#f4f5f7"), outline)
	# Folded corner.
	for i in 8:
		img.fill_rect(Rect2i(30 + i, 4, 8 - i, 1), Color(0, 0, 0, 0))
		img.set_pixel(30 + i, 4 + i, outline)
	img.fill_rect(Rect2i(30, 4, 1, 9), outline)
	img.fill_rect(Rect2i(30, 12, 8, 1), outline)
