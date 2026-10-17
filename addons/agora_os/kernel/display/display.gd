class_name AgoraDisplay
extends RefCounted
## The display server of a machine, in the spirit of X11. It belongs to the
## hardware (the monitor connector) and is bound to whichever kernel runs.
##
## Programs open windows here and own them: when a process exits, its
## windows close. The look and behavior of windows is not decided here. A
## window manager program registers itself with [method set_manager] and
## builds the frame (title bar, borders) for every window. Panels and the
## desktop are ordinary programs that open windows on special layers.
##
## The display has no nodes of its own. An [AgoraDisplayView] in the scene
## tree shows it and feeds it the screen size.

signal window_opened(win: AgoraWindow)
signal window_closed(win: AgoraWindow)
## The window's [member AgoraWindow.frame] was (re)built and must be placed.
signal window_framed(win: AgoraWindow)
signal focus_changed(win: AgoraWindow)
signal stacking_changed
signal manager_changed
signal resized

var name := ":0"
var size := Vector2(1280, 720):
	set(value):
		if size == value:
			return
		size = value
		_refit_maximized()
		resized.emit()
## Window list in stacking order, bottom to top.
var windows: Array[AgoraWindow] = []
var focused: AgoraWindow
## The window manager: any object with [code]decorate(win) -> Control[/code]
## and optionally [code]place(win)[/code] and [code]handle_key(event) -> bool[/code].
var manager: Object
## Screen edges reserved by panels, so maximized windows don't cover them.
var struts := {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}

var machine: AgoraMachine:
	get:
		return _machine_ref.get_ref() as AgoraMachine if _machine_ref else null

var _machine_ref: WeakRef
var _next_id := 1
var _cascade := 0


func _init(p_name: String = ":0") -> void:
	name = p_name


## Serves the kernel [param m] from now on. Windows of a previous kernel
## (before a reboot) are gone.
func bind_machine(m: AgoraMachine) -> void:
	var old := machine
	if old == m:
		return
	if old and old.process_exited.is_connected(_on_process_exited):
		old.process_exited.disconnect(_on_process_exited)
	for w in windows.duplicate():
		close_window(w)
	_machine_ref = weakref(m)
	m.process_exited.connect(_on_process_exited)


# --- windows ----------------------------------------------------------------

## Opens a window for [param owner] showing [param content].
## [param opts]: title, size (content size), position, layer, decorated,
## resizable, min_size, focus (bool, default true for normal windows).
func open_window(owner: AgoraProcess, content: Control, opts: Dictionary = {}) -> AgoraWindow:
	var win := AgoraWindow.new(self)
	win.id = _next_id
	_next_id += 1
	win.pid = owner.pid
	win.content = content
	win.focus_target = content if content.focus_mode != Control.FOCUS_NONE else null
	win.layer = opts.get("layer", AgoraWindow.Layer.NORMAL)
	win.title = opts.get("title", owner.name)
	win.decorated = opts.get("decorated", win.layer == AgoraWindow.Layer.NORMAL)
	win.resizable = opts.get("resizable", true)
	win.min_size = opts.get("min_size", win.min_size)
	win.size = opts.get("size", win.size)
	if opts.has("position"):
		win.position = opts.position
	else:
		win.position = _default_position(win.size)
	windows.append(win)
	_frame(win)
	if manager and manager.has_method("place") and not opts.has("position"):
		manager.place(win)
	window_opened.emit(win)
	if opts.get("focus", win.layer == AgoraWindow.Layer.NORMAL or win.layer == AgoraWindow.Layer.OVERLAY):
		focus_window(win)
	return win


func close_window(win: AgoraWindow) -> void:
	if not win.open:
		return
	win.open = false
	windows.erase(win)
	if focused == win:
		focused = null
		focus_topmost()
	window_closed.emit(win)
	if win.frame and win.frame != win.content:
		win.frame.queue_free()
	if win.content:
		win.content.queue_free()
	win.closed.emit()


func windows_of(pid: int) -> Array[AgoraWindow]:
	var out: Array[AgoraWindow] = []
	for w in windows:
		if w.pid == pid:
			out.append(w)
	return out


func find_window(id: int) -> AgoraWindow:
	for w in windows:
		if w.id == id:
			return w
	return null


func _on_process_exited(p: AgoraProcess) -> void:
	for w in windows_of(p.pid):
		close_window(w)


# --- focus and stacking -----------------------------------------------------

func focus_window(win: AgoraWindow) -> void:
	if win == null or not win.open:
		return
	if win.minimized:
		win.minimized = false
		win.changed.emit()
	if win.layer == AgoraWindow.Layer.NORMAL or win.layer == AgoraWindow.Layer.OVERLAY:
		windows.erase(win)
		windows.append(win)
		stacking_changed.emit()
	if focused == win:
		return
	var old := focused
	focused = win
	if old and old.open:
		old.changed.emit()
	win.changed.emit()
	focus_changed.emit(win)


## Focuses the topmost visible normal window, or nothing.
func focus_topmost() -> void:
	for i in range(windows.size() - 1, -1, -1):
		var w := windows[i]
		if w.layer == AgoraWindow.Layer.NORMAL and not w.minimized and w != focused:
			focus_window(w)
			return
	var old := focused
	focused = null
	if old and old.open:
		old.changed.emit()
	focus_changed.emit(null)


# --- window manager ---------------------------------------------------------

func set_manager(m: Object) -> void:
	manager = m
	for w in windows:
		_frame(w)
	manager_changed.emit()


## Unregisters [param m] if it is still the manager (a newer one may have
## replaced it). Windows fall back to bare, undecorated frames.
func clear_manager(m: Object) -> void:
	if manager != m:
		return
	manager = null
	for w in windows:
		_frame(w)
	manager_changed.emit()


func _frame(win: AgoraWindow) -> void:
	var content := win.content
	if content.get_parent():
		content.get_parent().remove_child(content)
	if win.frame and win.frame != content:
		win.frame.queue_free()
	win.size -= win.frame_extra
	win.frame_extra = Vector2.ZERO
	if manager and win.decorated:
		win.frame = manager.decorate(win)
	else:
		win.frame = content
	win.size += win.frame_extra
	window_framed.emit(win)
	win.changed.emit()


# --- geometry ---------------------------------------------------------------

## Screen area not covered by panels.
func work_area() -> Rect2:
	return Rect2(struts.left, struts.top, size.x - struts.left - struts.right, size.y - struts.top - struts.bottom)


func set_strut(edge: String, amount: float) -> void:
	struts[edge] = amount
	_refit_maximized()


func _default_position(win_size: Vector2) -> Vector2:
	var area := work_area()
	var pos := area.position + (area.size - win_size) / 2.0 + Vector2(_cascade, _cascade) * 24.0
	_cascade = (_cascade + 1) % 6
	return pos.max(area.position).floor()


func _refit_maximized() -> void:
	for w in windows:
		if w.maximized:
			w.set_rect(work_area())
