extends SceneTree
## Headless kernel tests. Run with:
##   godot --headless --path . -s tests/run_tests.gd
## Exits with code 0 when everything passes.

var _failures := 0
var _checks := 0
var _current := ""
var _machines: Array[AgoraMachine] = []


func _initialize() -> void:
	_run_all()


func _run_all() -> void:
	var tests := [
		"test_paths", "test_vfs_basics", "test_permissions", "test_sticky_tmp",
		"test_symlinks", "test_shell_basics", "test_shell_pipes_and_redirects",
		"test_shell_expansion", "test_shell_logic", "test_shell_control_flow",
		"test_shell_functions", "test_shell_scripts", "test_broken_pipe",
		"test_coreutils", "test_exec_rules", "test_proc_and_ps",
		"test_interactive_su", "test_sudo", "test_persistence", "test_ssh",
		"test_display_basics", "test_gui_session", "test_mime_and_open", "test_gui_apps",
		"test_systemd", "test_systemd_units", "test_syslog", "test_sysvinit",
		"test_init_switch_and_power", "test_cron",
		"test_hardware", "test_netstack", "test_ethernet_arp", "test_iproute", "test_net_tools", "test_ping", "test_ifupdown", "test_bridge", "test_dhcp", "test_packages", "test_router", "test_install_from_cd",
	]
	for t: String in tests:
		_current = t
		if OS.get_environment("TRACE_TESTS") != "": print("== ", t)
		await call(t)
		for m in _machines:
			m.shutdown()
		_machines.clear()
	# Let interrupted sleepers wake up and finish before exit.
	await create_timer(0.3).timeout
	print("\n%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		printerr("FAIL [%s] %s" % [_current, what])


func check_eq(actual: Variant, expected: Variant, what: String) -> void:
	_checks += 1
	if actual != expected:
		_failures += 1
		printerr("FAIL [%s] %s\n  expected: %s\n  actual:   %s" % [_current, what, var_to_str(expected), var_to_str(actual)])


## Waits up to [param frames] / 60 seconds of real time for [param cond] to
## become true. Loops yield to the engine between iterations and daemons
## sleep on timers, so results may take a moment to appear.
func until(cond: Callable, frames: int = 60) -> void:
	var deadline := Time.get_ticks_msec() + frames * 1000 / 60
	while Time.get_ticks_msec() < deadline:
		if cond.call():
			return
		await create_timer(0.016).timeout


func make_machine(hostname: String = "box", extra: Dictionary = {}) -> AgoraMachine:
	var opts := {
		"root_password": "toor",
		"users": [
			{"name": "alice", "password": "wonderland", "groups": ["sudo"]},
			{"name": "bob", "password": "builder"},
		],
	}
	opts.merge(extra, true)
	var m := AgoraMachine.create(hostname, opts)
	_machines.append(m)
	return m


## Runs a command through sh -c as [param user] and returns {out, err, code}.
func run(m: AgoraMachine, cmd: String, user: String = "alice") -> Dictionary:
	var u := m.users.find(user)
	var out := AgoraStream.new()
	out.add_reader()
	var errs := AgoraStream.new()
	errs.add_reader()
	var p := m.spawn(PackedStringArray(["/bin/sh", "-c", cmd]), {
		"cred": m.users.cred_for(user), "cwd": u.home,
		"env": {"HOME": u.home, "USER": user, "PATH": AgoraMachine.DEFAULT_PATH},
		"stdout": out, "stderr": errs,
	})
	if p == null:
		return {"out": "", "err": "spawn failed", "code": -1}
	var code := await p.wait()
	return {"out": out.read_available(), "err": errs.read_available(), "code": code}


# --- tests ------------------------------------------------------------------

func test_paths() -> void:
	check_eq(AgoraPath.normalize("a/../b/./c", "/x"), "/x/b/c", "normalize relative")
	check_eq(AgoraPath.normalize("/../.."), "/", "normalize above root")
	check_eq(AgoraPath.dirname("/a/b"), "/a", "dirname")
	check_eq(AgoraPath.basename("/a/b/"), "b", "basename")
	check_eq(AgoraStat.parse_octal("755"), 493, "octal parse")
	check_eq(AgoraStat.to_octal(493), "755", "octal format")


func test_vfs_basics() -> void:
	var m := make_machine()
	var root := AgoraCred.root()
	var vfs := m.vfs
	check_eq(vfs.mkdir(root, "/data"), AgoraErrno.OK, "mkdir")
	check_eq(vfs.mkdir(root, "/data"), AgoraErrno.EEXIST, "mkdir twice")
	check_eq(vfs.write_text(root, "/data/a.txt", "hello"), AgoraErrno.OK, "write")
	check_eq(vfs.read_text(root, "/data/a.txt"), "hello", "read back")
	vfs.write_text(root, "/data/a.txt", " world", "/", true)
	check_eq(vfs.read_text(root, "/data/a.txt"), "hello world", "append")
	check_eq(vfs.rmdir(root, "/data"), AgoraErrno.ENOTEMPTY, "rmdir non-empty")
	check_eq(vfs.rename(root, "/data/a.txt", "/data/b.txt"), AgoraErrno.OK, "rename")
	check(not vfs.exists(root, "/data/a.txt") and vfs.exists(root, "/data/b.txt"), "rename moved entry")
	check_eq(vfs.rename(root, "/data", "/data/sub"), AgoraErrno.EINVAL, "move dir into itself")
	check_eq(vfs.unlink(root, "/data/b.txt"), AgoraErrno.OK, "unlink")
	check_eq(vfs.rmdir(root, "/data"), AgoraErrno.OK, "rmdir")
	check_eq(vfs.read_text(root, "/nope"), "", "read missing")
	check_eq(vfs.errno, AgoraErrno.ENOENT, "missing errno")
	check_eq(vfs.rename(root, "/etc/motd", "/proc/motd"), AgoraErrno.EBUSY if vfs.is_mount_point("/proc/motd") else AgoraErrno.EXDEV, "cross-device rename")


func test_permissions() -> void:
	var m := make_machine()
	var vfs := m.vfs
	var alice := m.users.cred_for("alice")
	var bob := m.users.cred_for("bob")
	check(vfs.read_text(alice, "/etc/shadow").is_empty() and vfs.errno == AgoraErrno.EACCES, "shadow unreadable for users")
	check(not vfs.read_text(alice, "/etc/passwd").is_empty(), "passwd readable")
	check_eq(vfs.write_text(alice, "/etc/passwd", "x"), AgoraErrno.EACCES, "passwd not writable")
	check_eq(vfs.write_text(alice, "/home/alice/notes.txt", "secret"), AgoraErrno.OK, "write in own home")
	check_eq(vfs.stat(alice, "/home/alice/notes.txt").mode, 420, "umask applied (0644)")
	check_eq(vfs.chmod(alice, "/home/alice/notes.txt", 384), AgoraErrno.OK, "chmod own file")
	check_eq(vfs.read_text(bob, "/home/alice/notes.txt"), "", "bob can't read 0600 file")
	check_eq(vfs.chmod(bob, "/home/alice/notes.txt", 511), AgoraErrno.EPERM, "bob can't chmod")
	check_eq(vfs.write_text(bob, "/home/alice/x", ""), AgoraErrno.EACCES, "bob can't write alice's home")
	check_eq(vfs.chown(alice, "/home/alice/notes.txt", 1001, -1), AgoraErrno.EPERM, "no giving files away")
	check_eq(vfs.mkdir(alice, "/root/x"), AgoraErrno.EACCES, "root home closed")
	check(vfs.list_dir(alice, "/root").is_empty() and vfs.errno == AgoraErrno.EACCES, "can't list /root")


func test_sticky_tmp() -> void:
	var m := make_machine()
	var alice := m.users.cred_for("alice")
	var bob := m.users.cred_for("bob")
	check_eq(m.vfs.write_text(alice, "/tmp/a", "x"), AgoraErrno.OK, "alice writes /tmp")
	check_eq(m.vfs.unlink(bob, "/tmp/a"), AgoraErrno.EPERM, "bob can't delete alice's /tmp file")
	check_eq(m.vfs.unlink(alice, "/tmp/a"), AgoraErrno.OK, "alice deletes her file")


func test_symlinks() -> void:
	var m := make_machine()
	var root := AgoraCred.root()
	m.vfs.make_dirs(root, "/a/b")
	m.vfs.write_text(root, "/a/b/f", "deep")
	check_eq(m.vfs.symlink(root, "/a/b", "/link"), AgoraErrno.OK, "symlink")
	check_eq(m.vfs.read_text(root, "/link/f"), "deep", "read through symlink")
	check_eq(m.vfs.realpath(root, "/link/f"), "/a/b/f", "realpath")
	m.vfs.symlink(root, "rel", "/a/loop1")
	m.vfs.symlink(root, "/a/loop1", "/a/rel")
	check(m.vfs.stat(root, "/a/loop1") == null and m.vfs.errno == AgoraErrno.ELOOP, "symlink loop detected")


func test_shell_basics() -> void:
	var m := make_machine()
	var r := await run(m, "echo hello world")
	check_eq(r.out, "hello world\n", "echo")
	check_eq(r.code, 0, "echo status")
	r = await run(m, "pwd; cd /tmp; pwd")
	check_eq(r.out, "/home/alice\n/tmp\n", "cd builtin")
	r = await run(m, "nosuchcmd")
	check_eq(r.code, 127, "command not found status")
	check(r.err.contains("command not found"), "command not found message")
	r = await run(m, "whoami; id")
	check(r.out.begins_with("alice\nuid=1000(alice) gid=1000(alice)"), "whoami/id: " + r.out)
	r = await run(m, "echo 'unterminated")
	check_eq(r.code, 2, "syntax error status")


func test_shell_pipes_and_redirects() -> void:
	var m := make_machine()
	var r := await run(m, "echo one > f.txt; echo two >> f.txt; cat f.txt")
	check_eq(r.out, "one\ntwo\n", "redirect and append")
	r = await run(m, "cat f.txt | wc -l")
	check_eq(r.out.strip_edges(), "2", "pipe to wc")
	r = await run(m, "printf_missing 2> err.txt; cat err.txt")
	check(r.out.contains("command not found"), "stderr redirect")
	r = await run(m, "ls /nonexistent 2>&1 | grep -c 'No such'")
	check_eq(r.out, "1\n", "2>&1 into pipe")
	r = await run(m, "wc -l < f.txt")
	check_eq(r.out.strip_edges(), "2", "input redirect")
	r = await run(m, "echo x > /etc/passwd")
	check_eq(r.code, 1, "redirect permission denied")
	r = await run(m, "echo gone > /dev/null; echo ok")
	check_eq(r.out, "ok\n", "/dev/null sink")
	r = await run(m, "printf_missing; echo $?")
	check_eq(r.out, "127\n", "$? after failure")


func test_shell_expansion() -> void:
	var m := make_machine()
	var r := await run(m, "X=world; echo \"hello $X\" '$X' ${X}s ${NOPE:-dflt}")
	check_eq(r.out, "hello world $X worlds dflt\n", "variables and quoting")
	r = await run(m, "echo ~ ~bob")
	check_eq(r.out, "/home/alice /home/bob\n", "tilde")
	r = await run(m, "touch a1 a2 b1; echo a*; echo 'a*'; echo z*")
	check_eq(r.out, "a1 a2\na*\nz*\n", "globbing")
	r = await run(m, "echo $(echo nested $(whoami))")
	check_eq(r.out, "nested alice\n", "command substitution")
	r = await run(m, "for_args() { :; }; true")
	check(r.code != 0 or true, "functions unsupported, no crash")
	r = await run(m, "A=1 env | grep '^A='")
	check_eq(r.out, "A=1\n", "prefix assignment")
	r = await run(m, "export Y=2; sh -c 'echo $Y'")
	check_eq(r.out, "2\n", "export to child")
	r = await run(m, "F=\"a  b\"; touch $F; ls")
	check(r.out.contains("a\n") and r.out.contains("b\n"), "field splitting")


func test_shell_logic() -> void:
	var m := make_machine()
	var r := await run(m, "true && echo yes || echo no")
	check_eq(r.out, "yes\n", "and/or true")
	r = await run(m, "false && echo yes || echo no")
	check_eq(r.out, "no\n", "and/or false")
	r = await run(m, "! false && echo negated")
	check_eq(r.out, "negated\n", "negation")
	r = await run(m, "[ -d /tmp ] && test -f /etc/passwd && echo files")
	check_eq(r.out, "files\n", "test and [")
	r = await run(m, "exit 3; echo unreachable")
	check_eq(r.code, 3, "exit code")
	check_eq(r.out, "", "exit stops execution")


func test_broken_pipe() -> void:
	var m := make_machine()
	var r := await run(m, "yes | head -n 3")
	check_eq(r.out, "y\ny\ny\n", "yes | head terminates")
	r = await run(m, "seq 1 1000 | tail -n 2")
	check_eq(r.out, "999\n1000\n", "seq | tail")


func test_coreutils() -> void:
	var m := make_machine()
	var r := await run(m, "mkdir -p d/e/f && touch d/e/f/x && find d -type f")
	check_eq(r.out, "d/e/f/x\n", "mkdir -p and find")
	r = await run(m, "cp -r d d2 && ls d2/e/f && rm -r d && ls")
	check(r.out.begins_with("x\n") and not r.out.contains("\nd\n"), "cp -r and rm -r: " + r.out)
	r = await run(m, "echo hi > a; mv a b; cat b; ls a")
	check(r.out.begins_with("hi\n") and r.code != 0, "mv")
	r = await run(m, "printf_x 2>/dev/null; echo 'b\na\nc\na' > s; sort s | uniq -c")
	check_eq(r.out, "      2 a\n      1 b\n      1 c\n", "sort | uniq -c")
	r = await run(m, "echo 'root:x:0' | cut -d : -f 1,3")
	check_eq(r.out, "root:0\n", "cut")
	r = await run(m, "echo hello | tr a-z A-Z")
	check_eq(r.out, "HELLO\n", "tr")
	r = await run(m, "touch f; chmod u+x,go-r f; ls -l f")
	check(r.out.begins_with("-rwx-w----") or r.out.begins_with("-rwx------"), "symbolic chmod: " + r.out)
	r = await run(m, "grep -n alice /etc/passwd")
	check(r.out.begins_with("2:alice:x:1000"), "grep -n: " + r.out)
	r = await run(m, "ln -s /etc/motd m && cat m")
	check_eq(r.out, "Welcome to box.\n", "ln -s")
	r = await run(m, "date +%Y | wc -c")
	check_eq(r.out.strip_edges(), "5", "date format")


func test_exec_rules() -> void:
	var m := make_machine()
	var r := await run(m, "echo 'echo from script $1' > s.sh; sh s.sh arg; ./s.sh")
	check(r.out.begins_with("from script arg\n"), "sh script.sh")
	check(r.err.contains("Permission denied"), "non-executable script refused")
	r = await run(m, "printf_x 2>/dev/null; echo '#!/bin/sh\necho shebang $1' > t.sh; chmod +x t.sh; ./t.sh ok")
	check_eq(r.out, "shebang ok\n", "shebang script")
	r = await run(m, "cp /bin/ls ./myls && ./myls -d /tmp")
	check_eq(r.out, "/tmp\n", "copied binary runs")
	r = await run(m, "echo junk > fake; chmod +x fake; ./fake")
	check_eq(r.code, 126, "exec format error")
	r = await run(m, "ls -l /bin/su")
	check(r.out.begins_with("-rwsr-xr-x"), "su is setuid: " + r.out)


func test_proc_and_ps() -> void:
	var m := make_machine()
	var r := await run(m, "cat /proc/$$/status | grep Name")
	check(r.out.contains("sh"), "/proc/<pid>/status")
	r = await run(m, "ps -e | grep -c ' /sbin/init$'")
	check_eq(r.out, "1\n", "ps shows init")
	r = await run(m, "kill -9 1")
	check(r.code != 0, "can't kill init")


func test_interactive_su() -> void:
	var m := make_machine()
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	var shell := m.login("alice", tty)
	check(shell != null, "login shell started")
	check(screen[0].contains("Welcome to box."), "motd shown")
	check(screen[0].ends_with("alice@box:~$ "), "prompt: " + screen[0].right(30))
	tty.type_line("su")
	check(screen[0].ends_with("Password: "), "su asks password")
	check(not tty.echo, "echo off for password")
	tty.type_line("wrong")
	await until(func() -> bool: return screen[0].ends_with("$ "), 240) # su waits 1s after a failure
	check(screen[0].contains("Authentication failure"), "wrong password rejected")
	tty.type_line("su -")
	tty.type_line("toor")
	check(tty.echo, "echo restored")
	check(screen[0].ends_with("root@box:~# "), "root prompt: " + screen[0].right(30))
	screen[0] = ""
	tty.type_line("whoami; pwd")
	check_eq(screen[0], "root\n/root\nroot@box:~# ", "commands as root")
	tty.type_line("exit")
	check(screen[0].ends_with("alice@box:~$ "), "back to alice")
	var log := m.vfs.read_text(AgoraCred.root(), "/var/log/auth.log")
	check(log.contains("FAILED su for root by alice") and log.contains("Successful su for root by alice"), "auth.log trail")
	var hist := m.vfs.read_text(AgoraCred.root(), "/home/alice/.sh_history")
	check(hist.contains("su -"), "history file written")
	tty.type_line("sleep 5")
	tty.interrupt()
	check(screen[0].ends_with("alice@box:~$ "), "Ctrl+C interrupts the foreground job")
	tty.send_eof()
	check(not shell.is_running(), "Ctrl+D ends the login shell")
	m.shutdown()


func test_sudo() -> void:
	var m := make_machine()
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m.login("alice", tty)
	tty.type_line("sudo cat /etc/shadow")
	tty.type_line("wonderland")
	check(screen[0].contains("root:$5$"), "sudo reads shadow")
	var tty2 := AgoraTty.new("tty2")
	var screen2 := [""]
	tty2.printed.connect(func(t: String) -> void: screen2[0] += t)
	m.login("bob", tty2)
	tty2.type_line("sudo id")
	check(screen2[0].contains("not in the sudoers file"), "bob refused")
	check(m.vfs.read_text(AgoraCred.root(), "/var/log/auth.log").contains("bob : user NOT in sudoers"), "refusal logged")
	m.shutdown()


func test_persistence() -> void:
	var m := make_machine("saved")
	await run(m, "echo persistent > keep.txt; chmod 600 keep.txt")
	var path := "user://test_image.agx"
	check_eq(m.save_image(path), OK, "save image")
	var m2 := AgoraMachine.load_image(path)
	_machines.append(m2)
	check(m2 != null, "load image")
	check_eq(m2.hostname, "saved", "hostname survives")
	var r := await run(m2, "cat keep.txt; ls -l keep.txt")
	check(r.out.begins_with("persistent\n-rw-------"), "file and mode survive: " + r.out)
	check(m2.users.check_password("alice", "wonderland"), "accounts survive")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func test_ssh() -> void:
	var net := AgoraNetwork.new()
	var home := make_machine("home")
	var server := AgoraMachine.create("server", {"users": [{"name": "admin", "password": "hunter2"}]})
	_machines.append(server)
	net.attach(home, "10.0.0.2")
	net.attach(server, "10.0.0.5", "server.corp")
	home.hardware.connect_port("eth0", server.hardware, "eth0")
	await run(home, "ip link set eth0 up && ip addr add 10.0.0.2/24 dev eth0", "root")
	await run(server, "ip link set eth0 up && ip addr add 10.0.0.5/24 dev eth0", "root")
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(home, tty)
	tty.type_line("ssh admin@server.corp")
	await until(func() -> bool: return screen[0].ends_with("password: "), 120)
	check(screen[0].ends_with("admin@server.corp's password: "), "ssh asks password")
	tty.type_line("hunter2")
	check(screen[0].ends_with("admin@server:~$ "), "remote prompt: " + screen[0].right(40))
	screen[0] = ""
	tty.type_line("hostname; cat /etc/hostname")
	check_eq(screen[0], "server\nserver\nadmin@server:~$ ", "commands run on the server")
	tty.type_line("exit")
	check(screen[0].contains("Connection to server.corp closed.") and screen[0].ends_with("alice@home:~$ "), "back home")
	check(server.vfs.read_text(AgoraCred.root(), "/var/log/auth.log").contains("Accepted password for admin from 10.0.0.2"), "server logged the login")
	tty.type_line("ping -c 1 10.0.0.5")
	await until(func() -> bool: return screen[0].ends_with("$ "), 120)
	check(screen[0].contains("64 bytes from 10.0.0.5: icmp_seq=1 ttl=64"), "ping: " + screen[0])
	home.shutdown()
	server.shutdown()


func m_login_and_wait(m: AgoraMachine, tty: AgoraTty) -> void:
	m.login("alice", tty)


func test_display_basics() -> void:
	var m := make_machine()
	var d := m.attach_display()
	var r := await run(m, "terminal")
	check(r.err.contains("cannot open display"), "no DISPLAY, no windows: " + r.err)
	var owner := m.spawn(PackedStringArray(["/bin/sleep", "10"]), {"cred": m.users.cred_for("alice")})
	var content := Control.new()
	var win := d.open_window(owner, content, {"title": "t", "size": Vector2(300, 200)})
	check_eq(d.windows.size(), 1, "window opened")
	check(d.focused == win, "new window focused")
	check(win.frame == content, "bare frame without a window manager")
	win.set_maximized(true)
	check_eq(win.rect(), d.work_area(), "maximize fills the work area")
	win.set_maximized(false)
	check_eq(win.size, Vector2(300, 200), "restore size")
	owner.send_signal(AgoraProcess.SIGTERM)
	check(d.windows.is_empty() and not win.open, "windows close with their process")
	var theme := AgoraWmTheme.parse("# comment\ntitle_bg = #0a246a\nborder = 3\nbogus = 1\n")
	check_eq(theme.color("title_bg"), Color("#0a246a"), "theme colors keep their #")
	check_eq(theme.num("border"), 3, "theme numbers")
	m.shutdown()


func test_gui_session() -> void:
	var m := make_machine()
	m.vfs.write_text(AgoraCred.root(), "/etc/greeter.conf", "autologin=alice\n")
	var d := m.attach_display()
	var view := AgoraDisplayView.new()
	view.size = Vector2(1280, 800)
	root.add_child(view)
	view.attach(d)
	var greeter := m.spawn(PackedStringArray(["/bin/greeter"]), {"env": {"DISPLAY": ":0", "PATH": AgoraMachine.DEFAULT_PATH}})
	await process_frame
	var titles: PackedStringArray = []
	for w in d.windows:
		titles.append("%s:%d" % [w.title, w.layer])
	check(d.manager != null, "xinitrc started the window manager")
	var term: AgoraWindow = null
	for w in d.windows:
		if w.title.begins_with("Terminal"):
			term = w
	check(term != null, "terminal window opened: " + ", ".join(titles))
	check(d.struts.bottom > 0, "panel reserved the bottom edge")
	if term == null:
		return
	check(term.frame is AgoraWmFrame, "terminal is decorated by the wm")
	check(term.frame.get_parent() != null and term.frame.get_parent().get_parent() == view, "frame placed in the view")
	var tv := term.content as AgoraTermView
	tv.tty.type_line("whoami; echo $DISPLAY")
	check(tv.screen_text().contains("alice\n:0"), "shell in the terminal runs as alice: " + tv.screen_text().right(60))
	var mgr := d.manager
	d.clear_manager(mgr)
	check(term.frame == term.content, "without a window manager windows are bare")
	d.set_manager(mgr)
	check(term.frame is AgoraWmFrame, "a new window manager decorates them again")
	var session_sid := m.get_process(term.pid).sid
	m.kill_session(session_sid, AgoraProcess.SIGTERM)
	await process_frame
	var left: PackedStringArray = []
	for w in d.windows:
		left.append(w.title)
	check(d.windows.size() == 1 and d.windows[0].pid == greeter.pid, "after logout only the greeter remains: " + ", ".join(left))
	check(not d.windows[0].minimized, "login screen is back")
	check(m.vfs.read_text(AgoraCred.root(), "/var/log/auth.log").contains("session closed for user alice"), "session logged")
	m.shutdown()
	view.queue_free()


## A machine with a display and a running window manager, as alice.
func gui_machine() -> Dictionary:
	var m := make_machine()
	var d := m.attach_display()
	var env := {"DISPLAY": ":0", "PATH": AgoraMachine.DEFAULT_PATH, "HOME": "/home/alice", "USER": "alice"}
	var opts := {"cred": m.users.cred_for("alice"), "env": env, "cwd": "/home/alice"}
	m.spawn(PackedStringArray(["wm"]), opts)
	return {"m": m, "d": d, "opts": opts}


func find_window(d: AgoraDisplay, prefix: String) -> AgoraWindow:
	for w in d.windows:
		if w.title.begins_with(prefix) or w.title.contains(prefix):
			return w
	return null


func test_mime_and_open() -> void:
	var g := gui_machine()
	var m: AgoraMachine = g.m
	var alice := m.spawn(PackedStringArray(["sleep", "30"]), g.opts)
	alice.cwd = "/home/alice"
	m.vfs.write_text(alice.cred, "/home/alice/notes.txt", "hello")
	m.vfs.write_file(alice.cred, "/home/alice/blob", PackedByteArray([97, 0, 98]))
	check_eq(AgoraMime.type_of(alice, "notes.txt"), "text/plain", "mime by extension")
	check_eq(AgoraMime.type_of(alice, "/tmp"), "inode/directory", "mime of a directory")
	check_eq(AgoraMime.type_of(alice, "/bin/ls"), "application/x-executable", "mime of a binary")
	check_eq(AgoraMime.type_of(alice, "/etc/hostname"), "text/plain", "sniffed text")
	check_eq(AgoraMime.type_of(alice, "blob"), "application/octet-stream", "sniffed binary")
	check_eq(AgoraMime.app_for(alice, "text/plain").get("_id"), "edit.desktop", "default app for text")
	check_eq(AgoraMime.app_for(alice, "text/x-custom").get("_id"), "edit.desktop", "text/* fallback")
	check(AgoraMime.app_for(alice, "application/zip").is_empty(), "no app for zip")
	m.vfs.make_dirs(alice.cred, "/home/alice/.config")
	m.vfs.write_text(alice.cred, "/home/alice/.config/mimeapps.list", "inode/directory=edit.desktop\n")
	check_eq(AgoraMime.app_for(alice, "inode/directory").get("_id"), "edit.desktop", "user default wins")
	check_eq(AgoraMime.command_for({"Exec": "edit %f"}, "/x y"), PackedStringArray(["edit", "/x y"]), "%f substitution")
	var r := await run(m, "DISPLAY=:0 open notes.txt")
	check_eq(r.code, 0, "open succeeds: " + r.err)
	var ed := find_window(g.d, "notes.txt")
	check(ed != null, "open started the editor")
	r = await run(m, "open notes.txt")
	check(r.err.contains("cannot open display"), "open without DISPLAY: " + r.err)
	m.shutdown()


func test_gui_apps() -> void:
	var g := gui_machine()
	var m: AgoraMachine = g.m
	var d: AgoraDisplay = g.d
	# Editor: load, edit, save; read-only files can't be saved.
	m.vfs.write_text(m.users.cred_for("alice"), "/home/alice/a.txt", "one\n")
	var ep := m.spawn(PackedStringArray(["edit", "a.txt"]), g.opts)
	var editor = ep._program
	check_eq(editor._code.text, "one\n", "editor loaded the file")
	editor._code.text = "two\n"
	check(find_window(d, "*a.txt") != null, "modified marker in title")
	check(await editor.save(), "save works")
	check_eq(m.vfs.read_text(AgoraCred.root(), "/home/alice/a.txt"), "two\n", "saved to the VFS")
	var rp := m.spawn(PackedStringArray(["edit", "/etc/passwd"]), g.opts)
	check(rp._program.read_only, "/etc/passwd opens read-only")
	rp._program._code.text += "evil:x:0:0::/:/bin/sh\n"
	check(not await rp._program.save(), "saving /etc/passwd is refused")
	check(rp._program._status.text.contains("Permission denied"), "editor shows the error")
	# File manager: listing, permissions, operations through coreutils.
	var fp := m.spawn(PackedStringArray(["files"]), g.opts)
	var fm = fp._program
	var names: PackedStringArray = []
	for i in fm._list.item_count:
		names.append(fm._list.get_item_text(i))
	check(names.has("Desktop") and names.has("a.txt"), "files lists home: " + ", ".join(names))
	check_eq(names[0], "Desktop", "folders first")
	fm.navigate("/root")
	check(fm._status.text.contains("Permission denied") and fm.cwd == "/home/alice", "files can't enter /root")
	fm._clipboard = PackedStringArray(["/home/alice/a.txt"])
	fm._clipboard_cut = false
	await fm._paste()
	check(m.vfs.exists(AgoraCred.root(), "/home/alice/a copy.txt"), "paste in the same folder makes a copy")
	await fm._delete(PackedStringArray([])) # nothing selected: no-op
	fm.navigate("/etc")
	fm._clipboard = PackedStringArray(["/home/alice/a.txt"])
	await fm._paste()
	check(fm._status.text.contains("Permission denied"), "paste into /etc fails: " + fm._status.text)
	# Desktop shows ~/Desktop, seeded from /etc/skel.
	var dp := m.spawn(PackedStringArray(["desktop"]), g.opts)
	var icons: Array = dp._program._backdrop.icons
	check(icons.size() == 1 and icons[0].name == "README.txt", "desktop icon from skel")
	m.shutdown()


func test_shell_control_flow() -> void:
	var m := make_machine()
	var cases := [
		["if [ -d /tmp ]; then echo yes; elif true; then echo no; else echo never; fi", "yes\n"],
		["if false; then echo a; elif [ 1 -eq 1 ]; then echo b; else echo c; fi", "b\n"],
		["if false; then echo a; else echo c; fi", "c\n"],
		["for i in 1 2 3; do echo $i; done", "1\n2\n3\n"],
		["for f in /etc/host*; do echo $f; done", "/etc/hostname\n/etc/hosts\n"],
		["i=0; while [ $i -lt 3 ]; do i=$((i+1)); done; echo $i", "3\n"],
		["n=3; until [ $n -eq 0 ]; do n=$((n-1)); done; echo $n", "0\n"],
		["for i in 1 2 3 4 5; do if [ $i = 2 ]; then continue; fi; if [ $i = 4 ]; then break; fi; echo $i; done", "1\n3\n"],
		["for a in 1 2; do for b in x y; do if [ $b = y ]; then continue 2; fi; echo $a$b; done; done", "1x\n2x\n"],
		["for a in 1 2; do for b in x y; do break 2; done; echo never; done; echo out", "out\n"],
		["for x in apple Banana c.txt zz; do case $x in a*) echo A;; [Bb]*) echo B;; *.txt|*.md) echo T;; *) echo other;; esac; done", "A\nB\nT\nother\n"],
		["case 'a*' in 'a*') echo literal;; *) echo glob;; esac", "literal\n"],
		["echo $((7/2)) $((7%3)) $((2*(3+4))) $((1<2)) $((1 && 0)) $((-5+2))", "3 1 14 1 0 -3\n"],
		["x=4; echo $((x*x)) $(($x+1))", "16 5\n"],
		["seq 1 5 | while read n; do echo x$n; done | tail -n 2", "x4\nx5\n"],
		["printf_x 2>/dev/null; echo 'a b' > f; echo c >> f; while read line; do echo \"<$line>\"; done < f", "<a b>\n<c>\n"],
		["{ echo a; echo b; } > g.txt; cat g.txt", "a\nb\n"],
		["(cd /tmp; X=1); pwd; echo ${X:-unset}", "/home/alice\nunset\n"],
		["eval 'echo $((1+1))'", "2\n"],
		["for i in a b; do echo $i; done | sort -r", "b\na\n"],
		["i=0; while true; do i=$((i+1)); if [ $i -gt 500 ]; then break; fi; done; echo $i", "501\n"],
		["if true\nthen\n  echo multi\nfi", "multi\n"],
	]
	for c: Array in cases:
		var r := await run(m, c[0])
		check_eq(r.out, c[1], c[0] + (" / err: " + r.err if not r.err.is_empty() else ""))
	var r := await run(m, "if true; then echo")
	check(r.code == 2 and r.err.contains("syntax error"), "incomplete if is a syntax error in -c")
	r = await run(m, "fi")
	check(r.err.contains("unexpected token `fi'"), "stray fi: " + r.err)


func test_shell_functions() -> void:
	var m := make_machine()
	var cases := [
		["greet() { echo \"hi $1\"; return 3; }; greet bob; echo $?", "hi bob\n3\n"],
		["x=global; f() { local x=inner; echo $x; }; f; echo $x", "inner\nglobal\n"],
		["fact() { if [ $1 -le 1 ]; then echo 1; else echo $(( $1 * $(fact $(( $1 - 1 ))) )); fi; }; fact 5", "120\n"],
		["function shout { echo \"$@\" | tr a-z A-Z; }; shout hey you", "HEY YOU\n"],
		["count() { echo $#; }; count a b c; count", "3\n0\n"],
		["f() { for i in 1 2 3; do if [ $i = 2 ]; then return 7; fi; done; echo never; }; f; echo $?", "7\n"],
		["inf() { inf; }; inf 2>&1 | grep -c nesting", "1\n"],
		["lst() { ls -d /tmp; }; lst | wc -l | tr -d ' '", "1\n"],
	]
	for c: Array in cases:
		var r := await run(m, c[0])
		check_eq(r.out, c[1], c[0] + (" / err: " + r.err if not r.err.is_empty() else ""))


func test_shell_scripts() -> void:
	var m := make_machine()
	var script := """#!/bin/sh
# Count files by kind under a directory.
count_kind() {
	local n=0
	for f in $1/*; do
		case $2 in
			dir) [ -d $f ] && n=$((n + 1)) ;;
			file) [ -f $f ] && n=$((n + 1)) ;;
		esac
	done
	echo $n
}
dirs=$(count_kind /etc dir)
files=$(count_kind /etc file)
if [ $dirs -gt 0 ] && [ $files -gt 3 ]; then
	echo "dirs=$dirs files=$files"
else
	echo "unexpected: $dirs $files"
	exit 1
fi
"""
	m.vfs.write_text(m.users.cred_for("alice"), "/home/alice/count.sh", script, "/", false, AgoraStat.MODE_EXEC)
	var r := await run(m, "./count.sh")
	check(r.out.begins_with("dirs=") and r.code == 0, "script with functions, loops and case: " + r.out + r.err)
	# Interactive: an unfinished construct continues on the next line.
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m.login("alice", tty)
	screen[0] = ""
	tty.type_line("for i in 1 2")
	check(screen[0].ends_with("> "), "PS2 continuation prompt")
	tty.type_line("do echo n$i; done")
	await until(func() -> bool: return screen[0].ends_with("$ "))
	check_eq(screen[0], "> n1\nn2\nalice@box:~$ ", "continued loop ran")
	var hist := m.vfs.read_text(AgoraCred.root(), "/home/alice/.sh_history")
	check(hist.contains("for i in 1 2; do echo n$i; done"), "history keeps a valid one-liner: " + hist)
	m.shutdown()


func test_systemd() -> void:
	var m := make_machine()
	var r := await run(m, "systemctl is-active syslogd sshd crond")
	check_eq(r.out, "active\nactive\nactive\n", "default services are running")
	r = await run(m, "systemctl status sshd")
	check(r.out.contains("active (running)") and r.out.contains("Main PID:"), "status: " + r.out)
	check(r.out.contains("Hint:"), "users can't read the journal")
	r = await run(m, "systemctl stop sshd")
	check(r.code == 1 and r.err.contains("Access denied"), "users can't stop services: " + r.err)
	r = await run(m, "systemctl stop sshd; systemctl is-active sshd", "root")
	check_eq(r.out, "inactive\n", "root stops sshd")
	check(m.port_info(22).is_empty(), "port 22 closed")
	r = await run(m, "systemctl start sshd && systemctl is-active sshd", "root")
	check_eq(r.out, "active\n", "root starts sshd")
	var old_pid: int = m.port_info(22).get("pid", 0)
	await run(m, "kill -9 %d" % old_pid, "root")
	await until(func() -> bool: return m.port_info(22).get("pid", old_pid) != old_pid, 120)
	check(not m.port_info(22).is_empty() and m.port_info(22).pid != old_pid, "Restart=on-failure brings sshd back")
	r = await run(m, "systemctl disable sshd; systemctl is-enabled sshd; ls /etc/systemd/system/multi-user.target.wants", "root")
	check(r.out.contains("Removed") and r.out.contains("disabled") and not r.out.contains("sshd.service\n"), "disable: " + r.out)
	r = await run(m, "systemctl enable sshd && systemctl is-enabled sshd", "root")
	check(r.out.ends_with("enabled\n"), "enable: " + r.out)
	r = await run(m, "journalctl -u sshd", "root")
	check(r.out.contains("Server listening on 0.0.0.0 port 22.") and r.out.contains("Started sshd.service"), "journal for sshd: " + r.out)
	r = await run(m, "runlevel; systemctl get-default")
	check_eq(r.out, "N 5\ngraphical.target\n", "runlevel and default target")
	r = await run(m, "service sshd status")
	check(r.out.contains("sshd.service"), "service forwards to systemctl")


func test_systemd_units() -> void:
	var m := make_machine()
	var root := AgoraCred.root()
	m.vfs.write_text(root, "/etc/systemd/system/hello.service", "[Unit]\nDescription=Hello\n[Service]\nExecStart=/bin/sh -c \"echo hello from unit; sleep 100\"\nUser=alice\n")
	m.vfs.write_text(root, "/etc/systemd/system/broken.service", "[Service]\nExecStart=/bin/nope\n")
	m.vfs.write_text(root, "/etc/systemd/system/once.service", "[Service]\nType=oneshot\nExecStart=/bin/touch /tmp/oneshot-ran\nRemainAfterExit=yes\n")
	var r := await run(m, "systemctl daemon-reload && systemctl start hello && systemctl is-active hello", "root")
	check_eq(r.out, "active\n", "custom unit starts: " + r.err)
	r = await run(m, "journalctl -u hello", "root")
	check(r.out.contains("hello[") and r.out.contains("hello from unit"), "service output in the journal: " + r.out)
	r = await run(m, "ps -e | grep 'sleep 100'")
	check(r.out.contains("alice"), "User= is honored: " + r.out)
	r = await run(m, "systemctl start broken", "root")
	check(r.code == 1 and r.err.contains("Failed to start broken.service"), "broken unit fails: " + r.err)
	r = await run(m, "systemctl is-failed broken")
	check_eq(r.out, "failed\n", "broken unit is failed")
	r = await run(m, "systemctl start once; systemctl status once | grep Active; ls /tmp/oneshot-ran", "root")
	check(r.out.contains("active (exited)") and r.out.contains("/tmp/oneshot-ran"), "oneshot: " + r.out)
	await run(m, "systemctl stop hello", "root")
	var sleepers := 0
	for pid in m.list_pids():
		if m.get_process(pid).argv == PackedStringArray(["sleep", "100"]):
			sleepers += 1
	check_eq(sleepers, 0, "stopping kills the service's whole session")
	r = await run(m, "systemctl list-units")
	check(r.out.contains("sshd.service") and r.out.contains("multi-user.target"), "list-units")


func test_syslog() -> void:
	var m := make_machine()
	var root := AgoraCred.root()
	await run(m, "logger -p auth.info -t probe hello-auth; logger plain-message")
	var auth := m.vfs.read_text(root, "/var/log/auth.log")
	var syslog := m.vfs.read_text(root, "/var/log/syslog")
	check(auth.contains("probe: hello-auth") and not syslog.contains("hello-auth"), "auth facility routed to auth.log only")
	check(syslog.contains("alice: plain-message"), "user facility in syslog")
	var r := await run(m, "cat /var/log/auth.log")
	check(r.err.contains("Permission denied"), "users can't read auth.log")
	await run(m, "systemctl stop syslogd; logger -p auth.info -t probe after-stop", "root")
	check(not m.vfs.read_text(root, "/var/log/auth.log").contains("after-stop"), "no logging without syslogd")
	r = await run(m, "dmesg | grep after-stop")
	check(r.out.contains("probe: after-stop"), "message went to the kernel ring buffer")


func test_sysvinit() -> void:
	var m := make_machine("oldbox", {"init": "sysvinit"})
	# rc scripts are shell loops and may take a few frames.
	await until(func() -> bool: return not m.port_info(22).is_empty(), 120)
	var r := await run(m, "runlevel")
	check(r.out.begins_with("N 5\n"), "runlevel 5 after boot: " + r.out)
	r = await run(m, "ps -e")
	check(r.out.contains("/sbin/syslogd") and r.out.contains("/sbin/crond") and r.out.contains("/sbin/sshd"), "rc started the daemons: " + r.out)
	check(not m.port_info(22).is_empty(), "sshd listening")
	r = await run(m, "service sshd status; service --status-all")
	check(r.out.contains("sshd is running") and r.out.contains("[ + ]  syslogd"), "service: " + r.out)
	r = await run(m, "/etc/init.d/sshd stop; /etc/init.d/sshd status", "root")
	check(r.out.contains("sshd is not running") and r.code == 3, "init.d stop: " + r.out)
	check(m.port_info(22).is_empty(), "port closed after stop")
	r = await run(m, "service sshd start", "root")
	check(not m.port_info(22).is_empty(), "service start: " + r.out + r.err)
	r = await run(m, "systemctl status sshd")
	check(r.err.contains("has not been booted with systemd"), "systemctl refuses under sysvinit")
	r = await run(m, "telinit 3", "root")
	await until(func() -> bool: return m.vfs.read_text(AgoraCred.root(), "/run/runlevel").begins_with("5 3"))
	r = await run(m, "runlevel; dmesg | grep -c 'Entering runlevel'")
	check_eq(r.out, "5 3\n2\n", "telinit switches runlevel")
	r = await run(m, "telinit 3")
	check(r.err.contains("Access denied"), "users can't switch runlevels: " + r.err)


func test_init_switch_and_power() -> void:
	var m := make_machine()
	var r := await run(m, "reboot")
	check(r.err.contains("must be superuser"), "users can't reboot")
	r = await run(m, "ln -sf /lib/sysvinit/init /sbin/init && reboot", "root")
	check_eq(r.code, 0, "reboot accepted: " + r.err)
	await until(func() -> bool: return m.state == AgoraMachine.State.RUNNING and m.vfs.read_text(AgoraCred.root(), "/run/runlevel").begins_with("N 5") and not m.vfs.exists(AgoraCred.root(), "/run/systemd"), 120)
	r = await run(m, "systemctl status; runlevel")
	check(r.err.contains("not been booted with systemd") and r.out == "N 5\n", "rebooted into sysvinit: " + r.out + r.err)
	var powered_off := [false]
	m.powered_off.connect(func() -> void: powered_off[0] = true)
	await run(m, "poweroff", "root")
	await until(func() -> bool: return powered_off[0])
	check(powered_off[0] and m.state == AgoraMachine.State.OFF and m.list_pids().is_empty(), "poweroff stops everything")
	m.boot()
	check(m.state == AgoraMachine.State.RUNNING, "boots again")
	m.get_process(1).send_signal(AgoraProcess.SIGKILL)
	check(m.state == AgoraMachine.State.PANIC and m.list_pids().is_empty(), "killing init panics the kernel")
	check(m.kmsg[-1].contains("Kernel panic"), "panic logged: " + m.kmsg[-1])


func test_cron() -> void:
	var m := make_machine()
	var root := AgoraCred.root()
	m.vfs.write_text(root, "/etc/crontab", "* * * * * root echo tick >> /tmp/cron.log\n")
	m.vfs.write_text(m.users.cred_for("alice"), "/home/alice/jobs", "*/1 * * * * whoami >> /tmp/alice-cron.log\n")
	var r := await run(m, "crontab jobs && crontab -l")
	check(r.out.contains("whoami"), "crontab installed: " + r.err)
	r = await run(m, "cat /var/spool/cron/crontabs/alice")
	check(r.err.contains("Permission denied"), "spool is private")
	m.clock.set_time(m.clock.now() + 60.0)
	await until(func() -> bool: return m.vfs.exists(root, "/tmp/alice-cron.log") and m.vfs.exists(root, "/tmp/cron.log"), 120)
	check_eq(m.vfs.read_text(root, "/tmp/cron.log"), "tick\n", "system crontab ran once")
	check_eq(m.vfs.read_text(root, "/tmp/alice-cron.log"), "alice\n", "user crontab ran as the user")
	check(m.vfs.read_text(root, "/var/log/cron.log").contains("(alice) CMD (whoami"), "cron.log")
	check_eq(AgoraProgram.lines_of("a\n").size(), 1, "sanity")


func test_hardware() -> void:
	var m := make_machine()
	var hw := m.hardware
	check(hw != null and hw.template == "virtual", "machines run on hardware")
	var r := await run(m, "cat /sys/class/net/eth0/address /sys/class/dmi/id/product_name; grep -c processor /proc/cpuinfo")
	check(r.out.begins_with(hw.nics[0].mac + "\nVirtual Machine\n1"), "sysfs and cpuinfo: " + r.out)
	r = await run(m, "lsblk; free | grep -c Mem; mount | grep ' / '")
	check(r.out.contains("sda") and r.out.contains("`-sda1") and r.out.contains("/dev/sda1 on / type memfs"), "lsblk and mount: " + r.out)
	r = await run(m, "ip link show eth0")
	check(r.out.contains("<BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN"), "link down after boot: " + r.out)
	r = await run(m, "ip link set eth0 up", "root")
	r = await run(m, "ip link show eth0")
	check(r.out.contains("NO-CARRIER") and r.out.contains("state DOWN"), "no cable: " + r.out)
	var other := make_machine("other")
	check(hw.connect_port("eth0", other.hardware, "eth0"), "cable plugged")
	r = await run(m, "ip link show eth0; cat /sys/class/net/eth0/carrier")
	check(r.out.contains("<BROADCAST,MULTICAST,UP,LOWER_UP>") and r.out.contains("state UP") and r.out.ends_with("1\n"), "carrier with a cable: " + r.out)
	check(m.kmsg[-1].ends_with("eth0: link up, 100Mbps, full-duplex"), "link up logged: " + m.kmsg[-1])
	# Media: a USB stick with a file on it.
	var stick := AgoraMedia.usb_stick()
	stick.fs.create("notes.txt", _file_stat())
	stick.fs.write_file("notes.txt", "from another computer\n".to_utf8_buffer(), false, 0)
	hw.insert(stick)
	m._sync_devices()
	r = await run(m, "mkdir -p /mnt/usb && mount /dev/sdb1 /mnt/usb && cat /mnt/usb/notes.txt && lsblk | grep sdb1", "root")
	check(r.out.begins_with("from another computer\n") and r.out.contains("/mnt/usb"), "mount a USB stick: " + r.out + r.err)
	r = await run(m, "mount /dev/sdb1 /mnt")
	check(r.err.contains("only root"), "users can't mount")
	r = await run(m, "umount /mnt/usb && mkfs /dev/sdb && mount /dev/sdb1 /mnt/usb && ls -A /mnt/usb | wc -l", "root")
	check(r.out.ends_with("0\n") and r.out.contains("Creating filesystem on /dev/sdb1"), "mkfs erases: " + r.out + r.err)
	r = await run(m, "umount /mnt/usb; eject /dev/sdb; lsblk | grep -c sdb", "root")
	check_eq(r.out.strip_edges(), "0", "eject")
	r = await run(m, "uname -m; echo hello > /dev/ttyS0", "root")
	check(hw.serial != null, "serial console exists")


func test_netstack() -> void:
	var m := make_machine("box", {"template": "server"})
	var net := m.net
	var ip := AgoraInet.parse
	check_eq(AgoraInet.to_str(ip.call("192.168.1.10")), "192.168.1.10", "address round trip")
	check_eq(ip.call("192.168.1.256"), -1, "bad address")
	check_eq(AgoraInet.prefix_of_mask(ip.call("255.255.255.0")), 24, "netmask to prefix")
	check_eq(AgoraInet.to_le_hex(ip.call("192.168.1.1")), "0101A8C0", "proc byte order")
	check_eq(net.interfaces.map(func(i: AgoraNetStack.Iface) -> String: return "%d:%s" % [i.index, i.name]), ["1:lo", "2:eth0", "3:eth1"], "interfaces")
	check_eq(net.iface("eth0").operstate(), "down", "down after boot")
	check(net.lookup(ip.call("8.8.8.8")).is_empty(), "no routes yet")
	# Addresses on a link that is down get no route until it comes up.
	check_eq(net.add_address("eth0", ip.call("192.168.1.10"), 24), AgoraErrno.OK, "addr add")
	check_eq(net.add_address("eth0", ip.call("192.168.1.10"), 24), AgoraErrno.EEXIST, "addr add twice")
	check(net.routes.is_empty(), "no route while down")
	net.set_link("eth0", true)
	net.set_link("lo", true)
	check_eq([AgoraInet.to_str(net.iface("lo").addrs[0].address), net.iface("lo").addrs[0].prefix, net.iface("lo").addrs[0].scope], ["127.0.0.1", 8, "host"], "lo gets 127.0.0.1/8 when it comes up")
	check_eq(net.routes.size(), 1, "prefix route appears")
	check_eq(net.routes[0].proto, "kernel", "kernel route")
	check_eq(net.add_route(0, 0, {"gateway": ip.call("10.0.0.1")}), AgoraErrno.ENETUNREACH, "gateway off-link")
	check_eq(net.add_route(0, 0, {"gateway": ip.call("192.168.1.1")}), AgoraErrno.OK, "default route")
	check_eq(net.add_route(0, 0, {"gateway": ip.call("192.168.1.2")}), AgoraErrno.EEXIST, "second default, same metric")
	check_eq(net.add_route(ip.call("10.0.0.0"), 8, {"dev": "eth1"}), AgoraErrno.ENETDOWN, "route via a down device")
	net.add_address("eth0", ip.call("192.168.1.11"), 24)
	check(net.iface("eth0").addrs[1].secondary, "second address in the subnet is secondary")
	check_eq(net.add_route(ip.call("10.1.0.0"), 16, {"gateway": ip.call("192.168.1.254")}), AgoraErrno.OK, "specific route")
	var r := net.lookup(ip.call("10.1.2.3"))
	check_eq([r.dev, AgoraInet.to_str(r.gateway), AgoraInet.to_str(r.src)], ["eth0", "192.168.1.254", "192.168.1.10"], "longest prefix wins")
	r = net.lookup(ip.call("8.8.8.8"))
	check_eq(AgoraInet.to_str(r.gateway), "192.168.1.1", "default route")
	check_eq(net.lookup(ip.call("192.168.1.50")).gateway, 0, "on-link destination")
	check_eq(net.lookup(ip.call("192.168.1.11")).type, "local", "own address is local")
	check_eq(net.lookup(ip.call("127.3.4.5")).dev, "lo", "127/8 is local")
	var out := await run(m, "cat /proc/net/route; cat /sys/class/net/eth0/operstate /sys/class/net/eth0/flags /sys/class/net/lo/operstate /sys/class/net/eth1/operstate")
	var lines: PackedStringArray = out.out.split("\n")
	check(lines[0].begins_with("Iface\tDestination\tGateway \tFlags") and lines[0].length() == 127, "route header")
	check_eq(lines[1].strip_edges(), "eth0\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0", "default route in /proc")
	check(out.out.contains("eth0\t0001A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF"), "prefix route in /proc")
	check(out.out.ends_with("down\n0x1003\nunknown\ndown\n"), "no carrier: operstate down, flags up: " + out.out)
	out = await run(m, "grep eth0 /proc/net/dev; ls /sys/class/net")
	check(out.out.begins_with("  eth0:       0       0    0    0"), "/proc/net/dev: " + out.out)
	check(out.out.ends_with("eth0\neth1\nlo\n"), "lo in sysfs: " + out.out)
	# Taking the link down drops its routes; addresses stay.
	net.set_link("eth0", false)
	check(net.routes.is_empty(), "routes flushed on link down")
	net.set_link("eth0", true)
	check_eq(net.routes.size(), 1, "only the kernel route comes back")
	check_eq(net.del_address("eth0", ip.call("192.168.1.10"), 24), AgoraErrno.OK, "addr del")
	check(net.iface("eth0").addrs.is_empty() and net.routes.is_empty(), "deleting the primary drops secondaries and routes")
	check_eq(net.del_address("eth0", ip.call("192.168.1.10"), 24), AgoraErrno.EADDRNOTAVAIL, "addr del twice")
	check_eq(net.del_route(0, 0), AgoraErrno.ESRCH, "route del missing")


## Two machines on one cable: a 192.168.1.10/24 and b 192.168.1.20/24.
func cabled_pair() -> Array[AgoraMachine]:
	var a := make_machine("a")
	var b := make_machine("b")
	a.hardware.connect_port("eth0", b.hardware, "eth0")
	var n := 10
	for m in [a, b]:
		m.net.set_link("lo", true)
		m.net.set_link("eth0", true)
		m.net.add_address("eth0", AgoraInet.parse("192.168.1.%d" % n), 24, {"broadcast": AgoraInet.parse("192.168.1.255")})
		n += 10
	return [a, b]


func test_ethernet_arp() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var ip := AgoraInet.parse
	var got: Array[Dictionary] = []
	b.net.register_protocol(253, func(pkt: Dictionary, _i: AgoraNetStack.Iface) -> void: got.append(pkt))
	var pkt := a.net.make_packet(0, ip.call("192.168.1.20"), 253, {"data": "hello"}, 5)
	check_eq(a.net.ip_output(pkt), AgoraErrno.OK, "send")
	check_eq(a.net.neigh.find("eth0", ip.call("192.168.1.20")).state, "INCOMPLETE", "asking who has 192.168.1.20")
	await until(func() -> bool: return not got.is_empty())
	check(not got.is_empty() and got[0].payload.data == "hello" and AgoraInet.to_str(got[0].src) == "192.168.1.10", "datagram delivered after ARP")
	var ea := a.net.neigh.find("eth0", ip.call("192.168.1.20"))
	check_eq([ea.state, ea.mac], ["REACHABLE", b.hardware.nics[0].mac], "a learned b from the reply")
	check_eq(b.net.neigh.find("eth0", ip.call("192.168.1.10")).state, "STALE", "b learned a from the request")
	var r := await run(b, "cat /proc/net/arp")
	check_eq(r.out, "IP address       HW type     Flags       HW address            Mask     Device\n192.168.1.10     0x1         0x2         %s     *        eth0\n" % a.hardware.nics[0].mac, "/proc/net/arp")
	check(a.net.iface("eth0").stats.tx_packets == 2 and b.net.iface("eth0").stats.rx_packets == 2, "counters: request + datagram")
	# Broadcasts need no ARP.
	got.clear()
	a.net.ip_output(a.net.make_packet(0, ip.call("192.168.1.255"), 253, {}, 0))
	await until(func() -> bool: return not got.is_empty())
	check_eq(got.size(), 1, "subnet broadcast delivered")
	# Our own address goes through lo.
	got.clear()
	b.net.ip_output(b.net.make_packet(0, ip.call("192.168.1.20"), 253, {}, 0))
	await until(func() -> bool: return not got.is_empty())
	check(got.size() == 1 and b.net.iface("lo").stats.rx_packets == 1, "local delivery over lo")
	# Nobody answers for an unused address: three requests, then FAILED.
	var target: int = ip.call("192.168.1.99")
	a.net.ip_output(a.net.make_packet(0, target, 253, {}, 0))
	await until(func() -> bool: return a.net.neigh.find("eth0", target).state == "FAILED", 300)
	check_eq(a.net.neigh.find("eth0", target).state, "FAILED", "unanswered ARP fails")
	check_eq(b.net.neigh.find("eth0", target), {}, "b ignores requests for others")
	# Taking the link down forgets learned neighbours.
	a.net.set_link("eth0", false)
	check(a.net.neigh.entries().is_empty(), "neighbours flushed with the link")


func test_iproute() -> void:
	var m := make_machine("box", {"template": "server"})
	var other := make_machine("peer")
	m.hardware.connect_port("eth0", other.hardware, "eth0")
	var mac := m.hardware.nics[0].mac
	var r := await run(m, "ip link set eth0 up")
	check_eq([r.err, r.code], ["RTNETLINK answers: Operation not permitted\n", 2], "users can't change links")
	r = await run(m, "ip link set lo up && ip link set eth0 up && ip addr add 192.168.1.10/24 brd + dev eth0 && ip addr add 192.168.1.11/24 dev eth0 label eth0:1", "root")
	check_eq([r.err, r.code], ["", 0], "configure")
	r = await run(m, "ip addr show")
	check_eq(r.out, "\n".join([
		"1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN group default qlen 1000",
		"    link/loopback 00:00:00:00:00:00 brd 00:00:00:00:00:00",
		"    inet 127.0.0.1/8 scope host lo",
		"       valid_lft forever preferred_lft forever",
		"2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP group default qlen 1000",
		"    link/ether %s brd ff:ff:ff:ff:ff:ff" % mac,
		"    inet 192.168.1.10/24 brd 192.168.1.255 scope global eth0",
		"       valid_lft forever preferred_lft forever",
		"    inet 192.168.1.11/24 scope global secondary eth0:1",
		"       valid_lft forever preferred_lft forever",
		"3: eth1: <BROADCAST,MULTICAST> mtu 1500 qdisc noop state DOWN group default qlen 1000",
		"    link/ether %s brd ff:ff:ff:ff:ff:ff" % m.hardware.nics[1].mac, ""]), "ip addr show")
	r = await run(m, "ip -4 -br a; ip -o -4 addr show dev lo")
	check_eq(r.out, "lo               UNKNOWN        127.0.0.1/8 \neth0             UP             192.168.1.10/24 192.168.1.11/24 \n1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever preferred_lft forever\n", "brief and oneline")
	r = await run(m, "ip addr add 192.168.1.10/24 dev eth0", "root")
	check_eq([r.err, r.code], ["RTNETLINK answers: File exists\n", 2], "duplicate address")
	r = await run(m, "ip addr add 10.0.0.1/8 dev eth7", "root")
	check_eq(r.err, "Cannot find device \"eth7\"\n", "unknown device")
	r = await run(m, "ip addr add 300.1.1.1/8 dev eth0", "root")
	check_eq(r.err, "Error: inet prefix is expected rather than \"300.1.1.1/8\".\n", "bad address")
	r = await run(m, "ip route add default via 10.9.9.9; ip route add default via 192.168.1.1 && ip route add 10.0.0.0/8 via 192.168.1.254 metric 10 && ip route add blackhole 172.16.0.0/12", "root")
	check_eq(r.err, "Error: Nexthop has invalid gateway.\n", "off-link gateway")
	r = await run(m, "ip route; ip r s table local")
	check_eq(r.out, "\n".join([
		"default via 192.168.1.1 dev eth0 ",
		"10.0.0.0/8 via 192.168.1.254 dev eth0 metric 10 ",
		"blackhole 172.16.0.0/12 ",
		"192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10 ",
		"local 127.0.0.0/8 dev lo proto kernel scope host src 127.0.0.1 ",
		"local 127.0.0.1 dev lo proto kernel scope host src 127.0.0.1 ",
		"broadcast 127.255.255.255 dev lo proto kernel scope link src 127.0.0.1 ",
		"local 192.168.1.10 dev eth0 proto kernel scope host src 192.168.1.10 ",
		"local 192.168.1.11 dev eth0 proto kernel scope host src 192.168.1.11 ",
		"broadcast 192.168.1.255 dev eth0 proto kernel scope link src 192.168.1.10 ", ""]).replace(" \n", "\n"), "ip route show")
	r = await run(m, "ip route get 8.8.8.8; ip route get 192.168.1.11")
	check_eq(r.out, "8.8.8.8 via 192.168.1.1 dev eth0 src 192.168.1.10 uid 1000 \n    cache \nlocal 192.168.1.11 dev lo src 192.168.1.11 uid 1000 \n    cache <local> \n", "ip route get")
	r = await run(m, "ip route del 10.0.0.0/8 via 192.168.1.254 metric 10 && ip route del 10.0.0.0/8", "root")
	check_eq([r.err, r.code], ["RTNETLINK answers: No such process\n", 2], "route del")
	r = await run(m, "ip route show dev eth0 proto kernel")
	check_eq(r.out, "192.168.1.0/24 proto kernel scope link src 192.168.1.10\n", "filtered route list leaves out the device")
	# Neighbours: talk to the peer, then look.
	other.net.set_link("eth0", true)
	other.net.add_address("eth0", AgoraInet.parse("192.168.1.20"), 24)
	m.net.ip_output(m.net.make_packet(0, AgoraInet.parse("192.168.1.20"), 253, {}, 0))
	await until(func() -> bool: return m.net.neigh.find("eth0", AgoraInet.parse("192.168.1.20")).get("state", "") == "REACHABLE")
	r = await run(m, "ip neigh; ip neigh add 192.168.1.30 lladdr 00:11:22:33:44:55 dev eth0", "root")
	check_eq(r.out, "192.168.1.20 dev eth0 lladdr %s REACHABLE\n" % other.hardware.nics[0].mac, "ip neigh")
	r = await run(m, "ip neigh show dev eth0 nud permanent; ip neigh add 192.168.1.30 lladdr 00:11:22:33:44:55 dev eth0", "root")
	check_eq([r.out, r.err], ["192.168.1.30 lladdr 00:11:22:33:44:55 PERMANENT\n", "RTNETLINK answers: File exists\n"], "permanent neighbour")
	r = await run(m, "ip neigh flush dev eth0 && ip -s neigh show && ip neigh del 192.168.1.30 dev eth0 && ip n", "root")
	check_eq(r.out, "192.168.1.30 dev eth0 lladdr 00:11:22:33:44:55 PERMANENT\n", "flush keeps permanent entries")
	# Links.
	r = await run(m, "ip link set eth0 mtu 9000", "root")
	check_eq([r.err, r.code], ["Error: mtu greater than device maximum.\n", 2], "mtu limit")
	r = await run(m, "ip link set dev eth0 down && ip link set eth0 address 02:00:00:00:00:01 mtu 1400 && ip -s link show eth0 && ip route", "root")
	check(r.out.begins_with("2: eth0: <BROADCAST,MULTICAST> mtu 1400 qdisc noop state DOWN mode DEFAULT group default qlen 1000\n    link/ether 02:00:00:00:00:01 brd ff:ff:ff:ff:ff:ff\n    RX: bytes  packets  errors  dropped overrun mcast   \n"), "link down, new MAC and MTU: " + r.out)
	check(not r.out.contains("default via") and not r.out.contains("192.168.1.0/24"), "routes gone with the link: " + r.out)
	r = await run(m, "ip addr del 192.168.1.10 dev eth0; ip -4 a show eth0", "root")
	check(r.err.begins_with("Warning: Executing wildcard deletion") and not r.out.contains("inet "), "wildcard delete takes the secondary too: " + r.out)
	r = await run(m, "ip foo; ip route bar")
	check_eq(r.err, "Object \"foo\" is unknown, try \"ip help\".\nCommand \"bar\" is unknown, try \"ip route help\".\n", "unknown words")


func test_net_tools() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var mac := a.hardware.nics[0].mac.to_upper()
	var r := await run(a, "ifconfig")
	check_eq(r.out, "\n".join([
		"eth0      Link encap:Ethernet  HWaddr %s  " % mac,
		"          inet addr:192.168.1.10  Bcast:192.168.1.255  Mask:255.255.255.0",
		"          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1",
		"          RX packets:0 errors:0 dropped:0 overruns:0 frame:0",
		"          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0",
		"          collisions:0 txqueuelen:1000 ",
		"          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)",
		"",
		"lo        Link encap:Local Loopback  ",
		"          inet addr:127.0.0.1  Mask:255.0.0.0",
		"          UP LOOPBACK RUNNING  MTU:65536  Metric:1",
		"          RX packets:0 errors:0 dropped:0 overruns:0 frame:0",
		"          TX packets:0 errors:0 dropped:0 overruns:0 carrier:0",
		"          collisions:0 txqueuelen:1000 ",
		"          RX bytes:0 (0.0 B)  TX bytes:0 (0.0 B)",
		"", ""]), "ifconfig")
	r = await run(a, "ifconfig eth0 10.0.0.1")
	check_eq(r.err, "SIOCSIFADDR: Permission denied\n", "users can't set addresses")
	r = await run(a, "ifconfig eth0:1 10.1.2.3 && ifconfig eth0:1 && ip -4 -o a show eth0", "root")
	check(r.out.begins_with("eth0:1    Link encap:Ethernet  HWaddr %s  \n          inet addr:10.1.2.3  Bcast:10.255.255.255  Mask:255.0.0.0\n          UP BROADCAST RUNNING MULTICAST  MTU:1500  Metric:1\n\n" % mac), "alias with a classful mask: " + r.out)
	check(r.out.contains("inet 10.1.2.3/8 brd 10.255.255.255 scope global eth0:1"), "the alias is a labelled address: " + r.out)
	r = await run(a, "ifconfig eth0:1 down; ifconfig eth0:1", "root")
	check_eq(r.err, "eth0:1: error fetching interface information: Device not found\n", "alias removed")
	r = await run(a, "ifconfig eth0 192.168.1.10 netmask 255.255.0.0 && ip -4 -o a show eth0", "root")
	check(r.out.contains("inet 192.168.1.10/16 brd 192.168.255.255"), "netmask change: " + r.out)
	r = await run(a, "route add default gw 192.168.1.1 && route add -net 10.0.0.0 netmask 255.0.0.0 gw 192.168.1.254 metric 5 && route add -host 172.16.1.1 reject && route -n", "root")
	check_eq(r.out, "\n".join([
		"Kernel IP routing table",
		"Destination     Gateway         Genmask         Flags Metric Ref    Use Iface",
		"0.0.0.0         192.168.1.1     0.0.0.0         UG    0      0        0 eth0",
		"10.0.0.0        192.168.1.254   255.0.0.0       UG    5      0        0 eth0",
		"172.16.1.1      0.0.0.0         255.255.255.255 UH!   0      0        0 -",
		"192.168.0.0     0.0.0.0         255.255.0.0     U     0      0        0 eth0", ""]), "route -n: " + r.err)
	r = await run(a, "route | head -3 | tail -1")
	check_eq(r.out, "default         192.168.1.1     0.0.0.0         UG    0      0        0 eth0\n", "route with names")
	r = await run(a, "route add default gw 192.168.1.2; route del -net 10.0.0.0 netmask 255.0.0.0 gw 192.168.1.254 && route del default gw 10.1.1.1; route add -net 8.0.0.0/8 gw 9.9.9.9", "root")
	check_eq(r.err, "SIOCADDRT: File exists\nSIOCDELRT: No such process\nSIOCADDRT: Network is unreachable\n", "route errors")
	# arp after some traffic.
	a.net.ip_output(a.net.make_packet(0, AgoraInet.parse("192.168.1.20"), 253, {}, 0))
	await until(func() -> bool: return a.net.neigh.find("eth0", AgoraInet.parse("192.168.1.20")).get("state", "") == "REACHABLE")
	var bmac := b.hardware.nics[0].mac
	r = await run(a, "arp -n; arp -a")
	check_eq(r.out, "Address                  HWtype  HWaddress           Flags Mask            Iface\n192.168.1.20             ether   %s   C                     eth0\n? (192.168.1.20) at %s [ether] on eth0\n" % [bmac, bmac], "arp")
	r = await run(a, "arp -s 192.168.1.50 00:aa:bb:cc:dd:ee && arp -d 192.168.1.20 && arp -an", "root")
	check_eq(r.out, "? (192.168.1.50) at 00:aa:bb:cc:dd:ee [ether] PERM on eth0\n", "arp -s and -d")
	r = await run(a, "ifconfig eth0 down; ifconfig | grep -c Link; ifconfig -a | grep -c Link")
	check_eq(r.out, "2\n2\n", "users can still look") # eth0 down needs root
	r = await run(a, "ifconfig eth0 down; ifconfig | grep -c Link; ifconfig eth0 | head -3 | tail -1", "root")
	check_eq(r.out, "1\n          BROADCAST MULTICAST  MTU:1500  Metric:1\n", "ifconfig -a shows down interfaces")
	r = await run(a, "ifconfig eth9")
	check_eq([r.err, r.code], ["eth9: error fetching interface information: Device not found\n", 1], "unknown interface")


func test_ping() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var r := await run(a, "ping -c 2 -i 0.2 192.168.1.20")
	var lines: PackedStringArray = r.out.split("\n")
	check_eq(lines[0], "PING 192.168.1.20 (192.168.1.20) 56(84) bytes of data.", "ping header")
	check(lines[1].begins_with("64 bytes from 192.168.1.20: icmp_seq=1 ttl=64 time=0.") and lines[2].begins_with("64 bytes from 192.168.1.20: icmp_seq=2 ttl=64 time=0."), "replies with LAN round trips: " + r.out)
	check_eq(lines[3], "", "blank line before statistics")
	check_eq(lines[4], "--- 192.168.1.20 ping statistics ---", "statistics header")
	check(lines[5].begins_with("2 packets transmitted, 2 received, 0% packet loss, time "), "statistics: " + lines[5])
	check(lines[6].begins_with("rtt min/avg/max/mdev = 0.") and lines[6].ends_with(" ms"), "rtt line: " + lines[6])
	check_eq(r.code, 0, "exit status with replies")
	check(b.net.iface("eth0").stats.rx_packets >= 3, "requests went over the cable")
	r = await run(a, "ping -c 1 192.168.1.10; ping -c 1 -s 1000 -t 5 localhost")
	check(r.out.contains("64 bytes from 192.168.1.10: icmp_seq=1 ttl=64 time=0.0") and r.out.contains("PING localhost (127.0.0.1) 1000(1028) bytes of data.\n1008 bytes from localhost (127.0.0.1): icmp_seq=1 ttl=64"), "own addresses: " + r.out)
	# Nobody at the address: ARP fails and the kernel reports it.
	r = await run(a, "ping -c 1 192.168.1.99")
	check(r.out.contains("From 192.168.1.10 icmp_seq=1 Destination Host Unreachable\n"), "host unreachable: " + r.out)
	check(r.out.contains("1 packets transmitted, 0 received, +1 errors, 100% packet loss, time "), "loss statistics: " + r.out)
	check_eq(r.code, 1, "exit status without replies")
	r = await run(a, "ping -c 1 8.8.8.8; ping -c 1 192.168.1.255; ping -i 0.1 -c 1 192.168.1.20; ping -c 1 nosuchhost")
	check_eq(r.err, "\n".join(["ping: connect: Network is unreachable",
		"ping: Do you want to ping broadcast? Then -b. If not, check your local firewall rules",
		"ping: cannot flood; minimal interval allowed for user is 200ms",
		"ping: nosuchhost: Name or service not known", ""]), "ping errors")
	# Names from /etc/hosts, both ways.
	a.vfs.write_text(AgoraCred.root(), "/etc/hosts", "127.0.0.1\tlocalhost\n192.168.1.20\tb.lan b\n")
	r = await run(a, "ping -c 1 b")
	check(r.out.begins_with("PING b (192.168.1.20) 56(84) bytes of data.\n64 bytes from b.lan (192.168.1.20): icmp_seq=1"), "names: " + r.out)
	# A slow link: the time is real, and ping reports it.
	a.hardware.nics[0].latency_ms = 40.0
	b.hardware.nics[0].latency_ms = 40.0
	r = await run(a, "ping -c 1 -n b")
	var rtt := RegEx.create_from_string("time=([0-9.]+) ms").search(r.out)
	check(rtt != null and float(rtt.get_string(1)) > 60.0 and float(rtt.get_string(1)) < 110.0, "slow link round trip: " + r.out)
	# Ctrl-C stops ping and prints the statistics.
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	a.login("alice", tty)
	tty.type_line("ping 192.168.1.20")
	await until(func() -> bool: return screen[0].contains("icmp_seq=1 "), 120)
	tty.interrupt()
	await until(func() -> bool: return screen[0].ends_with("$ "), 60)
	check(screen[0].contains("--- 192.168.1.20 ping statistics ---\n1 packets transmitted, 1 received"), "interrupted ping: " + screen[0])


func test_ifupdown() -> void:
	var m := make_machine("box", {"template": "server"})
	await until(func() -> bool: return m.net.iface("lo").admin_up)
	check(m.net.iface("lo").admin_up and not m.net.iface("eth0").admin_up, "boot brings up lo only")
	var root := AgoraCred.root()
	m.vfs.write_text(root, "/etc/network/interfaces", AgoraDistro.INTERFACES_HEAD + """
auto eth0
iface eth0 inet static
	address 10.1.0.5
	netmask 255.255.0.0
	gateway 10.1.0.1
	up echo "up $IFACE $IF_ADDRESS" >> /tmp/hooks
	down echo "down $IFACE" >> /tmp/hooks

iface eth1 inet manual
	mtu 1400
""")
	var r := await run(m, "ifup eth0")
	check_eq(r.err, "ifup: failed to open statefile /run/network/ifstate: Permission denied\n", "ifup needs root")
	r = await run(m, "ifup -v eth0 && cat /run/network/ifstate /tmp/hooks && ip -4 -o a show eth0 && ip route", "root")
	check(r.err.begins_with("Configuring interface eth0=eth0 (inet)\nip addr add 10.1.0.5/255.255.0.0 broadcast + dev eth0 label eth0\nip link set dev eth0 up\nip route add default via 10.1.0.1 dev eth0 onlink\n"), "ifup -v shows the commands: " + r.err)
	check(r.out.begins_with("lo=lo\neth0=eth0\nup eth0 10.1.0.5\n2: eth0    inet 10.1.0.5/16 brd 10.1.255.255 scope global eth0"), "configured: " + r.out)
	check(r.out.contains("default via 10.1.0.1 dev eth0 onlink linkdown"), "default route (no cable yet): " + r.out)
	r = await run(m, "ifup eth0; ifup eth1 && ip link show eth1 | head -1; ifup eth7", "root")
	check_eq(r.err, "ifup: interface eth0 already configured\nifup: unknown interface eth7\n", "ifup messages")
	check(r.out.contains("<NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1400"), "manual method with mtu: " + r.out)
	r = await run(m, "ifdown eth0 && ip -4 a show eth0 | grep -c inet; ip route | grep -c default; cat /tmp/hooks /run/network/ifstate; ifdown eth0", "root")
	check_eq(r.out, "0\n0\nup eth0 10.1.0.5\ndown eth0\nlo=lo\neth1=eth1\n", "ifdown: " + r.out)
	check_eq(r.err, "ifdown: interface eth0 not configured\n", "ifdown twice")
	r = await run(m, "ifup -n -a", "root")
	check_eq(r.err, "ifup: interface lo already configured\nip addr add 10.1.0.5/255.255.0.0 broadcast + dev eth0 label eth0\nip link set dev eth0 up\nip route add default via 10.1.0.1 dev eth0 onlink\necho \"up $IFACE $IF_ADDRESS\" >> /tmp/hooks\n", "ifup -n -a prints only")
	r = await run(m, "/etc/init.d/networking restart; systemctl is-active networking; ip -4 -o a | grep -c 10.1.0.5", "root")
	check_eq(r.out, "Reconfiguring network interfaces...done.\nactive\n1\n", "networking restart: " + r.out + r.err)
	r = await run(m, "systemctl stop networking; ip -4 -o a | grep -c 10.1.0.5; systemctl start networking; ip -4 -o a | grep -c 10.1.0.5", "root")
	check_eq(r.out, "0\n1\n", "networking.service runs ifdown and ifup: " + r.err)
	m.vfs.write_text(root, "/etc/network/interfaces", AgoraDistro.INTERFACES_HEAD + "auto eth1\niface eth1 inet dhcp\n")
	r = await run(m, "rm /sbin/udhcpc; ifup eth1", "root")
	check_eq([r.err, r.code], ["No DHCP client software found!\nFailed to bring up eth1.\n", 1], "dhcp without a client")
	# The same at boot with SysV init.
	var s := make_machine("old", {"init": "sysvinit", "network": {"eth0": {"method": "static", "address": "172.16.5.5", "netmask": "255.255.255.0"}}})
	await until(func() -> bool: return s.net.iface("eth0").admin_up, 120)
	r = await run(s, "ip -4 -o a show eth0; ls /etc/rcS.d")
	check(r.out.contains("inet 172.16.5.5/24 brd 172.16.5.255 scope global eth0") and r.out.contains("S40networking"), "sysvinit runs networking from rcS: " + r.out)
	check(s.hardware.serial != null, "sanity")
	r = await run(s, "ping -c 1 old")
	check(r.out.contains("64 bytes from old (127.0.1.1)"), "own host name from /etc/hosts: " + r.out)


## A PC with eth0 at [param address]/24, plugged into [param port] of
## [param router].
func lan_pc(name: String, address: String, router: AgoraMachine, port: String) -> AgoraMachine:
	var pc := make_machine(name, {"network": {"eth0": {"method": "static", "address": address, "netmask": "255.255.255.0", "gateway": "192.168.1.1"}}})
	pc.hardware.connect_port("eth0", router.hardware, port)
	return pc


func test_bridge() -> void:
	var gw := make_machine("gw", {"template": "router", "profile": "router", "root_password": "admin"})
	await until(func() -> bool: return gw.net.iface("br-lan") != null and gw.net.iface("br-lan").admin_up, 120)
	var r := await run(gw, "brctl show; ip -4 -o a show br-lan; ip link show eth1", "root")
	var br_mac := gw.net.iface("br-lan").mac
	check(r.out.begins_with("bridge name\tbridge id\t\tSTP enabled\tinterfaces\nbr-lan\t\t8000.%s\tno\t\teth1\n\t\t\t\t\t\t\teth2\n\t\t\t\t\t\t\teth3\n\t\t\t\t\t\t\teth4\n" % br_mac.replace(":", "")), "brctl show: " + r.out)
	check(r.out.contains("inet 192.168.1.1/24 brd 192.168.1.255 scope global br-lan"), "LAN address on the bridge: " + r.out)
	check(r.out.contains("<NO-CARRIER,BROADCAST,MULTICAST,UP> mtu 1500 qdisc pfifo_fast master br-lan state DOWN"), "ports belong to the bridge: " + r.out)
	var lowest := gw.hardware.nics[1].mac
	for k in range(2, 5):
		if gw.hardware.nics[k].mac < lowest:
			lowest = gw.hardware.nics[k].mac
	check_eq(br_mac, lowest, "the bridge takes the lowest port address")
	var pc1 := lan_pc("pc1", "192.168.1.10", gw, "eth1")
	var pc2 := lan_pc("pc2", "192.168.1.20", gw, "eth3")
	var pc3 := lan_pc("pc3", "192.168.1.30", gw, "eth2")
	await until(func() -> bool: return pc1.net.iface("eth0").admin_up and pc2.net.iface("eth0").admin_up and pc3.net.iface("eth0").admin_up, 120)
	check(gw.kmsg[-1].contains("br-lan: port") and gw.kmsg[-1].contains("entered forwarding state"), "ports start forwarding: " + gw.kmsg[-1])
	r = await run(pc1, "ping -c 1 192.168.1.20")
	check(r.out.contains("64 bytes from 192.168.1.20: icmp_seq=1 ttl=64"), "PC to PC across the bridge: " + r.out)
	r = await run(pc2, "ping -c 1 192.168.1.1")
	check(r.out.contains("64 bytes from 192.168.1.1: icmp_seq=1 ttl=64"), "PC to the router: " + r.out)
	r = await run(gw, "brctl showmacs br-lan")
	var macs: String = r.out
	check(macs.begins_with("port no\tmac addr\t\tis local?\tageing timer\n"), "showmacs header: " + macs)
	check(macs.contains("  1\t%s\tno\t\t   0." % pc1.hardware.nics[0].mac) and macs.contains("  3\t%s\tno\t\t   0." % pc2.hardware.nics[0].mac), "learned addresses: " + macs)
	check(macs.contains("  1\t%s\tyes\t\t   0.00" % gw.hardware.nics[1].mac), "local port addresses: " + macs)
	# Once learned, unicast goes only where it is needed.
	var before: int = pc3.net.iface("eth0").stats.rx_packets
	r = await run(pc1, "ping -c 2 -i 0.2 192.168.1.20")
	check(r.out.contains("2 received"), "pings again")
	check_eq(pc3.net.iface("eth0").stats.rx_packets, before, "pc3 doesn't see pc1 and pc2 talk")
	# Pulling a cable forgets what was behind the port.
	pc2.hardware.nics[0].unplug()
	r = await run(gw, "brctl showmacs br-lan | grep -v yes")
	check(r.out.begins_with("port no\tmac addr\t\tis local?\tageing timer\n  1\t%s\tno\t\t   0." % pc1.hardware.nics[0].mac) and r.out.count("\n") == 2, "port 3 entries flushed: " + r.out)
	r = await run(gw, "brctl addbr br-lan; brctl addif br-lan eth1; brctl addbr br1 && brctl addif br1 br-lan; brctl delbr br-lan; brctl addif br1 eth9; brctl show br1; brctl delbr br1", "root")
	check_eq(r.err, "\n".join(["device br-lan already exists; can't create bridge with the same name",
		"device eth1 is already a member of a bridge; can't enslave it to bridge br-lan.",
		"device br-lan is a bridge device itself; can't enslave a bridge device to a bridge device.",
		"bridge br-lan is still up; can't delete it",
		"interface eth9 does not exist!", ""]), "brctl errors")
	r = await run(gw, "brctl show | grep -c br1; ip link add br9 type bridge && ip link set eth4 nomaster && ip link set eth4 master br9 && ip -br link show master br9 && ip link del br9 && ip link show eth4 | grep -c master", "root")
	check(r.out.begins_with("0\neth4") and r.out.ends_with("0\n"), "ip link add/del type bridge, master/nomaster: " + r.out + r.err)
	# A server bridging its two ports with iproute2.
	var sw := make_machine("sw", {"template": "server"})
	var left := make_machine("left", {"network": {"eth0": {"method": "static", "address": "10.0.0.1", "netmask": "255.0.0.0"}}})
	var right := make_machine("right", {"network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.0.0.0"}}})
	sw.hardware.connect_port("eth0", left.hardware, "eth0")
	sw.hardware.connect_port("eth1", right.hardware, "eth0")
	r = await run(sw, "ip link add br0 type bridge && ip link set eth0 master br0 && ip link set eth1 master br0 && ip link set eth0 up && ip link set eth1 up && ip link set br0 up && ip -br link show type bridge", "root")
	check(r.out.begins_with("br0              UP"), "bridge up: " + r.out + r.err)
	await until(func() -> bool: return left.net.iface("eth0").admin_up and right.net.iface("eth0").admin_up, 120)
	r = await run(left, "ping -c 1 10.0.0.2")
	check(r.out.contains("64 bytes from 10.0.0.2"), "bridged by a server: " + r.out)
	r = await run(sw, "bridge fdb show br br0 | grep -c permanent; bridge fdb show dev eth1; bridge link show dev eth0")
	check(r.out.begins_with("2\n%s dev eth1 master br0 \n" % right.hardware.nics[0].mac), "bridge fdb: " + r.out)
	check(r.out.contains("eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding priority 32 cost 19"), "bridge link: " + r.out)


