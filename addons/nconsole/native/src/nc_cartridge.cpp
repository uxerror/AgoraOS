#include "nc_cartridge.h"

#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/core/class_db.hpp>

using namespace godot;

namespace {
const char MAGIC[4] = { 'N', 'C', '8', 0x1A };
}

NCCartridge::NCCartridge() {
	resize_banks(2, 1);
}

// Sets the sizes; what fits stays.
void NCCartridge::resize_banks(int prg_banks, int chr_banks) {
	prg.resize(prg_banks * BANK_SIZE);
	chr.resize(chr_banks * CHR_BANK_SIZE);
}

PackedByteArray NCCartridge::bank(int n) const {
	const int banks = get_prg_banks();
	if (banks == 0) {
		return PackedByteArray();
	}
	n = ((n % banks) + banks) % banks;
	return prg.slice(n * BANK_SIZE, (n + 1) * BANK_SIZE);
}

PackedByteArray NCCartridge::to_bytes() const {
	PackedByteArray out;
	for (char c : MAGIC) {
		out.push_back((uint8_t)c);
	}
	out.push_back(VERSION);
	out.push_back(get_prg_banks());
	out.push_back(get_chr_banks());
	out.push_back(0);
	PackedByteArray name = title.to_ascii_buffer().slice(0, 24);
	name.resize(24);
	out.append_array(name);
	out.append_array(prg);
	out.append_array(chr);
	return out;
}

// Reads a cartridge image. Returns null if it isn't one.
Ref<NCCartridge> NCCartridge::from_bytes(const PackedByteArray &data) {
	if (data.size() < HEADER) {
		return Ref<NCCartridge>();
	}
	for (int k = 0; k < 4; k++) {
		if (data[k] != (uint8_t)MAGIC[k]) {
			return Ref<NCCartridge>();
		}
	}
	int banks = 2;
	int tiles = 1;
	if (data[4] == 2) {
		banks = data[5];
		tiles = data[6];
	} else if (data[4] != 1) {
		return Ref<NCCartridge>();
	}
	if (banks < 2 || banks > MAX_PRG_BANKS || tiles < 1 || tiles > MAX_CHR_BANKS) {
		return Ref<NCCartridge>();
	}
	const int64_t prg_end = HEADER + (int64_t)banks * BANK_SIZE;
	if (data.size() != prg_end + (int64_t)tiles * CHR_BANK_SIZE) {
		return Ref<NCCartridge>();
	}
	Ref<NCCartridge> c;
	c.instantiate();
	c->title = data.slice(8, 32).get_string_from_ascii();
	c->prg = data.slice(HEADER, prg_end);
	c->chr = data.slice(prg_end);
	return c;
}

Error NCCartridge::save(const String &path) const {
	Ref<FileAccess> f = FileAccess::open(path, FileAccess::WRITE);
	if (f.is_null()) {
		return FileAccess::get_open_error();
	}
	f->store_buffer(to_bytes());
	return OK;
}

// Loads an .nc8 file; null if it can't be read or isn't one.
Ref<NCCartridge> NCCartridge::load_file(const String &path) {
	return from_bytes(FileAccess::get_file_as_bytes(path));
}

void NCCartridge::_bind_methods() {
	ClassDB::bind_method(D_METHOD("resize_banks", "prg_banks", "chr_banks"), &NCCartridge::resize_banks);
	ClassDB::bind_method(D_METHOD("get_prg_banks"), &NCCartridge::get_prg_banks);
	ClassDB::bind_method(D_METHOD("get_chr_banks"), &NCCartridge::get_chr_banks);
	ClassDB::bind_method(D_METHOD("bank", "n"), &NCCartridge::bank);
	ClassDB::bind_method(D_METHOD("to_bytes"), &NCCartridge::to_bytes);
	ClassDB::bind_static_method("NCCartridge", D_METHOD("from_bytes", "data"), &NCCartridge::from_bytes);
	ClassDB::bind_method(D_METHOD("save", "path"), &NCCartridge::save);
	ClassDB::bind_static_method("NCCartridge", D_METHOD("load_file", "path"), &NCCartridge::load_file);
	ADD_PROPERTY(PropertyInfo(Variant::INT, "prg_banks", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "get_prg_banks");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "chr_banks", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "", "get_chr_banks");

#define NC_PROPERTY(type, name)                                                            \
	ClassDB::bind_method(D_METHOD("_get_" #name), &NCCartridge::_get_##name);              \
	ClassDB::bind_method(D_METHOD("_set_" #name, "value"), &NCCartridge::_set_##name);   \
	ADD_PROPERTY(PropertyInfo(Variant::type, #name), "_set_" #name, "_get_" #name);
	NC_PROPERTY(STRING, title)
	NC_PROPERTY(PACKED_BYTE_ARRAY, prg)
	NC_PROPERTY(PACKED_BYTE_ARRAY, chr)
	NC_PROPERTY(DICTIONARY, symbols)
	NC_PROPERTY(DICTIONARY, labels)
	NC_PROPERTY(DICTIONARY, label_banks)
#undef NC_PROPERTY

	BIND_CONSTANT(VERSION);
	BIND_CONSTANT(HEADER);
	BIND_CONSTANT(BANK_SIZE);
	BIND_CONSTANT(CHR_BANK_SIZE);
	BIND_CONSTANT(PRG_SIZE);
	BIND_CONSTANT(CHR_SIZE);
	BIND_CONSTANT(TILE_BYTES);
	BIND_CONSTANT(MAX_PRG_BANKS);
	BIND_CONSTANT(MAX_CHR_BANKS);
}
