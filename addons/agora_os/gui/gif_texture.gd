class_name AgoraGifTexture
extends Texture2D
## An animated picture (from [AgoraGif]): a texture whose frame follows the
## clock, so it plays wherever it is drawn. Whoever draws it should redraw
## while [method is_playing] is true.

var frames: Array[ImageTexture] = []
var delays := PackedFloat32Array()
## -1: play once, 0: forever, n: n more times after the first.
var loops := 0
var _total := 0.0
var _start_ms := 0


static func make(images: Array, frame_delays: PackedFloat32Array, loop_count: int) -> AgoraGifTexture:
	var t := AgoraGifTexture.new()
	for img: Image in images:
		t.frames.append(ImageTexture.create_from_image(img))
	t.delays = frame_delays
	t.loops = loop_count
	for d in frame_delays:
		t._total += d
	t._start_ms = Time.get_ticks_msec()
	return t


## Starts over from the first frame.
func restart() -> void:
	_start_ms = Time.get_ticks_msec()


func is_playing() -> bool:
	if frames.size() < 2 or _total <= 0.0:
		return false
	if loops == 0:
		return true
	return _elapsed() < _total * (1 + maxi(loops, 0))


func _elapsed() -> float:
	return (Time.get_ticks_msec() - _start_ms) / 1000.0


## The frame showing now.
func frame_index() -> int:
	return frame_at(_elapsed())


## The frame showing [param t] seconds after the start.
func frame_at(t: float) -> int:
	if frames.size() < 2 or _total <= 0.0:
		return 0
	if loops != 0 and t >= _total * (1 + maxi(loops, 0)):
		return frames.size() - 1
	t = fmod(t, _total)
	for k in delays.size():
		if t < delays[k]:
			return k
		t -= delays[k]
	return frames.size() - 1


func current() -> Texture2D:
	return frames[frame_index()] if not frames.is_empty() else null


func _get_width() -> int:
	return frames[0].get_width() if not frames.is_empty() else 0


func _get_height() -> int:
	return frames[0].get_height() if not frames.is_empty() else 0


func _has_alpha() -> bool:
	return true


func _is_pixel_opaque(x: int, y: int) -> bool:
	var img := current().get_image() if current() else null
	return img != null and img.get_pixel(x, y).a > 0.5


func _draw(to_canvas_item: RID, pos: Vector2, modulate: Color, transpose: bool) -> void:
	if current():
		current().draw(to_canvas_item, pos, modulate, transpose)


func _draw_rect(to_canvas_item: RID, rect: Rect2, tile: bool, modulate: Color, transpose: bool) -> void:
	if current():
		current().draw_rect(to_canvas_item, rect, tile, modulate, transpose)


func _draw_rect_region(to_canvas_item: RID, rect: Rect2, src_rect: Rect2, modulate: Color, transpose: bool, clip_uv: bool) -> void:
	if current():
		current().draw_rect_region(to_canvas_item, rect, src_rect, modulate, transpose, clip_uv)
