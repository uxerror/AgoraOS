class_name AgoraMachine
extends RefCounted
## One computer: its file system, accounts, processes and clock.
##
## Nothing here is global. The desktop runs on one machine, and the game can
## create as many more as it needs (servers, routers, other players' boxes),
## cable their network ports together ([method AgoraHardware.connect_port])
## and reach them with ssh.
##
## Typical use:
## [codeblock]
## var m := AgoraMachine.create("box", {"users": [{"name": "neo", "password": "x"}]})
## var tty := AgoraTty.new()
## m.login("neo", tty)
## [/codeblock]

signal process_started(process: AgoraProcess)
signal process_exited(process: AgoraProcess)
## The machine finished booting: init (pid 1) is running.
signal booted
## The machine was powered off or halted. Front ends may close the window.
signal powered_off
## Init died. Everything stopped, like a real kernel panic.
signal panicked

const KERNEL_NAME := "Agora"
const KERNEL_VERSION := "0.1.0"
const DEFAULT_PATH := "/bin:/usr/bin:/sbin:/usr/sbin"
const INIT_PATH := "/sbin/init"
const KMSG_MAX := 500

enum State { OFF, RUNNING, PANIC }
## Header of a native executable. The rest of the first line is the program
## name in [AgoraPrograms].
const EXEC_MAGIC := "\u007fAGX "
const MAX_SHEBANG_DEPTH := 2

var vfs: AgoraVfs
var clock: AgoraClock
var users: AgoraUsers
var dev: AgoraDevFs
## The network stack of the running kernel, null while the machine is off.
var net: AgoraNetStack
var boot_time := 0.0
var errno: int = AgoraErrno.OK
var state: State = State.OFF
## The box this kernel runs on, and the disk holding its root file system.
var hardware: AgoraHardware:
	get:
		return _hardware_ref.get_ref() as AgoraHardware if _hardware_ref else null
var root_disk: AgoraDisk

## The machine's screen, or null for a headless box (a server you can only
## reach over ssh).
var display: AgoraDisplay:
	get:
		return hardware.display if hardware else null
## Kernel ring buffer, read with dmesg (/proc/kmsg).
var kmsg: PackedStringArray = []

var hostname: String:
	get:
		return vfs.read_text(AgoraCred.root(), "/etc/hostname").strip_edges()
	set(value):
		vfs.write_text(AgoraCred.root(), "/etc/hostname", value + "\n")

var _hardware_ref: WeakRef
var _processes := {} # pid -> AgoraProcess
var _next_pid := 1
var _halting := false


## A kernel for [param p_hardware], with its root file system on
## [param p_root_disk]. Hardware firmware creates these; use [method create]
## for a ready-made machine.
func _init(p_clock: AgoraClock, p_hardware: AgoraHardware, p_root_disk: AgoraDisk) -> void:
	clock = p_clock
	_hardware_ref = weakref(p_hardware)
	root_disk = p_root_disk
	vfs = AgoraVfs.new(clock.now_int)
	vfs.mount("/", root_disk.fs, "/dev/" + p_hardware.fs_device_name(root_disk))
	users = AgoraUsers.new(vfs)
	dev = AgoraDevFs.new()


## Builds a headless virtual PC with the system installed on its disk, and
## boots it unless [param autoboot] is false. [param opts] go to
## [method AgoraInstaller.install_disk]; "template" picks other hardware.
## The hardware stays reachable as [member hardware].
static func create(p_hostname: String, opts: Dictionary = {}, p_clock: AgoraClock = null, autoboot: bool = true) -> AgoraMachine:
	var hw := AgoraHardware.from_template(opts.get("template", "virtual"), p_clock)
	AgoraInstaller.install_disk(hw.disks[0], p_hostname, opts, hw.clock)
	# The hardware is only referenced weakly by its kernel; keep it alive.
	var m := hw.power_on(autoboot)
	m._owned_hardware = hw
	return m


## Holds the hardware of machines made by [method create], which have no
## other owner.
var _owned_hardware: AgoraHardware