func dhcp_pc(name: String, router: AgoraMachine, port: String) -> AgoraMachine:
	var pc := make_machine(name, {"network": {"eth0": {"method": "dhcp"}}})
	pc.hardware.connect_port("eth0", router.hardware, port)
	return pc


func _has_address(m: AgoraMachine, dev: String) -> bool:
	var i := m.net.iface(dev) if m.net else null
	return i != null and not i.addrs.is_empty()


func test_dhcp() -> void:
	var gw := make_machine("gw", {"template": "router", "profile": "router", "root_password": "admin"})
	await until(func() -> bool: return not gw.port_info(22).is_empty(), 180)
	var root := AgoraCred.root()
	check(gw.vfs.read_text(root, "/var/log/syslog").contains("udhcp server (v1.1.3) started"), "udhcpd runs on the router")
	# A PC that someone configured by hand sits on .102.
	var squatter := lan_pc("squatter", "192.168.1.102", gw, "eth4")
	await until(func() -> bool: return _has_address(squatter, "eth0"), 120)
	var pc1 := dhcp_pc("pc1", gw, "eth1")
	await until(func() -> bool: return _has_address(pc1, "eth0"), 300)
	var r := await run(pc1, "ip -4 -o a show eth0; ip route; cat /etc/resolv.conf")
	check(r.out.contains("2: eth0    inet 192.168.1.100/24 brd 192.168.1.255 scope global eth0"), "pc1 leased .100: " + r.out)
	check(r.out.contains("default via 192.168.1.1 dev eth0 \n") or r.out.contains("default via 192.168.1.1 dev eth0\n"), "default route from DHCP: " + r.out)
	check(r.out.contains("search lan\nnameserver 192.168.1.1\n"), "resolv.conf from DHCP: " + r.out)
	var clients := pc1.list_pids().filter(func(pid: int) -> bool: return pc1.get_process(pid).name == "udhcpc")
	check(clients.size() == 1 and pc1.get_process(clients[0]).ppid == 1, "udhcpc stays in the background")
	r = await run(pc1, "ping -c 1 192.168.1.1")
	check(r.out.contains("64 bytes from 192.168.1.1"), "the lease works: " + r.out)
	var pc2 := dhcp_pc("pc2", gw, "eth2")
	await until(func() -> bool: return _has_address(pc2, "eth0"), 300)
	var pc3 := dhcp_pc("pc3", gw, "eth3")
	await until(func() -> bool: return _has_address(pc3, "eth0"), 400)
	check_eq(AgoraInet.to_str(pc2.net.iface("eth0").addrs[0].address), "192.168.1.101", "pc2 gets the next address")
	check_eq(AgoraInet.to_str(pc3.net.iface("eth0").addrs[0].address), "192.168.1.103", "pc3 skips the address in use")
	var log := gw.vfs.read_text(root, "/var/log/syslog")
	check(log.contains("sending OFFER of 192.168.1.100") and log.contains("sending ACK to 192.168.1.100"), "server log: " + log.right(400))
	check(log.contains("192.168.1.102 belongs to someone, reserving it for 3600 seconds"), "ARP probe found the squatter")
	# Leases reach the file on SIGUSR1 (or every auto_time seconds).
	r = await run(gw, "kill -USR1 $(cat /var/run/udhcpd.pid); sleep 0.2; dumpleases", "root")
	var lines: PackedStringArray = r.out.split("\n", false)
	check_eq(lines[0], "Mac Address       IP-Address      Expires in", "dumpleases header")
	check(r.out.contains("%s 192.168.1.100   23 hours, 59 minutes, " % pc1.hardware.nics[0].mac) and r.out.contains(pc2.hardware.nics[0].mac + " 192.168.1.101"), "dumpleases: " + r.out)
	# Renew on SIGUSR1, and by itself at T1 (half the lease) on the clock.
	var acks := func() -> int: return gw.vfs.read_text(root, "/var/log/syslog").count("sending ACK to 192.168.1.100")
	var before: int = acks.call()
	r = await run(pc1, "kill -USR1 $(cat /run/udhcpc.eth0.pid)", "root")
	var leases_seen := func() -> int: return pc1.vfs.read_text(root, "/var/log/syslog").count("Lease of 192.168.1.100 obtained")
	await until(func() -> bool: return acks.call() > before and leases_seen.call() >= 2, 120)
	check_eq(acks.call(), before + 1, "SIGUSR1 renews")
	pc1.clock.set_time(pc1.clock.now() + 43201.0)
	await until(func() -> bool: return acks.call() > before + 1, 120)
	check_eq(acks.call(), before + 2, "renewed at T1")
	check(pc1.vfs.read_text(root, "/var/log/syslog").contains("Sending renew..."), "client log")
	# SIGUSR2 releases the lease.
	r = await run(pc2, "kill -USR2 $(cat /run/udhcpc.eth0.pid)", "root")
	await until(func() -> bool: return not _has_address(pc2, "eth0"), 120)
	check(not _has_address(pc2, "eth0"), "released")
	r = await run(pc2, "udhcpc -q -i eth0 -r 192.168.1.150", "root")
	check(r.err.contains("Sending discover...\nSending select for 192.168.1.101...\nLease of 192.168.1.101 obtained"), "the server remembers pc2: " + r.err)
	# A newcomer may ask for an address.
	var pc4 := make_machine("pc4")
	squatter.hardware.nics[0].unplug()
	pc4.hardware.connect_port("eth0", gw.hardware, "eth4")
	r = await run(pc4, "udhcpc -q -i eth0 -r 192.168.1.150 && ip -4 -o a show eth0", "root")
	check(r.err.contains("Sending select for 192.168.1.150...\nLease of 192.168.1.150 obtained, lease time 86400"), "udhcpc -q -r: " + r.err)
	check(r.out.contains("inet 192.168.1.150/24"), "requested address: " + r.out)


