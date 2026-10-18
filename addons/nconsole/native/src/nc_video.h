// The video chip: a 160x120 picture of 8x8 tiles from the cartridge's tile
// ROM, 16 fixed colors, a scrolling 32x32 background and 32 sprites.
//
// Video RAM:
//   $2000-$23FF  background map: one tile index per cell, 32 columns x
//                32 rows (256x256 pixels); the screen is a window into it
//                at (scroll x, scroll y), wrapping around the edges
//   $2400-$247F  sprites, 4 bytes each: y, x, tile, attributes
//                (bit 0 flip horizontally, bit 1 flip vertically).
//                A sprite with y >= 120 is hidden; x and y >= 248 count
//                as -8..-1, so sprites can slide in from the edges.
// The top fixed_rows rows of the screen don't scroll: they show map rows
// 0.. as they are, for a status bar. Sprites don't scroll. Color 0 of a
// tile is transparent: the background color shows through the background,
// the background through sprites. Sprite 0 is drawn on top of the others.

#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>

#include <cstdint>

namespace godot {

class NCVideo : public RefCounted {
	GDCLASS(NCVideo, RefCounted)

public:
	static constexpr int WIDTH = 160;
	static constexpr int HEIGHT = 120;
	static constexpr int COLS = 20;
	static constexpr int ROWS = 15;
	static constexpr int MAP_SIZE = 32;
	static constexpr int MAP = 0x2000;
	static constexpr int SPRITES = 0x2400;
	static constexpr int SPRITE_COUNT = 32;
	static constexpr int HIDDEN_Y = 120;

	NCVideo();

	static PackedColorArray palette();
	void load_tiles(const PackedByteArray &chr);
	// Draws the picture from 64 KB of memory.
	void render(const uint8_t *mem, bool show_bg, bool show_sprites, int bg_color, int scroll_x, int scroll_y, int fixed_rows);
	void render_from(const PackedByteArray &mem, bool show_bg, bool show_sprites, int bg_color,
			int scroll_x = 0, int scroll_y = 0, int fixed_rows = 0);

	Ref<Image> get_image() const { return image; }
	int get_chr_bank() const { return chr_bank; }
	void set_chr_bank(int bank) { chr_bank = bank; }

protected:
	static void _bind_methods();

private:
	Ref<Image> image;
	PackedByteArray pixels;
	PackedByteArray chr;
	int chr_bank = 0;

	void fill(int x0, int y0, int w, int h, int color);
	void draw_tile(int tile, int x, int y, int flips);
};

} // namespace godot
