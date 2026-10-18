class_name AgoraProcess
extends RefCounted
## A running program on a machine.
##
## Programs receive their process in [method AgoraProgram.main] and use it for
## everything: arguments, environment, I/O streams, and file system calls that
## run with the process's credentials and current directory. File calls set
## [member errno] like their libc counterparts.

signal exited(code: int)
## The process exited, or went into the background with [method daemonize]:
## whoever waits for it can carry on.
signal released(code: int)

const SIGHUP := 1
const SIGINT := 2
const SIGKILL := 9
const SIGUSR1 := 10
const SIGUSR2 := 12
const SIGPIPE := 13
const SIGTERM := 15

const SIGNAL_NAMES := {1: "HUP", 2: "INT", 9: "KILL", 10: "USR1", 12: "USR2", 13: "PIPE", 15: "TERM"}

enum State { NEW, RUNNING, EXITED }

var pid := 0
var ppid := 0
## Session id: every process started from one login shares it, so logging
## out can end them all (see [method AgoraMachine.kill_session]).
var sid := 0
var name := ""
var argv: PackedStringArray = []
## Absolute path of the executable that was started.
var exe := ""
var cred: AgoraCred
var cwd := "/"
var env := {}
var stdin: AgoraStream
var stdout: AgoraStream
var stderr: AgoraStream
var tty: AgoraTty
## The network connection on stdin and stdout, for servers started by inetd
## (what getpeername(2) on fd 0 would tell).
var socket: AgoraTcp.Conn
var state := State.NEW
var exit_code := 0
var errno: int = AgoraErrno.OK
var start_time := 0.0
## Called with a signal number before the default action (terminate). Return
## true to handle the signal yourself. SIGKILL can't be handled.
var signal_handler: Callable

var machine: AgoraMachine:
	get:
		return _machine_ref.get_ref() as AgoraMachine

var _machine_ref: WeakRef
var _program: AgoraProgram
var _last_yield_ms := 0
var _daemon := false


func _init(p_machine: AgoraMachine) -> void:
	_machine_ref = weakref(p_machine)


# --- life cycle -------------------------------------------------------------

func start() -> void:
	if state != State.NEW:
		return
	state = State.RUNNING
	_last_yield_ms = Time.get_ticks_msec()
	_run()


func _run() -> void:
	var code: Variant = await _program.main(self)
	_finish(code if code is int else 0)


func is_running() -> bool:
	return state != State.EXITED


## Used as an abort check for blocking reads.
func is_dead() -> bool:
	return state == State.EXITED


func state_letter() -> String:
	match state:
		State.NEW: return "N"
		State.RUNNING: return "R" if not stdin.has_waiting_reader() else "S"
	return "Z"


## Waits until the process exits (or daemonizes) and returns its exit code.
func wait() -> int:
	if state == State.EXITED or _daemon:
		return exit_code if state == State.EXITED else 0
	return await released


## Goes into the background like daemon(3): whoever waits for the process
## sees it finish with status 0, while it keeps running in a session of its
## own, a child of init, with no terminal and its output discarded.
func daemonize() -> void:
	if _daemon or state == State.EXITED:
		return
	_daemon = true
	ppid = 1
	sid = pid
	if tty:
		tty.foreground.erase(self)
	tty = null
	stdin.release_reader()
	stdout.release_writer()
	stderr.release_writer()
	stdin = AgoraStream.empty()
	stdout = AgoraStream.discard()
	stderr = stdout
	stdin.add_reader()
	stdout.add_writer()
	stderr.add_writer()
	released.emit(0)


func send_signal(sig: int) -> void:
	if state == State.EXITED:
		return
	if sig != SIGKILL and signal_handler.is_valid() and signal_handler.call(sig):
		return
	_finish(128 + sig)


## Ends the process right away with [param code]. Its coroutine may still
## resume later, but every further output call is ignored.
func terminate(code: int) -> void:
	_finish(code)


func _finish(code: int) -> void:
	if state == State.EXITED:
		return
	state = State.EXITED
	exit_code = code
	stdin.release_reader()
	stdout.release_writer()
	stderr.release_writer()
	if tty:
		tty.foreground.erase(self)
	var m := machine
	if m:
		m._on_process_exit(self)
	exited.emit(code)
	if not _daemon:
		released.emit(code)
	_program = null
	signal_handler = Callable() # it usually points back at the program


# --- I/O --------------------------------------------------------------------

## Writes to stdout. Returns false if the process is dead or the pipe is
## broken. A broken pipe kills the process with SIGPIPE.
func out(text: String) -> bool:
	if state == State.EXITED:
		return false
	if not stdout.write(text):
		_finish(128 + SIGPIPE)
		return false
	return true


func outln(text: String = "") -> bool:
	return out(text + "\n")


func err(text: String) -> bool:
	if state == State.EXITED:
		return false
	return stderr.write(text)


func errln(text: String = "") -> bool:
	return err(text + "\n")


## Prints "name: message" to stderr and returns [param code], so programs
## can write [code]return p.fail("bad option")[/code].
func fail(message: String, code: int = 1) -> int:
	errln("%s: %s" % [name, message])
	return code