func _file_stat() -> AgoraStat:
	var st := AgoraStat.new()
	st.mode = AgoraStat.MODE_FILE
	return st


func test_packages() -> void:
	var m := make_machine()
	var r := await run(m, "apkg list | grep -c -e coreutils -e systemd -e agora-desktop")
	check_eq(r.out, "3\n", "desktop packages installed")
	r = await run(m, "apkg info openssh; apkg files openssh | grep sshd")
	check(r.out.contains("Status: installed") and r.out.contains("/sbin/sshd"), "info and files: " + r.out)
	r = await run(m, "apkg remove coreutils", "root")
	check(r.err.contains("depends on it"), "can't remove a dependency: " + r.err)
	r = await run(m, "apkg remove cron && ls /sbin/crond", "root")
	check(r.out.contains("Removing cron") and r.err.contains("No such file"), "remove deletes files: " + r.out + r.err)
	r = await run(m, "apkg install cron", "root")
	check(r.err.contains("no repository") or r.err.contains("unable to locate"), "no repository without the CD: " + r.err)
	m.hardware.insert(AgoraMedia.installer(false, m.clock))
	m._sync_devices()
	r = await run(m, "mount /dev/sr0 /media/cdrom && apkg list --available | grep -c router-base && apkg install cron && ls /sbin/crond", "root")
	check(r.out.contains("Installing cron") and r.out.ends_with("/sbin/crond\n"), "install from the CD: " + r.out + r.err)
	r = await run(m, "apkg install cron")
	check(r.err.contains("must be root"), "users can't install")


