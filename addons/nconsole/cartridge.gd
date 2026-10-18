class_name NCCartridge
extends RefCounted
## A game cartridge: 32 KB of program ROM, seen by the CPU at $8000, and
## 8 KB of tile ROM (256 tiles of 8x8 pixels, 4 bits a pixel), seen only
## by the video chip.
##
## The .nc8 file: a 32-byte header ("NC8" $1A, version, flags, two
## reserved bytes, a 24-byte title padded with zeros), then the program
## ROM, then the tile ROM.

const MAGIC := "NC8\u001a"
const VERSION := 1
const HEADER := 32
const PRG_SIZE := 0x8000
const CHR_SIZE := 0x2000
const TILE_BYTES := 32

var title := ""
var prg := PackedByteArray()
var chr := PackedByteArray()
## Label and constant values from the assembler, for debuggers and tests.
var symbols := {}


func _init() -> void:
	prg.resize(PRG_SIZE)
	chr.resize(CHR_SIZE)


func to_bytes() -> PackedByteArray:
	var out := MAGIC.to_ascii_buffer()
	out.append_array([VERSION, 0, 0, 0])
	var t := title.to_ascii_buffer().slice(0, 24)
	t.resize(24)
	out.append_array(t)
	out.append_array(prg)
	out.append_array(chr)
	return out


## Reads a cartridge image. Returns null if it isn't one.
static func from_bytes(data: PackedByteArray) -> NCCartridge:
	if data.size() != HEADER + PRG_SIZE + CHR_SIZE or data.slice(0, 4).get_string_from_ascii() != MAGIC or data[4] != VERSION:
		return null
	var c := NCCartridge.new()
	c.title = data.slice(8, 32).get_string_from_ascii()
	c.prg = data.slice(HEADER, HEADER + PRG_SIZE)
	c.chr = data.slice(HEADER + PRG_SIZE)
	return c


func save(path: String) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_buffer(to_bytes())
	return OK


## Loads a .nc8 file, or assembles an .asm source. Returns null and
## prints the errors if that fails.
static func load_file(path: String) -> NCCartridge:
	if path.get_extension().to_lower() == "asm":
		var asm := NCAssembler.new()
		var cart := asm.assemble_file(path)
		for e in asm.errors:
			push_error(e)
		return cart
	return from_bytes(FileAccess.get_file_as_bytes(path))
