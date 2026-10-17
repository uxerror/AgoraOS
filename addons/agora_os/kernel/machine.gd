class_name AgoraMachine
extends RefCounted
## One computer: its file system, accounts, processes and clock.
##
## Nothing here is global. The desktop runs on one machine, and the game can
## create as many more as it needs (servers, routers, other players' boxes),
## attach them to an [AgoraNetwork] and reach them with ssh.
##
## Typical use:
## [codeblock]
## var m := AgoraMachine.create("box", {"users": [{"name": "neo", "password": "x"}]})
## var tty := AgoraTty.new()
## m.login("neo", tty)
## [/codeblock]

signal process_started(process: AgoraProcess)
signal process_exited(process: AgoraProcess)

const KERNEL_NAME := "Agora"
const KERNEL_VERSION := "0.1.0"
const IMAGE_FORMAT := 1
const DEFAULT_PATH := "/bin:/usr/bin"
## Header of a native executable. The rest of the first line is the program
## name in [AgoraPrograms].
const EXEC_MAGIC := "\u007fAGX "
const MAX_SHEBANG_DEPTH := 2

var vfs: AgoraVfs
var clock: AgoraClock
var users: AgoraUsers
var dev: AgoraDevFs
var ip := "127.0.0.1"
var boot_time := 0.0
var errno: int = AgoraErrno.OK
## The machine's screen, or null for a headless box (a server you can only
## reach over ssh). See [method attach_display].
var display: AgoraDisplay

var hostname: String:
	get:
		return vfs.read_text(AgoraCred.root(), "/etc/hostname").strip_edges()
	set(value):
		vfs.write_text(AgoraCred.root(), "/etc/hostname", value + "\n")

var network: AgoraNetwork:
	get:
		return _network_ref.get_ref() as AgoraNetwork if _network_ref else null
	set(value):
		_network_ref = weakref(value) if value else null

var _network_ref: WeakRef
var _root_fs: AgoraMemFs
var _processes := {} # pid -> AgoraProcess
var _next_pid := 1


func _init(p_clock: AgoraClock = null) -> void:
	clock = p_clock if p_clock else AgoraClock.new()
	vfs = AgoraVfs.new(clock.now_int)
	_root_fs = AgoraMemFs.new()
	vfs.mount("/", _root_fs)
	users = AgoraUsers.new(vfs)
	dev = AgoraDevFs.new()


## Builds a fresh machine with the base system installed and booted.
## See [method AgoraInstaller.install] for [param opts].
static func create(p_hostname: String, opts: Dictionary = {}, p_clock: AgoraClock = null) -> AgoraMachine:
	var m := AgoraMachine.new(p_clock)
	AgoraInstaller.install(m, p_hostname, opts)
	m.boot()
	return m


## Mounts the kernel file systems and starts init (pid 1).
func boot() -> void:
	var root := AgoraCred.root()
	for point in ["/proc", "/dev"]:
		if not vfs.exists(root, point):
			vfs.make_dirs(root, point)
	if vfs.get_mount("/proc") == null:
		vfs.mount("/proc", AgoraProcFs.new(self))
	if vfs.get_mount("/dev") == null:
		vfs.mount("/dev", dev)
	boot_time = clock.now()
	dev.mtime = int(boot_time)
	if not _processes.has(1):
		var init := AgoraProcess.new(self)
		init.pid = _alloc_pid()
		init.name = "init"
		init.argv = PackedStringArray(["init"])
		init.exe = "/sbin/init"
		init.cred = root
		init.stdin = AgoraStream.empty()
		init.stdout = AgoraStream.discard()
		init.stderr = init.stdout
		init.state = AgoraProcess.State.RUNNING
		init.start_time = clock.now()
		_processes[init.pid] = init
	log_event("syslog", "kernel", "%s %s booted" % [KERNEL_NAME, KERNEL_VERSION])


## Mounts a real directory (e.g. "user://home") at [param at], owned by
## [param owner]. Mounts are not part of the saved image: the app mounts
## them again after loading.
func mount_host(host_path: String, at: String, owner: String = "root") -> int:
	var root := AgoraCred.root()
	var u := users.find(owner)
	var real := ProjectSettings.globalize_path(host_path)
	vfs.make_dirs(root, at)
	errno = vfs.mount(at, AgoraHostFs.new(real, u.get("uid", 0), u.get("gid", 0)))
	return errno


## Gives the machine a screen. Front ends call this, then show the display
## with an [AgoraDisplayView].
func attach_display(display_name: String = ":0") -> AgoraDisplay:
	if display == null:
		display = AgoraDisplay.new(self, display_name)
	return display


## Sends [param sig] to every process of a session, leader last.
func kill_session(sid: int, sig: int = AgoraProcess.SIGHUP) -> void:
	if sid <= 0:
		return
	var leader: AgoraProcess = null
	for pid in list_pids():
		var proc := get_process(pid)
		if proc == null or proc.sid != sid:
			continue
		if proc.pid == sid:
			leader = proc
		else:
			proc.send_signal(sig)
	if leader:
		leader.send_signal(sig)


