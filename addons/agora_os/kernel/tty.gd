class_name AgoraTty
extends RefCounted
## A terminal line: the link between a screen (a GUI terminal window, the
## headless REPL, a remote ssh session) and the processes running on it.
##
## The front end calls [method type_line] for each line the user enters and
## listens to [signal printed]. Line editing happens in the front end, as in
## the canonical mode of a real tty. Programs turn [member echo] off to read
## passwords.

signal printed(text: String)
signal mode_changed
## The window size changed (TIOCSWINSZ; programs would get SIGWINCH).
signal resized

var name := "tty1"
## Keyboard side: front end writes, processes read.
var input := AgoraStream.new()
## Screen side: processes write, front end reads.
var output := AgoraStream.new()
## The front end should show typed characters only while this is true.
var echo := true:
	set(value):
		echo = value
		mode_changed.emit()
## Raw (non-canonical) mode, for full-screen programs: every key reaches the
## program as it is typed, arrows and the like as escape sequences (see
## [method type_key]), and nothing is echoed. Ctrl+C still interrupts.
var raw := false:
	set(value):
		raw = value
		mode_changed.emit()
## A serial line's speed in bits per second ("console=ttyS0,115200" sets
## it). A terminal at another speed on the other end of the cable sees
## garbage.
var baud := 9600
## Window size in characters, set by the front end (what TIOCGWINSZ tells).
var cols := 80:
	set(value):
		if value != cols:
			cols = value
			resized.emit()
var rows := 24:
	set(value):
		if value != rows:
			rows = value
			resized.emit()
## Processes that receive Ctrl+C. The shell updates this around each job.
var foreground: Array[AgoraProcess] = []
## Set by the shell so the front end can browse history with the arrow keys.
var history_provider: Callable


func _init(p_name: String = "tty1") -> void:
	name = p_name
	input.add_writer()
	output.add_reader()
	output.changed.connect(_flush)


func _flush() -> void:
	var text := output.read_available()
	if not text.is_empty():
		printed.emit(text)


func type_line(text: String) -> void:
	input.write(text + "\n")


## A key in raw mode: its characters go to the program at once.
func type_key(text: String) -> void:
	input.write(text)


## Ctrl+D: the next read returns end-of-file.
func send_eof() -> void:
	input.push_eof()


## Ctrl+C: SIGINT to every foreground process.
func interrupt() -> void:
	for p in foreground.duplicate():
		p.send_signal(AgoraProcess.SIGINT)


## True when a process is blocked waiting for a line from the keyboard.
func is_waiting_for_input() -> bool:
	return input.has_waiting_reader()


func history() -> PackedStringArray:
	return history_provider.call() if history_provider.is_valid() else PackedStringArray()


## Hangs up the line: foreground processes get SIGHUP and reads see EOF.
func hang_up() -> void:
	for p in foreground.duplicate():
		p.send_signal(AgoraProcess.SIGHUP)
	input.release_writer()
