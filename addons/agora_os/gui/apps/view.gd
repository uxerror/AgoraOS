extends AgoraGuiProgram
## Image viewer for PNG, JPEG and WebP files in the machine's file system.


func summary() -> String:
	return "image viewer"


func usage() -> String:
	return "usage: view image"


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail(usage(), 2)
	var path := p.argv[1]
	var data := p.read_bytes(path)
	if p.errno != AgoraErrno.OK:
		return p.fail_path(path)
	var img := Image.new()
	var loaded := false
	for loader in [img.load_png_from_buffer, img.load_jpg_from_buffer, img.load_webp_from_buffer]:
		if (loader as Callable).call(data) == OK:
			loaded = true
			break
	if not loaded:
		return p.fail("%s: not a PNG, JPEG or WebP image" % path)
	var bg := ColorRect.new()
	bg.color = Color("#111316")
	var tex := TextureRect.new()
	tex.texture = ImageTexture.create_from_image(img)
	tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tex.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tex.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.add_child(tex)
	var size := Vector2(img.get_size()).clamp(Vector2(200, 150), Vector2(900, 640))
	var win := open_window(p, bg, {"title": "%s (%dx%d) - view" % [AgoraPath.basename(path), img.get_width(), img.get_height()], "size": size})
	if win == null:
		return 1
	await win.closed
	return 0