## Mounts the kernel file systems and starts /sbin/init as pid 1. Which init
## that is (systemd, sysvinit, something the player wrote) is decided by the
## file system, not the kernel.
func boot() -> void:
	if state == State.RUNNING:
		return
	var root := AgoraCred.root()
	for point in ["/proc", "/dev", "/run"]:
		if not vfs.exists(root, point):
			vfs.make_dirs(root, point)
	if vfs.get_mount("/proc") == null:
		vfs.mount("/proc", AgoraProcFs.new(self))
	if vfs.get_mount("/dev") == null:
		vfs.mount("/dev", dev)
	# /run is a fresh in-memory file system on every boot, like tmpfs.
	vfs.unmount("/run")
	vfs.mount("/run", AgoraMemFs.new(), "tmpfs")
	if vfs.get_mount("/sys") == null and vfs.exists(root, "/sys"):
		vfs.mount("/sys", AgoraSysFs.new(self), "sysfs")
	_sync_devices()
	_halting = false
	_next_pid = 1
	net = AgoraNetStack.new(self)
	state = State.RUNNING
	boot_time = clock.now()
	dev.mtime = int(boot_time)
	klog("%s version %s booting on %s" % [KERNEL_NAME, KERNEL_VERSION, hostname])
	var init := spawn(PackedStringArray([INIT_PATH]), {"env": {"PATH": DEFAULT_PATH, "TERM": "agora"}, "start": false})
	if init == null:
		klog("Failed to execute %s (%s). Using the built-in fallback init." % [INIT_PATH, AgoraErrno.describe(errno)])
		_start_fallback_init()
	else:
		init.name = "init"
		init.start()
	booted.emit()


## A do-nothing pid 1 so a machine without a working /sbin/init still runs.
func _start_fallback_init() -> void:
	var init := AgoraProcess.new(self)
	init.pid = _alloc_pid()
	init.name = "init"
	init.argv = PackedStringArray(["init"])
	init.exe = "(kernel)"
	init.cred = AgoraCred.root()
	init.stdin = AgoraStream.empty()
	init.stdout = AgoraStream.discard()
	init.stderr = init.stdout
	init.state = AgoraProcess.State.RUNNING
	init.start_time = clock.now()
	_processes[init.pid] = init


## Power control, the reboot(2) system call. Only init may call it, after it
## has stopped its services. [param action] is "poweroff", "halt" or "reboot".
func power(action: String, caller: AgoraProcess) -> int:
	if caller == null or caller.pid != 1:
		errno = AgoraErrno.EPERM
		return errno
	klog("reboot: %s" % ("Restarting system" if action == "reboot" else "System halted" if action == "halt" else "Power down"))
	_stop_everything()
	var hw := hardware
	if action == "reboot":
		if hw:
			hw._kernel_reboot()
	else:
		powered_off.emit()
		if hw:
			hw._kernel_power_off()
	errno = AgoraErrno.OK
	return errno


func _stop_everything() -> void:
	_halting = true
	for sig in [AgoraProcess.SIGTERM, AgoraProcess.SIGKILL]:
		for pid in list_pids():
			# Killing one process can end others (a session), so look each up again.
			var proc := get_process(pid)
			if proc:
				proc.send_signal(sig)
	_processes.clear()
	if net:
		net.detach()
		net = null
	vfs.unmount("/run")
	state = State.OFF


## Appends a line to the kernel ring buffer and prints it on the console
## (the monitor's text console, or the serial port of a headless box).
func klog(message: String) -> void:
	var line := "[%10.4f] %s" % [clock.now() - boot_time if state == State.RUNNING else 0.0, message]
	kmsg.append(line)
	if kmsg.size() > KMSG_MAX:
		kmsg = kmsg.slice(kmsg.size() - KMSG_MAX)
	var tty := console_tty()
	if tty:
		tty.output.write(line + "\n")


## The system console: tty1 if there is a monitor, else ttyS0.
func console_tty() -> AgoraTty:
	var hw := hardware
	if hw == null:
		return null
	return hw.console if hw.console else hw.serial


## The terminal behind a device name ("tty1", "ttyS0", "/dev/ttyS0").
func get_tty(name: String) -> AgoraTty:
	var hw := hardware
	return hw.get_tty(name) if hw else null


## Creates /dev nodes for the hardware: disks, consoles, framebuffer.
## Called at boot and whenever media is inserted or removed.
func _sync_devices() -> void:
	var hw := hardware
	if hw == null:
		return
	for name in dev.list_dir(""):
		if name.begins_with("sd") or name.begins_with("sr") or name.begins_with("mtdblock") or name.begins_with("tty") or name == "fb0":
			dev.remove_device(name)
	for d in hw.disks:
		dev.add_device(hw.device_name(d), dev._empty_bytes, dev._discard, 432) # 0o660
		if d.is_formatted() and hw.fs_device_name(d) != hw.device_name(d):
			dev.add_device(hw.fs_device_name(d), dev._empty_bytes, dev._discard, 432)
	for tty: AgoraTty in [hw.console, hw.serial]:
		if tty:
			dev.add_device(tty.name, dev._empty_bytes, _tty_writer(tty), 400) # 0o620
	if hw.display:
		# A framebuffer device tells services (the login screen) there is a screen.
		dev.add_device("fb0", dev._empty_bytes, dev._discard, 432)


func _tty_writer(tty: AgoraTty) -> Callable:
	return func(data: PackedByteArray) -> void: tty.output.write(data.get_string_from_utf8())


