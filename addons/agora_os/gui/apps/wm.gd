extends AgoraGuiProgram
## The window manager. It registers with the display server and builds the
## frame of every window. Kill it and windows lose their decorations; start
## another one and they get new ones.


class Manager:
	var theme: AgoraWmTheme
	# Weak: the display holds the manager, so a strong ref back would leak.
	var _display_ref: WeakRef
	var display: AgoraDisplay:
		get:
			return _display_ref.get_ref() as AgoraDisplay

	func decorate(win: AgoraWindow) -> Control:
		return AgoraWmFrame.new(win, theme)

	func handle_key(event: InputEventKey) -> bool:
		if event.alt_pressed and event.keycode == KEY_F4:
			if display.focused and display.focused.layer == AgoraWindow.Layer.NORMAL:
				display.focused.request_close()
			return true
		if event.alt_pressed and event.keycode == KEY_TAB:
			# Bring the bottom-most normal window to the top: repeated
			# presses cycle through all of them.
			for w in display.windows:
				if w.layer == AgoraWindow.Layer.NORMAL and w != display.focused:
					display.focus_window(w)
					break
			return true
		return false


func summary() -> String:
	return "window manager"


func main(p: AgoraProcess) -> int:
	var d := display_for(p)
	if d == null:
		return p.fail("cannot open display")
	if d.manager != null:
		return p.fail("another window manager is already running")
	var m := Manager.new()
	m.theme = AgoraWmTheme.load_for(p)
	m._display_ref = weakref(d)
	d.set_manager(m)
	await p.exited
	d.clear_manager(m)
	return 0
