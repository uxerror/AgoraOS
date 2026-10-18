class_name AgoraGif
extends RefCounted
## A GIF decoder (GIF87a and GIF89a), since the engine reads no GIFs: LZW
## data, global and local color tables, interlaced images, transparency,
## and animations with per-frame delays, disposal methods and the
## NETSCAPE2.0 loop count.
##
## [method decode] returns {width, height, frames (Array of Image, each the
## whole picture as it looks then), delays (seconds), loops (-1: play
## once, 0: forever, n: repeat n times)} or {error}. [method texture]
## makes something to draw: an ImageTexture for a still picture, an
## [AgoraGifTexture] for an animated one.

## Browsers show frames with no (or a tiny) delay for a tenth of a second.
const MIN_DELAY := 0.1


static func is_gif(bytes: PackedByteArray) -> bool:
	return bytes.size() >= 6 and bytes.slice(0, 3).get_string_from_ascii() == "GIF"


static func texture(bytes: PackedByteArray) -> Texture2D:
	var g := decode(bytes)
	if g.has("error") or (g.frames as Array).is_empty():
		return null
	if (g.frames as Array).size() == 1:
		return ImageTexture.create_from_image(g.frames[0])
	return AgoraGifTexture.make(g.frames, g.delays, g.loops)


static func _u16(b: PackedByteArray, k: int) -> int:
	return b[k] | (b[k + 1] << 8)


static func decode(b: PackedByteArray) -> Dictionary:
	if not is_gif(b) or b.size() < 13:
		return {"error": "not a GIF"}
	var width := _u16(b, 6)
	var height := _u16(b, 8)
	if width <= 0 or height <= 0 or width > 4096 or height > 4096:
		return {"error": "bad size"}
	var packed := b[10]
	var k := 13
	var global := PackedByteArray()
	if packed & 0x80:
		var n := 3 * (1 << ((packed & 7) + 1))
		global = b.slice(k, k + n)
		k += n
	var canvas := PackedByteArray()
	canvas.resize(width * height * 4) # transparent black
	var frames: Array = []
	var delays := PackedFloat32Array()
	var loops := -1
	# The Graphic Control Extension applies to the next image.
	var delay := 0.0
	var transparent := -1
	var disposal := 0
	while k < b.size():
		var block := b[k]
		k += 1
		if block == 0x3B: # trailer
			break
		if block == 0x21: # extension
			if k >= b.size():
				break
			var label := b[k]
			k += 1
			if label == 0xF9 and k + 5 < b.size() and b[k] >= 4:
				var flags := b[k + 1]
				disposal = (flags >> 2) & 7
				delay = _u16(b, k + 2) / 100.0
				transparent = b[k + 4] if flags & 1 else -1
			elif label == 0xFF and k + 12 < b.size() and b.slice(k + 1, k + 12).get_string_from_ascii() == "NETSCAPE2.0":
				var sub := k + 12
				if sub + 3 < b.size() and b[sub] >= 3 and b[sub + 1] == 1:
					loops = _u16(b, sub + 2)
			k = _skip_blocks(b, k)
			continue
		if block != 0x2C or k + 9 > b.size():
			break
		# An image.
		var left := _u16(b, k)
		var top := _u16(b, k + 2)
		var w := _u16(b, k + 4)
		var h := _u16(b, k + 6)
		var ip := b[k + 8]
		k += 9
		var palette := global
		if ip & 0x80:
			var n := 3 * (1 << ((ip & 7) + 1))
			palette = b.slice(k, k + n)
			k += n
		if k >= b.size():
			break
		var min_size := b[k]
		k += 1
		var data := PackedByteArray()
		while k < b.size() and b[k] != 0:
			var len := b[k]
			data.append_array(b.slice(k + 1, k + 1 + len))
			k += 1 + len
		k += 1
		if min_size < 2 or min_size > 11 or w == 0 or h == 0:
			continue
		var pixels := _lzw(data, min_size, w * h)
		var rows := _row_order(h, ip & 0x40 != 0)
		var saved := canvas.duplicate() if disposal == 3 else PackedByteArray()
		for r in h:
			var y := top + rows[r]
			if y >= height:
				continue
			for x in w:
				var cx := left + x
				if cx >= width:
					break
				var index := pixels[r * w + x]
				if index == transparent or index * 3 + 2 >= palette.size():
					continue
				var o := (y * width + cx) * 4
				canvas[o] = palette[index * 3]
				canvas[o + 1] = palette[index * 3 + 1]
				canvas[o + 2] = palette[index * 3 + 2]
				canvas[o + 3] = 255
		frames.append(Image.create_from_data(width, height, false, Image.FORMAT_RGBA8, canvas))
		delays.append(maxf(delay, MIN_DELAY) if delay > 0.01 else MIN_DELAY)
		match disposal:
			2: # back to the background (transparent, as browsers do)
				for y in range(top, mini(height, top + h)):
					for x in range(left, mini(width, left + w)):
						var o := (y * width + x) * 4
						canvas[o] = 0
						canvas[o + 1] = 0
						canvas[o + 2] = 0
						canvas[o + 3] = 0
			3: # back to what was there before
				canvas = saved
		delay = 0.0
		transparent = -1
		disposal = 0
	if frames.is_empty():
		return {"error": "no image"}
	return {"width": width, "height": height, "frames": frames, "delays": delays, "loops": loops}


