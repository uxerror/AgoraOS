extends AgoraProgram
## minicom 2.1: a terminal on a serial port. With a console cable in the
## port (see [method AgoraHardware.connect_serial]) it is the console
## terminal of the box at the other end: what that box prints shows here,
## what is typed here reaches it, a line at a time while its console is in
## canonical mode, key by key in raw mode. At another speed than the
## other end's console the text comes out as garbage. Ctrl-A Z shows the
## special keys, Ctrl-A X leaves.
##
## /etc/minicom/minirc.dfl gives the port and speed ("pu port /dev/ttyS0",
## "pu baudrate 9600"); -D and -b override them.

const VERSION := "2.1"
const HELP := """
                 +-------------------------------------------------+
                 |               Minicom Command Summary            |
                 |                                                  |
                 |      Commands can be called by CTRL-A <key>      |
                 |                                                  |
                 |   Exit and reset.....X    Quit with no reset....Q |
                 |   Clear Screen.......C    Help screen...........Z |
                 |   Send break.........F    Local echo on/off.....E |
                 +-------------------------------------------------+
"""

var p: AgoraProcess
var _remote: AgoraTty
var _baud := 9600
var _line := ""
var _local_echo := false
var _done := false


func summary() -> String:
	return "friendly serial communication program"


func usage() -> String:
	return "Usage: minicom [OPTION]... [configuration]\n  -D, --device       : set device name (default /dev/ttyS0)\n  -b, --baudrate     : set baudrate (ignore the value from config)"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "Db", PackedStringArray(["device", "baudrate"]))
	if a.has("h") or a.has("help"):
		p.outln(usage())
		return 0
	var conf := _config()
	var device: String = a.value("D", a.value("device", conf.get("port", "/dev/ttyS0")))
	var baud_text: String = a.value("b", a.value("baudrate", conf.get("baudrate", "9600")))
	_baud = int(baud_text) if baud_text.is_valid_int() else 9600
	var name := device.trim_prefix("/dev/")
	var hw := p.machine.hardware
	var st := p.stat(device)
	if hw == null or st == null or not name.begins_with("ttyS") or hw.get_tty(name) == null:
		return p.fail("minicom: cannot open %s: No such file or directory" % device, 1)
	if not AgoraVfs.can_access(p.cred, st, AgoraStat.R | AgoraStat.W):
		return p.fail("minicom: cannot open %s: Permission denied" % device, 1)
	var tty := p.tty
	if tty == null:
		return p.fail("minicom: cannot open the terminal", 1)
	_remote = hw.serial_remote()
	p.out("\u001b[2J\u001b[H")
	p.outln("\nWelcome to minicom %s\n" % VERSION)
	p.outln("OPTIONS: History Buffer, F-key Macros, Search History Buffer, I18n")
	p.outln("Compiled on Jul 14 2006, 01:26:15.")
	p.outln("Port %s\n" % device)
	p.outln("Press CTRL-A Z for help on special keys\n")
	tty.raw = true
	p.signal_handler = _on_signal
	var show := func(text: String) -> void: p.out(_line_noise(text))
	if _remote:
		_remote.printed.connect(show)
	var escape := false
	while p.is_running() and not _done:
		var chunk: Variant = await p.stdin.read_some(p.is_dead)
		if chunk == null:
			break
		for ch: String in str(chunk):
			if escape:
				escape = false
				await _command(ch.to_lower())
				if _done:
					break
			elif ch == "\u0001":
				escape = true
			else:
				_send(ch)
	if _remote and _remote.printed.is_connected(show):
		_remote.printed.disconnect(show)
	p.signal_handler = Callable()
	tty.raw = false
	return 0


## The settings of /etc/minicom/minirc.dfl ("pu port ...").
func _config() -> Dictionary:
	var out := {}
	for line in p.read_text("/etc/minicom/minirc.dfl").split("\n", false):
		var w := line.strip_edges().split(" ", false)
		if w.size() >= 3 and w[0] == "pu":
			out[w[1]] = w[2]
	return out


## Ctrl-A, then [param key].
func _command(key: String) -> void:
	match key:
		"x", "q":
			p.out("\n\n +-------------------------+\n | Leave without reset? Yes |\n +-------------------------+\n")
			_done = true
		"z":
			p.out(HELP)
		"c":
			p.out("\u001b[2J\u001b[H")
		"e":
			_local_echo = not _local_echo
			p.out("\n[Local echo %s]\n" % ("ON" if _local_echo else "OFF"))
		"f":
			if _remote:
				_remote.interrupt()


## A key typed here, on its way down the cable.
func _send(ch: String) -> void:
	if _remote == null:
		if _local_echo:
			p.out(ch)
		return # nothing at the other end
	if _baud != _remote.baud:
		# The other end hears the wrong speed: it gets noise, not keys.
		return
	if _remote.raw:
		_remote.type_key(ch)
		return
	# The other end's console edits lines, as a terminal's line discipline
	# does: echo, backspace, Enter sends the line.
	var echo := _remote.echo or _local_echo
	match ch:
		"\n", "\r":
			if echo:
				p.out("\n")
			_remote.type_line(_line)
			_line = ""
		"\u007f", "\b":
			if not _line.is_empty():
				_line = _line.substr(0, _line.length() - 1)
				if echo:
					p.out("\b \b")
		"\u0003":
			_line = ""
			_remote.interrupt()
		"\u0004":
			if _line.is_empty():
				_remote.send_eof()
		_:
			if ch.unicode_at(0) >= 32:
				_line += ch
				if echo:
					p.out(ch)


## Ctrl+C on our own terminal goes down the line instead of stopping us.
func _on_signal(sig: int) -> bool:
	if sig == AgoraProcess.SIGINT:
		_send("\u0003")
		return true
	return false


## What arrives at the wrong speed: each character turned into line noise.
func _line_noise(text: String) -> String:
	if _remote == null or _baud == _remote.baud:
		return text
	var out := ""
	for ch in text:
		var c := ch.unicode_at(0)
		out += "\n" if ch == "\n" else String.chr(0xA0 + (c * 37 + _baud / 100) % 0x5F)
	return out