var _next_pty := 0


## Name for a new pseudo-terminal, like "pts/0".
func alloc_pty() -> String:
	_next_pty += 1
	return "pts/%d" % (_next_pty - 1)


## Kills every process except init. Call before dropping the machine.
func shutdown() -> void:
	for pid in list_pids():
		# Killing one process can end others (a session), so look each up again.
		var proc := get_process(pid)
		if proc and pid != 1:
			proc.send_signal(AgoraProcess.SIGKILL)
	_processes.clear()


# --- processes --------------------------------------------------------------

func _alloc_pid() -> int:
	var pid := _next_pid
	_next_pid += 1
	return pid


func get_process(pid: int) -> AgoraProcess:
	return _processes.get(pid)


func list_pids() -> Array[int]:
	var pids: Array[int] = []
	pids.assign(_processes.keys())
	pids.sort()
	return pids


func _on_process_exit(p: AgoraProcess) -> void:
	_processes.erase(p.pid)
	for other: AgoraProcess in _processes.values():
		if other.ppid == p.pid:
			other.ppid = 1
	process_exited.emit(p)


## Sends a signal on behalf of [param sender]. Users may only signal their
## own processes. Root may signal anything except init.
func kill(pid: int, sig: int, sender: AgoraCred) -> int:
	var p := get_process(pid)
	if p == null or pid == 1:
		errno = AgoraErrno.ESRCH if p == null else AgoraErrno.EPERM
		return errno
	if not sender.is_root() and sender.uid != p.cred.uid and sender.uid != p.cred.ruid:
		errno = AgoraErrno.EPERM
		return errno
	p.send_signal(sig)
	errno = AgoraErrno.OK
	return errno


## Finds the file [param command] would run: as a path if it contains "/",
## otherwise by searching [param search_path]. Returns "" with errno set.
func find_executable(command: String, search_path: String, cred: AgoraCred, cwd: String) -> String:
	if command.contains("/"):
		var st := vfs.stat(cred, command, cwd)
		errno = vfs.errno
		return AgoraPath.normalize(command, cwd) if st != null else ""
	for dir in search_path.split(":", false):
		var candidate := AgoraPath.join(dir, command)
		var st := vfs.stat(cred, candidate, cwd)
		if st != null and st.is_file() and AgoraVfs.can_access(cred, st, AgoraStat.X):
			errno = AgoraErrno.OK
			return candidate
	errno = AgoraErrno.ENOENT
	return ""


## Starts a new process and returns it, or null with [member errno] set.
## [param opts]:
## - cred (AgoraCred, default root), cwd ("/"), env ({})
## - stdin, stdout, stderr (AgoraStream; default empty input, discarded output)
## - tty (AgoraTty), parent (AgoraProcess)
## - new_session (bool): the process leads a new session (sid = its pid)
## - start (bool, default true): false lets the caller wire up a pipeline
##   before anything runs. Call [method AgoraProcess.start] later.
func spawn(argv: PackedStringArray, opts: Dictionary = {}) -> AgoraProcess:
	errno = AgoraErrno.OK
	if argv.is_empty():
		errno = AgoraErrno.EINVAL
		return null
	var cred: AgoraCred = (opts.get("cred", AgoraCred.root()) as AgoraCred).copy()
	var cwd: String = opts.get("cwd", "/")
	var env: Dictionary = (opts.get("env", {}) as Dictionary).duplicate()
	var path := find_executable(argv[0], str(env.get("PATH", DEFAULT_PATH)), cred, cwd)
	if path.is_empty():
		return null
	var image := _load_image(path, argv, cred, cwd, 0)
	if image.is_empty():
		return null
	var st: AgoraStat = image.stat
	if st.mode & AgoraStat.S_ISUID:
		cred.uid = st.uid
	if st.mode & AgoraStat.S_ISGID:
		cred.gid = st.gid

	var p := AgoraProcess.new(self)
	p.pid = _alloc_pid()
	var parent: AgoraProcess = opts.get("parent")
	p.ppid = parent.pid if parent else 1
	p.sid = p.pid if opts.get("new_session", false) else (parent.sid if parent else 0)
	p.argv = image.argv
	p.name = AgoraPath.basename(argv[0])
	p.exe = image.path
	p.cred = cred
	p.cwd = cwd
	p.env = env
	p.tty = opts.get("tty")
	p.stdin = opts.get("stdin", AgoraStream.empty())
	p.stdout = opts.get("stdout", AgoraStream.discard())
	p.stderr = opts.get("stderr", p.stdout)
	p.stdin.add_reader()
	p.stdout.add_writer()
	p.stderr.add_writer()
	p.start_time = clock.now()
	p._program = (image.script as Script).new()
	_processes[p.pid] = p
	process_started.emit(p)
	if opts.get("start", true):
		p.start()
	return p


