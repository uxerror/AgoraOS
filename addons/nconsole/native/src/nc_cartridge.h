// A game cartridge: program ROM in 16 KB banks and tile ROM in 8 KB banks
// (256 tiles of 8x8 pixels, 4 bits a pixel, seen only by the video chip).
//
// The CPU sees one program bank at $8000-$BFFF, chosen with the PRGBANK
// register (bank 0 after reset), and the last bank always at $C000-$FFFF,
// where the vectors are. The smallest cartridge has 2 program banks
// (32 KB) and 1 tile bank.
//
// The .nc8 file: a 32-byte header ("NC8" $1A, version, program banks,
// tile banks, a reserved byte, a 24-byte title padded with zeros), then
// the program ROM, then the tile ROM. Version 1 files (before banks) are
// 32 KB + 8 KB.

#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/string.hpp>

namespace godot {

class NCCartridge : public RefCounted {
	GDCLASS(NCCartridge, RefCounted)

public:
	static constexpr int VERSION = 2;
	static constexpr int HEADER = 32;
	static constexpr int BANK_SIZE = 0x4000;
	static constexpr int CHR_BANK_SIZE = 0x2000;
	static constexpr int PRG_SIZE = 0x8000; // the smallest program ROM
	static constexpr int CHR_SIZE = 0x2000;
	static constexpr int TILE_BYTES = 32;
	static constexpr int MAX_PRG_BANKS = 32;
	static constexpr int MAX_CHR_BANKS = 16;

	NCCartridge();

	void resize_banks(int prg_banks, int chr_banks);
	int get_prg_banks() const { return prg.size() / BANK_SIZE; }
	int get_chr_banks() const { return chr.size() / CHR_BANK_SIZE; }
	PackedByteArray bank(int n) const;
	PackedByteArray to_bytes() const;
	static Ref<NCCartridge> from_bytes(const PackedByteArray &data);
	Error save(const String &path) const;
	static Ref<NCCartridge> load_file(const String &path);

	String title;
	PackedByteArray prg;
	PackedByteArray chr;
	Dictionary symbols; // labels and constants from the assembler
	Dictionary labels; // only the labels (addresses), for disassembly
	Dictionary label_banks; // the bank of labels in the window at $8000

#define NC_ACCESSORS(ctype, name) \
	ctype _get_##name() const { return name; } \
	void _set_##name(ctype value) { name = value; }
	NC_ACCESSORS(String, title)
	NC_ACCESSORS(PackedByteArray, prg)
	NC_ACCESSORS(PackedByteArray, chr)
	NC_ACCESSORS(Dictionary, symbols)
	NC_ACCESSORS(Dictionary, labels)
	NC_ACCESSORS(Dictionary, label_banks)
#undef NC_ACCESSORS

protected:
	static void _bind_methods();
};

} // namespace godot
