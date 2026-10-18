#include "nc_video.h"

#include "nc_cartridge.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>

using namespace godot;

namespace {
// The console's 16 colors.
const uint8_t PALETTE[16][3] = {
	{ 0, 0, 0 }, { 255, 255, 255 }, { 128, 128, 136 }, { 56, 56, 64 },
	{ 200, 48, 48 }, { 255, 140, 56 }, { 255, 220, 72 }, { 64, 180, 80 },
	{ 24, 104, 56 }, { 80, 180, 255 }, { 40, 80, 200 }, { 140, 72, 200 },
	{ 255, 120, 180 }, { 140, 88, 48 }, { 240, 200, 160 }, { 80, 230, 200 },
};
} // namespace

NCVideo::NCVideo() {
	pixels.resize(WIDTH * HEIGHT * 4);
	image = Image::create_empty(WIDTH, HEIGHT, false, Image::FORMAT_RGBA8);
}

PackedColorArray NCVideo::palette() {
	PackedColorArray out;
	for (const auto &c : PALETTE) {
		out.push_back(Color::from_rgba8(c[0], c[1], c[2]));
	}
	return out;
}

// Uses the tile ROM of a newly inserted cartridge.
void NCVideo::load_tiles(const PackedByteArray &p_chr) {
	chr = p_chr;
	chr_bank = 0;
}

void NCVideo::fill(int x0, int y0, int w, int h, int color) {
	uint8_t *px = pixels.ptrw();
	const uint8_t *c = PALETTE[color & 15];
	for (int y = std::max(0, y0); y < std::min(HEIGHT, y0 + h); y++) {
		for (int x = std::max(0, x0); x < std::min(WIDTH, x0 + w); x++) {
			uint8_t *p = px + (y * WIDTH + x) * 4;
			p[0] = c[0];
			p[1] = c[1];
			p[2] = c[2];
			p[3] = 255;
		}
	}
}

// A tile at (x, y), clipped to the screen; color 0 is transparent.
void NCVideo::draw_tile(int tile, int x, int y, int flips) {
	const int64_t base = ((int64_t)(chr_bank << 8) + tile) * NCCartridge::TILE_BYTES;
	if (base + NCCartridge::TILE_BYTES > chr.size()) {
		return;
	}
	const uint8_t *src = chr.ptr() + base;
	uint8_t *px = pixels.ptrw();
	for (int row = 0; row < 8; row++) {
		const int dy = y + ((flips & 2) ? 7 - row : row);
		if (dy < 0 || dy >= HEIGHT) {
			continue;
		}
		for (int col = 0; col < 8; col++) {
			const uint8_t b = src[row * 4 + col / 2];
			const int color = (col % 2 == 0) ? (b >> 4) : (b & 15);
			if (color == 0) {
				continue;
			}
			const int dx = x + ((flips & 1) ? 7 - col : col);
			if (dx < 0 || dx >= WIDTH) {
				continue;
			}
			uint8_t *p = px + (dy * WIDTH + dx) * 4;
			p[0] = PALETTE[color][0];
			p[1] = PALETTE[color][1];
			p[2] = PALETTE[color][2];
			p[3] = 255;
		}
	}
}

void NCVideo::render(const uint8_t *mem, bool show_bg, bool show_sprites, int bg_color, int scroll_x, int scroll_y,
		int fixed_rows) {
	fill(0, 0, WIDTH, HEIGHT, bg_color);
	if (show_bg) {
		// The scrolling part: 21 x 16 tiles cover the screen at any offset.
		const int ox = scroll_x & 7;
		const int oy = scroll_y & 7;
		const int tx = scroll_x >> 3;
		const int ty = scroll_y >> 3;
		for (int r = 0; r <= ROWS; r++) {
			const int row_at = MAP + ((ty + r) & (MAP_SIZE - 1)) * MAP_SIZE;
			for (int c = 0; c <= COLS; c++) {
				draw_tile(mem[row_at + ((tx + c) & (MAP_SIZE - 1))], c * 8 - ox, r * 8 - oy, 0);
			}
		}
		// The fixed rows on top.
		const int fixed = std::min(fixed_rows, ROWS);
		if (fixed > 0) {
			fill(0, 0, WIDTH, fixed * 8, bg_color);
			for (int r = 0; r < fixed; r++) {
				for (int c = 0; c < COLS; c++) {
					draw_tile(mem[MAP + r * MAP_SIZE + c], c * 8, r * 8, 0);
				}
			}
		}
	}
	if (show_sprites) {
		for (int k = SPRITE_COUNT - 1; k >= 0; k--) {
			const int s = SPRITES + k * 4;
			const int sy = mem[s];
			if (sy >= HIDDEN_Y && sy < 248) {
				continue;
			}
			const int sx = mem[s + 1];
			draw_tile(mem[s + 2], sx >= 248 ? sx - 256 : sx, sy >= 248 ? sy - 256 : sy, mem[s + 3] & 3);
		}
	}
	image->set_data(WIDTH, HEIGHT, false, Image::FORMAT_RGBA8, pixels);
}

void NCVideo::render_from(const PackedByteArray &mem, bool show_bg, bool show_sprites, int bg_color, int scroll_x,
		int scroll_y, int fixed_rows) {
	if (mem.size() < 0x10000) {
		return;
	}
	render(mem.ptr(), show_bg, show_sprites, bg_color, scroll_x, scroll_y, fixed_rows);
}

void NCVideo::_bind_methods() {
	ClassDB::bind_static_method("NCVideo", D_METHOD("palette"), &NCVideo::palette);
	ClassDB::bind_method(D_METHOD("load_tiles", "chr"), &NCVideo::load_tiles);
	ClassDB::bind_method(D_METHOD("render", "mem", "show_bg", "show_sprites", "bg_color", "scroll_x", "scroll_y", "fixed_rows"),
			&NCVideo::render_from, DEFVAL(0), DEFVAL(0), DEFVAL(0));
	ClassDB::bind_method(D_METHOD("get_image"), &NCVideo::get_image);
	ClassDB::bind_method(D_METHOD("get_chr_bank"), &NCVideo::get_chr_bank);
	ClassDB::bind_method(D_METHOD("set_chr_bank", "bank"), &NCVideo::set_chr_bank);
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, "image", PROPERTY_HINT_RESOURCE_TYPE, "Image", PROPERTY_USAGE_NONE), "", "get_image");
	ADD_PROPERTY(PropertyInfo(Variant::INT, "chr_bank"), "set_chr_bank", "get_chr_bank");

	BIND_CONSTANT(WIDTH);
	BIND_CONSTANT(HEIGHT);
	BIND_CONSTANT(COLS);
	BIND_CONSTANT(ROWS);
	BIND_CONSTANT(MAP_SIZE);
	BIND_CONSTANT(MAP);
	BIND_CONSTANT(SPRITES);
	BIND_CONSTANT(SPRITE_COUNT);
	BIND_CONSTANT(HIDDEN_Y);
}
