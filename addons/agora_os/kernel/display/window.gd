class_name AgoraWindow
extends RefCounted
## A window on an [AgoraDisplay]. It belongs to the process that opened it
## and disappears when that process exits.
##
## [member content] is the app's own Control. [member frame] is what's
## actually on screen: the decoration built by the window manager around the
## content, or the content itself when there is no window manager.

signal changed
signal closed
## Emitted when the user asks to close the window (close button, Alt+F4).
## If nothing is connected, the window simply closes.
signal close_requested

enum Layer { DESKTOP, NORMAL, PANEL, OVERLAY }

var id := 0
var pid := 0
var title := "":
	set(value):
		title = value
		changed.emit()
var layer: Layer = Layer.NORMAL
var content: Control
var frame: Control
## Control that should get keyboard focus when the window is focused.
var focus_target: Control
## Whether a window manager may draw a title bar and border around it.
var decorated := true
var resizable := true
var min_size := Vector2(160, 100)
## Outer rectangle (including decorations) in screen coordinates.
var position := Vector2.ZERO
var size := Vector2(640, 400)
var minimized := false
var maximized := false
## The window wants attention (a new message): the taskbar button blinks
## until the window is focused.
var urgent := false:
	set(value):
		if urgent != value:
			urgent = value
			changed.emit()
var open := true
## Size the decorations add around the content. Set by the window manager.
var frame_extra := Vector2.ZERO
## Rectangle to go back to when un-maximizing.
var restore_rect := Rect2()

var display: AgoraDisplay:
	get:
		return _display_ref.get_ref() as AgoraDisplay

var _display_ref: WeakRef


func _init(p_display: AgoraDisplay) -> void:
	_display_ref = weakref(p_display)


func rect() -> Rect2:
	return Rect2(position, size)


func set_rect(r: Rect2) -> void:
	position = r.position
	size = r.size.max(min_size + frame_extra)
	changed.emit()


func move_to(pos: Vector2) -> void:
	position = pos
	changed.emit()


func request_close() -> void:
	if close_requested.get_connections().is_empty():
		display.close_window(self)
	else:
		close_requested.emit()


func close() -> void:
	display.close_window(self)


func focus() -> void:
	display.focus_window(self)


func set_minimized(value: bool) -> void:
	if minimized == value:
		return
	minimized = value
	changed.emit()
	if value and display.focused == self:
		display.focus_topmost()
	elif not value:
		display.focus_window(self)


func set_maximized(value: bool) -> void:
	if maximized == value or not resizable:
		return
	if value:
		restore_rect = rect()
		maximized = true
		set_rect(display.work_area())
	else:
		maximized = false
		set_rect(restore_rect)


func is_focused() -> bool:
	return display != null and display.focused == self
