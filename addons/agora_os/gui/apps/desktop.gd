extends AgoraGuiProgram
## Draws the desktop background on the bottom layer. Configured with
## "background=#rrggbb" in ~/.config/desktop.conf or /etc/desktop.conf.


class Backdrop extends Control:
	var color := Color("#1d2b38")
	var caption := ""

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), color)
		var font := get_theme_default_font()
		var text_size := font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
		draw_string(font, Vector2(size.x - text_size.x - 12, 12 + text_size.y), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1, 1, 1, 0.35))


func summary() -> String:
	return "desktop background"


func main(p: AgoraProcess) -> int:
	var d := display_for(p)
	var backdrop := Backdrop.new()
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	backdrop.color = Color.from_string(conf_value(p, [p.home() + "/.config/desktop.conf", "/etc/desktop.conf"], "background"), backdrop.color)
	backdrop.caption = "%s %s  -  %s" % [AgoraMachine.KERNEL_NAME, AgoraMachine.KERNEL_VERSION, p.machine.hostname]
	var win := open_window(p, backdrop, {
		"layer": AgoraWindow.Layer.DESKTOP, "decorated": false, "focus": false,
		"position": Vector2.ZERO, "size": d.size if d else Vector2.ZERO,
	})
	if win == null:
		return 1
	d.resized.connect(_fit.bind(win))
	await win.closed
	return 0


func _fit(win: AgoraWindow) -> void:
	if win.open:
		win.set_rect(Rect2(Vector2.ZERO, win.display.size))