## Mounts the file system of a disk device ("/dev/sdb1") at [param at].
func mount_device(device: String, at: String) -> int:
	var hw := hardware
	var disk := hw.find_device(device) if hw else null
	if disk == null:
		errno = AgoraErrno.ENOENT
		return errno
	if not disk.is_formatted():
		errno = AgoraErrno.EINVAL
		return errno
	if not vfs.mount_point_of(disk.fs).is_empty():
		errno = AgoraErrno.EBUSY
		return errno
	if not vfs.is_dir(AgoraCred.root(), at):
		errno = AgoraErrno.ENOTDIR
		return errno
	errno = vfs.mount(AgoraPath.normalize(at), disk.fs, "/dev/" + hw.fs_device_name(disk))
	return errno


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


## Plugs a monitor into the running machine (hot-plug). Front ends usually
## use hardware with a display from the start instead.
func attach_display(_display_name: String = ":0") -> AgoraDisplay:
	var hw := hardware
	var d := hw.add_display()
	d.bind_machine(self)
	_sync_devices()
	return d


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


## Pulls the plug: kills every process, init included, without a clean
## shutdown. Call before dropping the machine.
func shutdown() -> void:
	_stop_everything()
	_owned_hardware = null # breaks the machine <-> hardware cycle


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
	if net:
		net.udp.close_for(p.pid)
		net.tcp.close_for(p.pid)
	for other: AgoraProcess in _processes.values():
		if other.ppid == p.pid:
			other.ppid = 1
	process_exited.emit(p)
	if p.pid == 1 and not _halting and state == State.RUNNING:
		klog("Kernel panic - not syncing: Attempted to kill init! exitcode=%d" % p.exit_code)
		_stop_everything()
		state = State.PANIC
		panicked.emit()


## Sends a signal on behalf of [param sender]. Users may only signal their
## own processes. Root may signal anything; init ignores signals it doesn't
## handle. Signal 0 only checks that the process exists and may be signaled.
func kill(pid: int, sig: int, sender: AgoraCred) -> int:
	var p := get_process(pid)
	if p == null:
		errno = AgoraErrno.ESRCH
		return errno
	if not sender.is_root() and sender.uid != p.cred.uid and sender.uid != p.cred.ruid:
		errno = AgoraErrno.EPERM
		return errno
	errno = AgoraErrno.OK
	if sig == 0:
		return errno
	if pid == 1 and sig != AgoraProcess.SIGKILL and not (p.signal_handler.is_valid() and p.signal_handler.call(sig)):
		return errno # init can't be terminated by signals it doesn't catch
	if pid == 1 and sig == AgoraProcess.SIGKILL:
		errno = AgoraErrno.EPERM # the kernel protects init from SIGKILL
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

## Sends a message to the system logger through /dev/log, like syslog(3).
## [param facility] is "auth", "daemon", "kern", "cron" or "user". If no
## logger is running (syslogd killed, or not started yet), the message only
## reaches the kernel ring buffer, so stopping syslogd really stops logging.
func log_event(facility: String, tag: String, message: String) -> void:
	var root := AgoraCred.root()
	if vfs.stat(root, "/dev/log") != null:
		vfs.write_text(root, "/dev/log", "%s|%s|%s\n" % [facility, tag, message])
	else:
		klog("%s: %s" % [tag, message])


# --- ports ------------------------------------------------------------------

## Who listens on TCP [param port]: {pid, service}, or {} if nobody does.
func port_info(port: int) -> Dictionary:
	var l := net.tcp.listener_on(port) if net else null
	if l == null:
		return {}
	var owner := get_process(l.pid)
	return {"pid": l.pid, "service": owner.name if owner else ""}


## TCP ports something listens on, sorted.
func open_ports() -> Array[int]:
	var out: Array[int] = []
	if net:
		for l in net.tcp.listeners:
			if not out.has(l.port):
				out.append(l.port)
	out.sort()
	return out


# --- persistence ------------------------------------------------------------

## The whole box (hardware and disks), see [method AgoraHardware.serialize].
func serialize() -> Dictionary:
	return hardware.serialize()


## Saves the hardware with all its disks to a real file, e.g. under user://.
func save_image(path: String) -> int:
	return hardware.save(path)


## Loads hardware saved with [method save_image] and powers it on. Returns
## its kernel (booted unless [param autoboot] is false), or null if nothing
## on it is bootable.
static func load_image(path: String, p_clock: AgoraClock = null, autoboot: bool = true) -> AgoraMachine:
	var hw := AgoraHardware.load_from(path, p_clock)
	if hw == null:
		return null
	var m := hw.power_on(autoboot)
	if m:
		m._owned_hardware = hw
	return m