## Prints "name: path: <errno text>" to stderr using the current errno.
func fail_path(path: String, code: int = 1) -> int:
	return fail("%s: %s" % [path, AgoraErrno.describe(errno)], code)


## Reads one line from stdin, or null at end-of-file.
func read_line() -> Variant:
	return await stdin.read_line(is_dead)


func read_all() -> String:
	return await stdin.read_all(is_dead)


## Programs that loop for a long time call this to let the engine draw a
## frame now and then, so the game never freezes.
func tick() -> void:
	var now := Time.get_ticks_msec()
	if now - _last_yield_ms < 8:
		return
	_last_yield_ms = now
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.process_frame


## Sleeps for [param seconds] of real time. Returns early if killed.
func sleep(seconds: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or seconds <= 0.0:
		return
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while state != State.EXITED and Time.get_ticks_msec() < end:
		await tree.create_timer(minf(0.1, (end - Time.get_ticks_msec()) / 1000.0)).timeout


# --- environment ------------------------------------------------------------

func getenv(key: String, default: String = "") -> String:
	return str(env.get(key, default))


## Lexically normalized absolute path for [param path], relative to cwd.
func abspath(path: String) -> String:
	return AgoraPath.normalize(path, cwd)


func user_name() -> String:
	return machine.users.name_of(cred.uid)


func home() -> String:
	return getenv("HOME", "/")


## Starts a child process. Options are those of [method AgoraMachine.spawn];
## anything not given is inherited from this process.
func spawn(child_argv: PackedStringArray, opts: Dictionary = {}) -> AgoraProcess:
	var o := {
		"parent": self, "cred": cred, "cwd": cwd, "env": env, "tty": tty,
		"stdin": stdin, "stdout": stdout, "stderr": stderr,
	}
	o.merge(opts, true)
	var child := machine.spawn(child_argv, o)
	errno = machine.errno
	return child


## Runs a child to completion and returns its exit code, or 127 if it
## couldn't be started.
func run(child_argv: PackedStringArray, opts: Dictionary = {}) -> int:
	var child := spawn(child_argv, opts)
	if child == null:
		return 127
	return await child.wait()


# --- file system calls ------------------------------------------------------

func _sync(result: Variant) -> Variant:
	errno = machine.vfs.errno
	return result


func stat(path: String, follow: bool = true) -> AgoraStat:
	return _sync(machine.vfs.stat(cred, path, cwd, follow))


func exists(path: String) -> bool:
	return stat(path) != null


func is_dir(path: String) -> bool:
	var st := stat(path)
	return st != null and st.is_dir()


func realpath(path: String) -> String:
	return _sync(machine.vfs.realpath(cred, path, cwd))


func list_dir(path: String) -> PackedStringArray:
	return _sync(machine.vfs.list_dir(cred, path, cwd))


func read_bytes(path: String) -> PackedByteArray:
	return _sync(machine.vfs.read_file(cred, path, cwd))


func read_text(path: String) -> String:
	return read_bytes(path).get_string_from_utf8()


func write_bytes(path: String, data: PackedByteArray, append: bool = false, mode: int = AgoraStat.MODE_FILE) -> int:
	return _sync(machine.vfs.write_file(cred, path, data, cwd, append, mode))


func write_text(path: String, text: String, append: bool = false, mode: int = AgoraStat.MODE_FILE) -> int:
	return write_bytes(path, text.to_utf8_buffer(), append, mode)


func mkdir(path: String, mode: int = AgoraStat.MODE_DIR) -> int:
	return _sync(machine.vfs.mkdir(cred, path, cwd, mode))


func make_dirs(path: String, mode: int = AgoraStat.MODE_DIR) -> int:
	return _sync(machine.vfs.make_dirs(cred, path, cwd, mode))


func unlink(path: String) -> int:
	return _sync(machine.vfs.unlink(cred, path, cwd))


func rmdir(path: String) -> int:
	return _sync(machine.vfs.rmdir(cred, path, cwd))


func rename(from_path: String, to_path: String) -> int:
	return _sync(machine.vfs.rename(cred, from_path, to_path, cwd))


func symlink(target: String, link_path: String) -> int:
	return _sync(machine.vfs.symlink(cred, target, link_path, cwd))


func read_link(path: String) -> String:
	return _sync(machine.vfs.read_link(cred, path, cwd))


func chmod(path: String, mode: int) -> int:
	return _sync(machine.vfs.chmod(cred, path, mode, cwd))


func chown(path: String, uid: int, gid: int, follow: bool = true) -> int:
	return _sync(machine.vfs.chown(cred, path, uid, gid, cwd, follow))


func touch_time(path: String, mtime: int = -1) -> int:
	return _sync(machine.vfs.touch_time(cred, path, mtime, cwd))


## Changes the current directory. Needs search (x) permission on the target.
func chdir(path: String) -> int:
	var st := stat(path)
	if st == null:
		return errno
	if not st.is_dir():
		errno = AgoraErrno.ENOTDIR
		return errno
	if not AgoraVfs.can_access(cred, st, AgoraStat.X):
		errno = AgoraErrno.EACCES
		return errno
	cwd = machine.vfs.realpath(cred, path, cwd)
	env["PWD"] = cwd
	errno = AgoraErrno.OK
	return errno