static func _skip_blocks(b: PackedByteArray, k: int) -> int:
	while k < b.size() and b[k] != 0:
		k += 1 + b[k]
	return k + 1


## Which picture row each stored row is.
static func _row_order(h: int, interlaced: bool) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not interlaced:
		for y in h:
			out.append(y)
		return out
	for pass_info in [[0, 8], [4, 8], [2, 4], [1, 2]]:
		var y: int = pass_info[0]
		while y < h:
			out.append(y)
			y += pass_info[1]
	return out


## Variable-length LZW, as GIF uses it: [param count] color indexes.
static func _lzw(data: PackedByteArray, min_size: int, count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(count)
	var clear := 1 << min_size
	var eoi := clear + 1
	var prefix := PackedInt32Array()
	prefix.resize(4096)
	var suffix := PackedByteArray()
	suffix.resize(4096)
	var first := PackedByteArray()
	first.resize(4096)
	for i in clear:
		suffix[i] = i
		first[i] = i
	var stack := PackedByteArray()
	stack.resize(4097)
	var code_size := min_size + 1
	var next := eoi + 1
	var prev := -1
	var buf := 0
	var bits := 0
	var k := 0
	var pos := 0
	while pos < count:
		while bits < code_size:
			if k >= data.size():
				return out
			buf |= data[k] << bits
			k += 1
			bits += 8
		var code := buf & ((1 << code_size) - 1)
		buf >>= code_size
		bits -= code_size
		if code == clear:
			code_size = min_size + 1
			next = eoi + 1
			prev = -1
			continue
		if code == eoi:
			break
		if prev == -1:
			if code < clear:
				out[pos] = code
				pos += 1
			prev = code
			continue
		var sp := 0
		var c := code
		if code >= next:
			# The code being defined: the previous string plus its first byte.
			stack[sp] = first[prev]
			sp += 1
			c = prev
		while c > eoi:
			stack[sp] = suffix[c]
			sp += 1
			c = prefix[c]
		stack[sp] = c
		sp += 1
		var j := sp - 1
		while j >= 0 and pos < count:
			out[pos] = stack[j]
			pos += 1
			j -= 1
		if next < 4096:
			prefix[next] = prev
			suffix[next] = c
			first[next] = first[prev]
			next += 1
			if next == (1 << code_size) and code_size < 12:
				code_size += 1
		prev = code
	return out