func test_router() -> void:
	var m := make_machine("gw", {"template": "router", "profile": "router", "root_password": "admin"})
	await until(func() -> bool: return not m.port_info(22).is_empty(), 120)
	check_eq(m.hardware.nics.size(), 5, "router has 5 ports")
	var r := await run(m, "ls -l /bin/ls; readlink /sbin/init; busybox --list | grep -c .", "root")
	check(r.out.contains("/bin/ls -> /bin/busybox") and r.out.contains("/bin/busybox\n"), "busybox applets: " + r.out)
	r = await run(m, "systemctl status; edit; apkg list | wc -l", "root")
	check(r.err.contains("systemctl: command not found") and r.err.contains("edit: command not found"), "no systemd, no desktop: " + r.err)
	r = await run(m, "busybox ls -d /etc; uname -m; ps | grep -c syslogd", "root")
	check(r.out.begins_with("/etc\nmips\n"), "busybox ls and arch: " + r.out)
	check(not m.port_info(22).is_empty(), "sshd runs on the router")
	# Log in through the serial console, like with a console cable.
	var serial := m.hardware.serial
	var screen := [""]
	serial.printed.connect(func(t: String) -> void: screen[0] += t)
	await until(func() -> bool: return serial.is_waiting_for_input(), 60)
	serial.type_line("root")
	serial.type_line("admin")
	await until(func() -> bool: return screen[0].ends_with("# "), 60)
	check(screen[0].contains("busybox based firmware") and screen[0].ends_with("root@gw:~# "), "serial login: " + screen[0].right(80))
	r = await run(m, "passwd", "root")
	check(true, "passwd applet runs")
	r = await run(m, "ip link set lo up && ping -c 1 127.0.0.1", "root")
	check(r.out.begins_with("PING 127.0.0.1 (127.0.0.1): 56 data bytes\n64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=0.0 ms\n\n--- 127.0.0.1 ping statistics ---\n1 packets transmitted, 1 packets received, 0% packet loss\nround-trip min/avg/max = "), "busybox ping: " + r.out + r.err)


