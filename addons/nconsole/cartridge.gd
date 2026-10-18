class_name NCCartridge
extends RefCounted
## A game cartridge: program ROM in 16 KB banks and tile ROM in 8 KB banks
## (256 tiles of 8x8 pixels, 4 bits a pixel, seen only by the video chip).
##
## The CPU sees one program bank at $8000-$BFFF, chosen with the PRGBANK
## register (bank 0 after reset), and the last bank always at $C000-$FFFF,
## where the vectors are. The smallest cartridge has 2 program banks
## (32 KB) and 1 tile bank.
##
## The .nc8 file: a 32-byte header ("NC8" $1A, version, program banks,
## tile banks, a reserved byte, a 24-byte title padded with zeros), then
## the program ROM, then the tile ROM. Version 1 files (before banks) are
## 32 KB + 8 KB.

const MAGIC := "NC8\u001a"
const VERSION := 2
const HEADER := 32
const BANK_SIZE := 0x4000
const CHR_BANK_SIZE := 0x2000
## The smallest program ROM: two banks, $8000-$FFFF.
const PRG_SIZE := 0x8000
const CHR_SIZE := 0x2000
const TILE_BYTES := 32
const MAX_PRG_BANKS := 32
const MAX_CHR_BANKS := 16

var title := ""
var prg := PackedByteArray()
var chr := PackedByteArray()
## Label and constant values from the assembler, for debuggers and tests.
var symbols := {}
## Only the labels (addresses), for disassembly.
var labels := {}
## The bank of labels in the switchable window ($8000-$BFFF).
var label_banks := {}

var prg_banks: int:
	get:
		return prg.size() / BANK_SIZE

var chr_banks: int:
	get:
		return chr.size() / CHR_BANK_SIZE


func _init(banks: int = 2, tile_banks: int = 1) -> void:
	prg.resize(banks * BANK_SIZE)
	chr.resize(tile_banks * CHR_BANK_SIZE)


## Bytes of program bank [param n].
func bank(n: int) -> PackedByteArray:
	n = posmod(n, prg_banks)
	return prg.slice(n * BANK_SIZE, (n + 1) * BANK_SIZE)


func to_bytes() -> PackedByteArray:
	var out := MAGIC.to_ascii_buffer()
	out.append_array([VERSION, prg_banks, chr_banks, 0])
	var t := title.to_ascii_buffer().slice(0, 24)
	t.resize(24)
	out.append_array(t)
	out.append_array(prg)
	out.append_array(chr)
	return out


## Reads a cartridge image. Returns null if it isn't one.
static func from_bytes(data: PackedByteArray) -> NCCartridge:
	if data.size() < HEADER or data.slice(0, 4).get_string_from_ascii() != MAGIC:
		return null
	var banks := 2
	var tiles := 1
	match data[4]:
		1: pass
		2:
			banks = data[5]
			tiles = data[6]
		_: return null
	if banks < 2 or banks > MAX_PRG_BANKS or tiles < 1 or tiles > MAX_CHR_BANKS:
		return null
	var prg_end := HEADER + banks * BANK_SIZE
	if data.size() != prg_end + tiles * CHR_BANK_SIZE:
		return null
	var c := NCCartridge.new(banks, tiles)
	c.title = data.slice(8, 32).get_string_from_ascii()
	c.prg = data.slice(HEADER, prg_end)
	c.chr = data.slice(prg_end)
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