## Reads an executable and returns {script, argv, path, stat}, following
## "#!" interpreter lines. Returns {} with errno set on failure.
func _load_image(path: String, argv: PackedStringArray, cred: AgoraCred, cwd: String, depth: int) -> Dictionary:
	var st := vfs.stat(cred, path, cwd)
	if st == null:
		errno = vfs.errno
		return {}
	if st.is_dir():
		errno = AgoraErrno.EISDIR
		return {}
	if not st.is_file() or not AgoraVfs.can_access(cred, st, AgoraStat.X) \
			or not AgoraVfs.can_access(cred, st, AgoraStat.R):
		errno = AgoraErrno.EACCES
		return {}
	var head := vfs.read_file(cred, path, cwd).slice(0, 256).get_string_from_utf8()
	var first_line := head.get_slice("\n", 0)
	if first_line.begins_with(EXEC_MAGIC):
		var script: Script = AgoraPrograms.lookup(first_line.substr(EXEC_MAGIC.length()).strip_edges())
		if script == null:
			errno = AgoraErrno.ENOEXEC
			return {}
		return {"script": script, "argv": argv, "path": AgoraPath.normalize(path, cwd), "stat": st}
	if first_line.begins_with("#!") and depth < MAX_SHEBANG_DEPTH:
		var words := first_line.substr(2).strip_edges().split(" ", false)
		if words.is_empty():
			errno = AgoraErrno.ENOEXEC
			return {}
		var new_argv := PackedStringArray([words[0]])
		new_argv.append_array(words.slice(1))
		new_argv.append(AgoraPath.normalize(path, cwd))
		new_argv.append_array(argv.slice(1))
		var inner := _load_image(words[0], new_argv, cred, cwd, depth + 1)
		if not inner.is_empty():
			# Like most Unixes, setuid bits on scripts are ignored.
			inner.stat = st.duplicate_stat()
			inner.stat.mode &= ~(AgoraStat.S_ISUID | AgoraStat.S_ISGID)
		return inner
	errno = AgoraErrno.ENOEXEC
	return {}


# --- sessions ---------------------------------------------------------------

## Starts a login shell for [param user_name] on [param tty] without asking
## for a password. Front ends use this for the local desktop session.
func login(user_name: String, tty: AgoraTty, parent: AgoraProcess = null) -> AgoraProcess:
	var u := users.find(user_name)
	if u.is_empty():
		errno = AgoraErrno.ENOENT
		return null
	var env := {
		"HOME": u.home, "USER": u.name, "LOGNAME": u.name, "SHELL": u.shell,
		"PATH": DEFAULT_PATH, "TERM": "agora", "PWD": u.home,
	}
	var cwd: String = u.home if vfs.is_dir(users.cred_for(user_name), u.home) else "/"
	return _spawn_login_shell(u, env, cwd, tty, parent)


func _spawn_login_shell(u: Dictionary, env: Dictionary, cwd: String, tty: AgoraTty, parent: AgoraProcess) -> AgoraProcess:
	# A login shell is the user's shell started with "-" in front of argv[0].
	var p := spawn(PackedStringArray([u.shell]), {
		"cred": users.cred_for(u.name), "cwd": cwd, "env": env, "tty": tty,
		"stdin": tty.input, "stdout": tty.output, "stderr": tty.output,
		"parent": parent, "start": false,
	})
	if p == null:
		return null
	p.argv[0] = "-" + AgoraPath.basename(u.shell)
	tty.foreground.assign([p])
	p.start()
	return p


# --- logging ----------------------------------------------------------------

## Appends a syslog-style line to /var/log/<file>. These logs are part of the
## file system, so intruders can read them and clean up after themselves.
func log_event(file: String, tag: String, message: String) -> void:
	var root := AgoraCred.root()
	if not vfs.is_dir(root, "/var/log"):
		return
	var line := "%s %s %s: %s\n" % [clock.format_log(), hostname, tag, message]
	vfs.write_text(root, "/var/log/" + file, line, "/", true, 416) # 0o640


# --- persistence ------------------------------------------------------------

func serialize() -> Dictionary:
	return {
		"format": IMAGE_FORMAT,
		"root": _root_fs.serialize(),
		"clock": clock.serialize(),
		"ip": ip,
	}


## Builds and boots a machine from [method serialize] output.
static func deserialize(data: Dictionary, p_clock: AgoraClock = null) -> AgoraMachine:
	var m := AgoraMachine.new(p_clock)
	m._root_fs.deserialize(data.get("root", {}))
	if p_clock == null and data.has("clock"):
		m.clock.deserialize(data.clock)
	m.ip = data.get("ip", "127.0.0.1")
	m.boot()
	return m


## Saves the machine image (compressed) to a real file, e.g. under user://.
func save_image(path: String) -> int:
	var f := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return FileAccess.get_open_error()
	f.store_var(serialize())
	return OK


static func load_image(path: String, p_clock: AgoraClock = null) -> AgoraMachine:
	var f := FileAccess.open_compressed(path, FileAccess.READ, FileAccess.COMPRESSION_ZSTD)
	if f == null:
		return null
	var data: Variant = f.get_var()
	if not data is Dictionary:
		return null
	return deserialize(data, p_clock)