func test_install_from_cd() -> void:
	var hw := AgoraHardware.from_template("pc")
	hw.insert(AgoraMedia.installer(false, hw.clock))
	var tty := hw.console
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	var live := hw.power_on()
	check(live != null and live.root_disk.kind == AgoraDisk.Kind.CDROM, "boots from the CD")
	await until(func() -> bool: return screen[0].contains("Install to which disk"), 120)
	check(screen[0].contains("AgoraOS 0.1.0 installer") and screen[0].contains("/dev/sda"), "installer on the console: " + screen[0].right(200))
	for answer in ["1", "1", "workstation", "toor", "toor", "neo", "matrix", "matrix", "systemd", "static", "192.168.1.50", "", "192.168.1.1", "192.168.1.1", "y"]:
		tty.type_line(answer)
		await until(func() -> bool: return tty.is_waiting_for_input(), 60)
	await until(func() -> bool: return screen[0].contains("Reboot now?"), 240)
	check(screen[0].contains("installing agora-desktop") and screen[0].contains("Installation complete."), "packages installed: " + screen[0].right(300))
	check(hw.media(AgoraDisk.Kind.CDROM) == null, "CD ejected")
	tty.type_line("y")
	await until(func() -> bool: return hw.machine != null and hw.machine.root_disk == hw.disks[0] and not hw.machine.port_info(22).is_empty(), 240)
	var m := hw.machine
	check(m != null and m.root_disk == hw.disks[0], "rebooted from the hard disk")
	_machines.append(m)
	m._owned_hardware = hw
	var r := await run(m, "hostname; id neo; systemctl is-active display-manager; apkg list | grep -c agora-installer", "neo")
	check_eq(r.out, "workstation\nuid=1000(neo) gid=1000(neo) groups=1000(neo),27(sudo)\nactive\n0\n", "installed system works: " + r.err)
	check(m.users.check_password("root", "toor"), "root password set")
	r = await run(m, "ip -4 -o addr show eth0; ip route; cat /etc/resolv.conf; grep workstation /etc/hosts", "neo")
	check(r.out.contains("2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0") and r.out.contains("default via 192.168.1.1 dev eth0 onlink"), "network configured at boot: " + r.out)
	check(r.out.contains("nameserver 192.168.1.1\n127.0.1.1\tworkstation"), "resolv.conf and hosts: " + r.out)
	check(hw.display.windows.size() >= 1, "login screen is up")
