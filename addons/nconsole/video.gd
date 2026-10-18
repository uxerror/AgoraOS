class_name NCVideo
extends RefCounted
## The video chip: a 160x120 picture of 8x8 tiles from the cartridge's
## tile ROM, 16 fixed colors, a scrolling 32x32 background and 32 sprites.
##
## Video RAM:
##   $2000-$23FF  background map: one tile index per cell, 32 columns x
##                32 rows (256x256 pixels); the screen is a window into it
##                at (scroll x, scroll y), wrapping around the edges
##   $2400-$247F  sprites, 4 bytes each: y, x, tile, attributes
##                (bit 0 flip horizontally, bit 1 flip vertically).
##                A sprite with y >= 120 is hidden; x and y >= 248 count
##                as -8..-1, so sprites can slide in from the edges.
## The top [code]fixed_rows[/code] rows of the screen don't scroll: they
## show map rows 0.. as they are, for a status bar. Sprites don't scroll.
## Color 0 of a tile is transparent: the background color shows through
## the background, the background through sprites. Sprite 0 is drawn on
## top of the others.

const WIDTH := 160
const HEIGHT := 120
const COLS := 20
const ROWS := 15
const MAP_SIZE := 32
const MAP := 0x2000
const SPRITES := 0x2400
const SPRITE_COUNT := 32
const HIDDEN_Y := 120

## The console's 16 colors.
const PALETTE: PackedColorArray = [
	Color8(0, 0, 0), Color8(255, 255, 255), Color8(128, 128, 136), Color8(56, 56, 64),
	Color8(200, 48, 48), Color8(255, 140, 56), Color8(255, 220, 72), Color8(64, 180, 80),
	Color8(24, 104, 56), Color8(80, 180, 255), Color8(40, 80, 200), Color8(140, 72, 200),
	Color8(255, 120, 180), Color8(140, 88, 48), Color8(240, 200, 160), Color8(80, 230, 200),
]

var image := Image.create_empty(WIDTH, HEIGHT, false, Image.FORMAT_RGBA8)
## The tile set (256 tiles of the cartridge's tile ROM) in use.
var chr_bank := 0
## Tile images by ((bank * 256 + tile) * 4 + flips), made when first needed.
var _tiles := {}
var _blank := {}
var _chr := PackedByteArray()


## Uses the tile ROM of a newly inserted cartridge.
func load_tiles(chr: PackedByteArray) -> void:
	_chr = chr
	_tiles.clear()
	_blank.clear()
	chr_bank = 0


func _tile(index: int, flips: int) -> Image:
	var key := ((chr_bank << 8) + index) * 4 + flips
	if _tiles.has(key):
		return _tiles[key]
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	var base := ((chr_bank << 8) + index) * NCCartridge.TILE_BYTES
	for row in 8:
		for px in 8:
			var at := base + row * 4 + px / 2
			var b := _chr[at] if at < _chr.size() else 0
			var color := (b >> 4) if px % 2 == 0 else (b & 15)
			if color == 0:
				continue
			var dx := 7 - px if flips & 1 else px
			var dy := 7 - row if flips & 2 else row
			img.set_pixel(dx, dy, PALETTE[color])
	_tiles[key] = img
	return img


## True if a tile has no pixels, so drawing it can be skipped.
func _is_blank(index: int) -> bool:
	var key := (chr_bank << 8) + index
	if not _blank.has(key):
		var base := key * NCCartridge.TILE_BYTES
		var empty := true
		for k in NCCartridge.TILE_BYTES:
			if base + k < _chr.size() and _chr[base + k] != 0:
				empty = false
				break
		_blank[key] = empty
	return _blank[key]


## Draws the picture from video RAM in [param mem].
func render(mem: PackedByteArray, show_bg: bool, show_sprites: bool, bg_color: int,
		scroll_x: int = 0, scroll_y: int = 0, fixed_rows: int = 0) -> void:
	var back := PALETTE[bg_color & 15]
	image.fill(back)
	var rect := Rect2i(0, 0, 8, 8)
	if show_bg:
		# The scrolling part: 21 x 16 tiles cover the screen at any offset.
		var ox := scroll_x & 7
		var oy := scroll_y & 7
		var tx := scroll_x >> 3
		var ty := scroll_y >> 3
		for r in ROWS + 1:
			var row_at := MAP + ((ty + r) & (MAP_SIZE - 1)) * MAP_SIZE
			for c in COLS + 1:
				var t := mem[row_at + ((tx + c) & (MAP_SIZE - 1))]
				if not _is_blank(t):
					image.blend_rect(_tile(t, 0), rect, Vector2i(c * 8 - ox, r * 8 - oy))
		# The fixed rows on top.
		var fixed := mini(fixed_rows, ROWS)
		if fixed > 0:
			image.fill_rect(Rect2i(0, 0, WIDTH, fixed * 8), back)
			for r in fixed:
				for c in COLS:
					var t := mem[MAP + r * MAP_SIZE + c]
					if not _is_blank(t):
						image.blend_rect(_tile(t, 0), rect, Vector2i(c * 8, r * 8))
	if show_sprites:
		for k in range(SPRITE_COUNT - 1, -1, -1):
			var s := SPRITES + k * 4
			var sy := mem[s]
			if sy >= HIDDEN_Y and sy < 248:
				continue
			var sx := mem[s + 1]
			image.blend_rect(_tile(mem[s + 2], mem[s + 3] & 3), rect,
				Vector2i(sx - 256 if sx >= 248 else sx, sy - 256 if sy >= 248 else sy))
