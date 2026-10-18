class_name NCVideo
extends RefCounted
## The video chip: a 160x120 picture of 8x8 tiles from the cartridge's
## tile ROM, 16 fixed colors, a 20x15 background and 32 sprites.
##
## Video RAM:
##   $2000-$212B  background: one tile index per cell, 20 columns x 15 rows
##   $2200-$227F  sprites, 4 bytes each: y, x, tile, attributes
##                (bit 0 flip horizontally, bit 1 flip vertically).
##                A sprite with y >= 120 is hidden; x and y >= 248 count
##                as -8..-1, so sprites can slide in from the edges.
## Color 0 of a tile is transparent: the background color shows through
## the background, the background through sprites. Sprite 0 is drawn on
## top of the others.

const WIDTH := 160
const HEIGHT := 120
const COLS := 20
const ROWS := 15
const MAP := 0x2000
const SPRITES := 0x2200
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
## Tile images by tile * 4 + flips, made when first needed.
var _tiles := {}
var _chr := PackedByteArray()


## Uses the tile ROM of a newly inserted cartridge.
func load_tiles(chr: PackedByteArray) -> void:
	_chr = chr
	_tiles.clear()
	_blank.clear()


func _tile(index: int, flips: int) -> Image:
	var key := index * 4 + flips
	if _tiles.has(key):
		return _tiles[key]
	var img := Image.create_empty(8, 8, false, Image.FORMAT_RGBA8)
	var base := index * NCCartridge.TILE_BYTES
	for row in 8:
		for px in 8:
			var b := _chr[base + row * 4 + px / 2] if base + row * 4 + px / 2 < _chr.size() else 0
			var color := (b >> 4) if px % 2 == 0 else (b & 15)
			if color == 0:
				continue
			var dx := 7 - px if flips & 1 else px
			var dy := 7 - row if flips & 2 else row
			img.set_pixel(dx, dy, PALETTE[color])
	_tiles[key] = img
	return img


## Draws the picture from video RAM in [param mem].
func render(mem: PackedByteArray, show_bg: bool, show_sprites: bool, bg_color: int) -> void:
	image.fill(PALETTE[bg_color & 15])
	var rect := Rect2i(0, 0, 8, 8)
	if show_bg:
		var at := MAP
		for row in ROWS:
			for col in COLS:
				var t := mem[at]
				at += 1
				if not _is_blank(t):
					image.blend_rect(_tile(t, 0), rect, Vector2i(col * 8, row * 8))
	if show_sprites:
		for k in range(SPRITE_COUNT - 1, -1, -1):
			var s := SPRITES + k * 4
			var sy := mem[s]
			if sy >= HIDDEN_Y and sy < 248:
				continue
			var sx := mem[s + 1]
			image.blend_rect(_tile(mem[s + 2], mem[s + 3] & 3), rect,
				Vector2i(sx - 256 if sx >= 248 else sx, sy - 256 if sy >= 248 else sy))


var _blank := {}


## True if a tile has no pixels, so drawing it can be skipped.
func _is_blank(index: int) -> bool:
	if not _blank.has(index):
		var base := index * NCCartridge.TILE_BYTES
		var empty := true
		for k in NCCartridge.TILE_BYTES:
			if base + k < _chr.size() and _chr[base + k] != 0:
				empty = false
				break
		_blank[index] = empty
	return _blank[index]
