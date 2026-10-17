extends AgoraGuiProgram
## Terminal emulator: a window with an AgoraTermView on a new pseudo-terminal,
## running the user's shell.


func summary() -> String:
	return "terminal emulator"


func usage() -> String:
	return "usage: terminal [-e command...]"


func main(p: AgoraProcess) -> int:
	var tty := AgoraTty.new(p.machine.alloc_pty())
	var view := AgoraTermView.new()
	view.attach(tty)
	var win := open_window(p, view, {"title": "Terminal - %s" % tty.name, "size": view.size_for(80, 24), "min_size": view.size_for(20, 4)})
	if win == null:
		return 1
	var argv := PackedStringArray([p.getenv("SHELL", "/bin/sh")])
	var e := p.argv.find("-e")
	if e >= 0 and e + 1 < p.argv.size():
		argv = PackedStringArray(["/bin/sh", "-c", " ".join(p.argv.slice(e + 1))])
	var shell := p.spawn(argv, {
		"stdin": tty.input, "stdout": tty.output, "stderr": tty.output, "tty": tty, "start": false,
	})
	if shell == null:
		view.feed("terminal: cannot run %s: %s\n" % [argv[0], AgoraErrno.describe(p.errno)])
	else:
		tty.foreground.assign([shell])
		shell.exited.connect(_on_shell_exit.bind(win), CONNECT_ONE_SHOT)
		shell.start()
	if win.open:
		await win.closed
	tty.hang_up()
	if shell and shell.is_running():
		shell.send_signal(AgoraProcess.SIGKILL)
	return 0


func _on_shell_exit(_code: int, win: AgoraWindow) -> void:
	if win.open:
		win.close()
