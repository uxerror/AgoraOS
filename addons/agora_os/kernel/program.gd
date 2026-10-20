class_name AgoraProgram
extends RefCounted
## Base class of every executable.
##
## A program is a script registered in [AgoraPrograms]. Its binary in /bin is
## a small file holding the program's name, so binaries can be copied, renamed,
## deleted or chmod-ed like any other file. [method main] may be a coroutine:
## awaiting input or a timer simply suspends the process.

## The multi-call binary running this program as an applet ("busybox"), or
## "". Applets with a different look than the full tool check it.
var multicall := ""


## Entry point. Return the exit status (0 means success).
func main(_p: AgoraProcess) -> int:
	return 0


## One-line description shown by "help".
func summary() -> String:
	return ""


## Usage text shown by "help <name>" and "<name> --help".
func usage() -> String:
	return ""


# --- helpers for filters ------------------------------------------------------

## Set by [method read_inputs] when some operand couldn't be read.
var input_failed := false


## Reads every operand file, or stdin when there are none or for "-".
## Returns [[name, text], ...]. Unreadable files are reported and skipped,
## and [member input_failed] is set.
func read_inputs(p: AgoraProcess, files: PackedStringArray) -> Array:
	var out: Array = []
	input_failed = false
	if files.is_empty():
		files = PackedStringArray(["-"])
	for f in files:
		if f == "-":
			out.append(["-", await p.read_all()])
			continue
		var text := p.read_text(f)
		if p.errno != AgoraErrno.OK:
			p.fail_path(f)
			input_failed = true
			continue
		out.append([f, text])
	return out


## Splits text into lines. A trailing newline doesn't produce an empty line.
static func lines_of(text: String) -> PackedStringArray:
	if text.is_empty():
		return PackedStringArray()
	var lines := text.split("\n")
	if text.ends_with("\n"):
		lines.remove_at(lines.size() - 1)
	return lines


## True when stdout goes straight to a terminal (not a pipe or file).
static func is_terminal(p: AgoraProcess) -> bool:
	return p.tty != null and p.stdout == p.tty.output


## Reads a line from the terminal without echo, for passwords. With
## [param from_tty] it reads the terminal itself (/dev/tty) even when stdin
## is a pipe, as ssh does.
static func read_secret(p: AgoraProcess, prompt_text: String, from_tty: bool = false) -> Variant:
	if p.tty:
		p.tty.output.write(prompt_text)
		p.tty.echo = false
	else:
		p.err(prompt_text)
	var line: Variant
	if from_tty and p.tty:
		line = await p.tty.input.read_line(p.is_dead)
	else:
		line = await p.read_line()
	if p.tty:
		p.tty.echo = true
		p.tty.output.write("\n")
	return line
