class_name AgoraStream
extends RefCounted
## One-directional text channel: a pipe between processes, the input or output
## side of a terminal, or a sink that writes into a file.
##
## Ends are reference counted. When every writer has released the stream,
## readers see end-of-file. When every reader has released it, writes fail
## (a broken pipe), which is how "yes | head" stops.
##
## Reads are coroutines: they await [signal changed] until data arrives.
## Godot resumes awaiting coroutines synchronously inside emit(), so a
## pipeline runs as a chain of nested calls with no threads involved.

signal changed

var _buf := ""
var _writers := 0
var _readers := 0
var _had_writers := false
var _had_readers := false
var _eof_marks := 0
var _waiting := 0


## A stream that is already at end-of-file. Default stdin of a process.
static func empty() -> AgoraStream:
	var s := AgoraStream.new()
	s._had_writers = true
	return s


## A stream that accepts and discards everything. Default stdout.
static func discard() -> AgoraStream:
	var s := AgoraStream.new()
	s.changed.connect(s._drop)
	s.add_reader()
	return s


## A stream whose whole content is [param text], followed by end-of-file.
static func from_text(text: String) -> AgoraStream:
	var s := empty()
	s._buf = text
	return s


func _drop() -> void:
	_buf = ""


func add_writer() -> void:
	_writers += 1
	_had_writers = true


func release_writer() -> void:
	_writers = maxi(0, _writers - 1)
	changed.emit()


func add_reader() -> void:
	_readers += 1
	_had_readers = true


func release_reader() -> void:
	# The buffer is kept: other readers of the same stream (the next command
	# reading a redirected file in a loop) still need what's left in it.
	_readers = maxi(0, _readers - 1)
	changed.emit()


## True when every writer is gone, so no more data will arrive.
func is_eof() -> bool:
	return _had_writers and _writers == 0


## True when every reader is gone, so writes would go nowhere.
func is_broken() -> bool:
	return _had_readers and _readers == 0


## True while some coroutine is blocked waiting for input on this stream.
func has_waiting_reader() -> bool:
	return _waiting > 0


func available() -> int:
	return _buf.length()


## Appends text. Returns false if the stream is broken.
func write(text: String) -> bool:
	if is_broken():
		return false
	if text.is_empty():
		return true
	_buf += text
	changed.emit()
	return true


## A one-shot end-of-file for the next read, like Ctrl+D on a terminal.
func push_eof() -> void:
	_eof_marks += 1
	changed.emit()


## Puts [param text] back in front of what is buffered, for a reader that
## took more than it could use now. Readers are not woken.
func unread(text: String) -> void:
	_buf = text + _buf


## Takes everything buffered right now without waiting.
func read_available() -> String:
	var out := _buf
	_buf = ""
	return out


## Reads one line without its newline. Returns null at end-of-file, or when
## [param abort] returns true (the reading process was killed).
func read_line(abort: Callable = Callable()) -> Variant:
	while true:
		var idx := _buf.find("\n")
		if idx >= 0:
			var line := _buf.substr(0, idx)
			_buf = _buf.substr(idx + 1)
			return line
		if is_eof() or _eof_marks > 0:
			if _buf.is_empty():
				if _eof_marks > 0:
					_eof_marks -= 1
				return null
			return read_available()
		if abort.is_valid() and abort.call():
			return null
		_waiting += 1
		await changed
		_waiting -= 1
		# A reader that gave up must not take the next line from the others.
		if abort.is_valid() and abort.call():
			return null
	return null


## Reads until end-of-file and returns everything.
func read_all(abort: Callable = Callable()) -> String:
	while not is_eof() and _eof_marks == 0:
		if abort.is_valid() and abort.call():
			break
		_waiting += 1
		await changed
		_waiting -= 1
	if _eof_marks > 0:
		_eof_marks -= 1
	return read_available()
