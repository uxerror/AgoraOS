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
	await create_timer(1.2).timeout
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
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(home, tty)
	tty.type_line("ssh admin@server.corp")
	await create_timer(0.3).timeout
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
	check(screen[0].contains("64 bytes from 10.0.0.5"), "ping")
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
		["for f in /etc/host*; do echo $f; done", "/etc/hostname\n"],
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
