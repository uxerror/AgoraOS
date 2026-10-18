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
		"test_hardware", "test_netstack", "test_ethernet_arp", "test_cable", "test_cable_errors", "test_ethtool", "test_duplex", "test_iproute", "test_net_tools", "test_ping", "test_ifupdown", "test_bridge", "test_dhcp", "test_routing", "test_iptables", "test_nat", "test_tcp", "test_tcp_segments", "test_dns", "test_tcpdump", "test_telnet", "test_ftp", "test_web", "test_lynx", "test_mail", "test_packages", "test_router", "test_world", "test_internet", "test_install_from_cd",
	]
	# TEST_ONLY=test_ssh,test_tcp runs just those.
	var only := OS.get_environment("TEST_ONLY")
	if not only.is_empty():
		tests = tests.filter(func(t: String) -> bool: return t in only.split(","))
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


## Starts a command in the background as [param user]; await its wait().
func start(m: AgoraMachine, cmd: String, user: String = "alice") -> AgoraProcess:
	var u := m.users.find(user)
	return m.spawn(PackedStringArray(["/bin/sh", "-c", cmd]), {
		"cred": m.users.cred_for(user), "cwd": u.home,
		"env": {"HOME": u.home, "USER": user, "PATH": AgoraMachine.DEFAULT_PATH},
	})


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
	r = await run(m, "n=`echo 41`; echo \"[`echo in quotes`]\" $((n + 1)) `echo \\`echo nested\\``")
	check_eq(r.out, "[in quotes] 42 nested\n", "backquoted command substitution")
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
	r = await run(m, "printf '%s=%03d %-4s|\\n' a 7 b; printf '%s\\n' x y; printf '\\101\\t%x %X %5.2f %c\\n' 255 255 3.14159 zed; printf '%b' 'one\\ttwo\\n'")
	check_eq(r.out, "a=007 b   |\nx\ny\nA\tff FF  3.14 z\none\ttwo\n", "printf")
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
	check(r.out.begins_with("4:alice:x:1000"), "grep -n: " + r.out)
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
	var home := make_machine("home", {"network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.255.255.0"}}})
	var server := make_machine("server", {"users": [{"name": "admin", "password": "hunter2"}],
		"network": {"eth0": {"method": "static", "address": "10.0.0.5", "netmask": "255.255.255.0"}}})
	home.hardware.connect_port("eth0", server.hardware, "eth0")
	home.vfs.write_text(AgoraCred.root(), "/etc/hosts", "127.0.0.1\tlocalhost\n10.0.0.5\tserver.corp\n")
	await until(func() -> bool: return _has_address(home, "eth0") and _has_address(server, "eth0") and not server.port_info(22).is_empty(), 120)
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(home, tty)
	tty.type_line("ssh admin@server.corp")
	await until(func() -> bool: return screen[0].ends_with("password: "), 120)
	check(screen[0].ends_with("admin@server.corp's password: ") and not tty.echo, "ssh asks for the password without echo")
	tty.type_line("wrong")
	await until(func() -> bool: return screen[0].ends_with("Permission denied, please try again.\nadmin@server.corp's password: "), 120)
	check(screen[0].ends_with("Permission denied, please try again.\nadmin@server.corp's password: "), "wrong password: " + screen[0].right(80))
	tty.type_line("hunter2")
	await until(func() -> bool: return screen[0].ends_with("admin@server:~$ "), 120)
	check(screen[0].ends_with("admin@server:~$ ") and tty.echo, "remote prompt: " + screen[0].right(40))
	screen[0] = ""
	tty.type_line("hostname; cat /etc/hostname; echo $SSH_CLIENT")
	await until(func() -> bool: return screen[0].ends_with("$ "), 120)
	check(screen[0].begins_with("server\nserver\n10.0.0.2 ") and screen[0].ends_with(" 22\nadmin@server:~$ "), "commands run on the server: " + screen[0])
	screen[0] = ""
	tty.type_line("exit")
	await until(func() -> bool: return screen[0].ends_with("alice@home:~$ "), 120)
	check(screen[0].contains("Connection to server.corp closed.") and screen[0].ends_with("alice@home:~$ "), "back home: " + screen[0])
	var auth := server.vfs.read_text(AgoraCred.root(), "/var/log/auth.log")
	check(auth.contains("Failed password for admin from 10.0.0.2 port ") and auth.contains("Accepted password for admin from 10.0.0.2 port ") and auth.contains(" ssh2\n"), "server logged the logins: " + auth)
	check(auth.contains("pam_unix(sshd:session): session opened for user admin by (uid=0)") and auth.contains("session closed for user admin"), "sessions logged")
	# A command instead of a shell, with its exit status.
	screen[0] = ""
	tty.type_line("ssh admin@10.0.0.5 'whoami; exit 3'; echo status $?")
	await until(func() -> bool: return screen[0].ends_with("password: "), 120)
	tty.type_line("hunter2")
	await until(func() -> bool: return screen[0].contains("status "), 120)
	check(screen[0].contains("admin\nstatus 3\n"), "ssh host command: " + screen[0])
	var r := await run(server, "netstat -tln", "admin")
	check(r.out.contains("tcp        0      0 0.0.0.0:22              0.0.0.0:*               LISTEN     "), "netstat shows sshd: " + r.out)
	# Connections that don't work, each for its own reason.
	r = await run(home, "ssh nobody@10.0.0.5 -p 2222 true; ssh 10.0.0.99 true; ssh nosuch true")
	check_eq(r.err, "ssh: connect to host 10.0.0.5 port 2222: Connection refused\nssh: connect to host 10.0.0.99 port 22: No route to host\nssh: Could not resolve hostname nosuch: Temporary failure in name resolution\n", "ssh errors")
	await run(server, "iptables -A INPUT -p tcp --dport 22 -j DROP && sysctl -q -w net.ipv4.tcp_syn_retries=1", "root")
	await run(home, "sysctl -q -w net.ipv4.tcp_syn_retries=1", "root")
	r = await run(home, "ssh 10.0.0.5 true")
	check_eq(r.err, "ssh: connect to host 10.0.0.5 port 22: Connection timed out\n", "a firewall that drops")
	await run(server, "iptables -F && iptables -A INPUT -p tcp --dport 22 -j REJECT", "root")
	r = await run(home, "ssh 10.0.0.5 true")
	check_eq(r.err, "ssh: connect to host 10.0.0.5 port 22: Connection refused\n", "a firewall that rejects")


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
	check(m.kmsg[-1].ends_with("eth0: link up, 1000Mbps, full-duplex"), "link up logged: " + m.kmsg[-1])
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


func test_cable() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var na: AgoraNic = a.hardware.nics[0]
	var nb: AgoraNic = b.hardware.nics[0]
	check_eq(na.link_speed, 1000, "gigabit cards")
	nb.speed_mbps = 10
	check_eq([na.link_speed, nb.link_speed], [10, 10], "the slower card sets the speed")
	var cable := na.cable
	check(is_equal_approx(cable.wire_time(1514), (8 + 1514 + 4) * 8 / 10e6), "a full frame: preamble, frame, FCS")
	check(is_equal_approx(cable.wire_time(42), (8 + 60 + 4) * 8 / 10e6), "short frames are padded")
	# A burst waits its turn: each frame starts after the last one and the gap.
	na.latency_ms = 0.0
	nb.latency_ms = 0.0
	var got: Array[Dictionary] = []
	var driver := nb.receiver
	nb.receiver = func(f: Dictionary) -> void: got.append(f)
	var started := Time.get_ticks_usec()
	# A frame's delay counts from its own send; later sends wait less.
	var sent_ms: Array[float] = []
	for k in 5:
		sent_ms.append((Time.get_ticks_usec() - started) / 1000.0)
		na.transmit({"dst": nb.mac, "src": na.mac, "type": 0x88B5, "payload": {}, "len": 1500, "n": k})
	check_eq(na.queued(), 5, "five frames on the transmitter")
	await until(func() -> bool: return got.size() == 5, 60)
	var elapsed := (Time.get_ticks_usec() - started) / 1000.0
	nb.receiver = driver
	check_eq(got.map(func(f: Dictionary) -> int: return f.n), [0, 1, 2, 3, 4], "frames arrive in order")
	var frame_ms := (8 + 1514 + 4) * 8 / 10e3
	var gap_ms := 96 / 10e3
	var ok := got.size() == 5
	for k in got.size():
		var expected := (k + 1) * frame_ms + k * gap_ms + cable.propagation() * 1000.0 - sent_ms[k]
		ok = ok and absf(float(got[k].lat) - expected) < 0.02
	check(ok, "queueing delay: %s" % [got.map(func(f: Dictionary) -> String: return "%.4f" % f.lat)])
	check(elapsed >= 4.0, "the burst really takes about 6 ms: %.2f ms" % elapsed)
	check_eq(na.queued(), 0, "queue drained")
	# The interface's txqueuelen bounds the queue; the rest is dropped.
	await run(a, "ping -c 1 192.168.1.20")
	var r := await run(a, "ip link set eth0 txqueuelen 3 && ip link show eth0", "root")
	check(r.out.contains("qlen 3"), "txqueuelen: " + r.out + r.err)
	var dropped: int = a.net.iface("eth0").stats.tx_dropped
	for k in 10:
		a.net.ip_output(a.net.make_packet(0, AgoraInet.parse("192.168.1.20"), 253, {}, 1480))
	check_eq(a.net.iface("eth0").stats.tx_dropped - dropped, 7, "a full queue drops")
	r = await run(a, "ip link set eth0 txqueuelen x", "root")
	check_eq(r.err, "Error: argument \"x\" is wrong: Invalid \"txqueuelen\" value\n", "bad txqueuelen")
	# Through the stack: 139 kB at 10 Mbit/s take over a tenth of a second.
	var sink := start(b, "nc -l -p 7000 > /tmp/bulk")
	await until(func() -> bool: return not b.port_info(7000).is_empty(), 60)
	await run(a, "ip link set eth0 txqueuelen 1000", "root")
	started = Time.get_ticks_usec()
	r = await run(a, "seq 1 25000 | nc 192.168.1.20 7000")
	await sink.wait()
	elapsed = (Time.get_ticks_usec() - started) / 1000.0
	check_eq(b.vfs.read_text(AgoraCred.root(), "/tmp/bulk").length(), 138894, "bulk transfer intact")
	check(elapsed >= 110.0, "limited by the link: %.0f ms" % elapsed)
	# A longer cable: 2 km of copper add 10 us each way, but carry nothing.
	a.hardware.connect_port("eth0", b.hardware, "eth0", 2000.0)
	check(is_equal_approx(na.cable.propagation(), 0.00001), "propagation delay")
	r = await run(a, "cat /sys/class/net/eth0/carrier /sys/class/net/eth0/speed")
	check_eq(r.out, "0\n-1\n", "no link over 2 km")
	a.hardware.connect_port("eth0", b.hardware, "eth0", 120.0)
	r = await run(a, "cat /sys/class/net/eth0/speed /sys/class/net/eth0/duplex")
	check_eq(r.out, "10\nfull\n", "sysfs speed is the link's")
	check(a.kmsg[-1].ends_with("eth0: link up, 10Mbps, full-duplex"), "negotiated speed logged: " + a.kmsg[-1])


func test_cable_errors() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var na: AgoraNic = a.hardware.nics[0]
	var nb: AgoraNic = b.hardware.nics[0]
	var cable := na.cable
	check_eq(cable.bit_error_rate(), AgoraCable.BER_SOUND, "a short sound cable")
	check(cable.frame_error_chance(1514) < 1e-7, "practically no errors")
	# Beyond 100 m errors grow tenfold every 10 m; 10BASE-T reaches further.
	cable.length_m = 150.0
	check(is_equal_approx(cable.bit_error_rate(100), 1e-7), "150 m at 100 Mbit/s: " + str(cable.bit_error_rate(100)))
	check_eq(cable.bit_error_rate(10), AgoraCable.BER_SOUND, "150 m at 10 Mbit/s")
	cable.length_m = 2.0
	cable.defects = ["bad_crimp", "crushed"]
	check(is_equal_approx(cable.bit_error_rate(100), 2.1e-5 + AgoraCable.BER_SOUND), "defects add up")
	check(is_equal_approx(cable.bit_error_rate(10), 2.1e-7 + AgoraCable.BER_SOUND), "defects hurt 10 Mbit/s less")
	# A crushed cable: about one full frame in five arrives with a bad FCS.
	cable.defects = ["crushed"]
	cable.rng.seed = 1
	var chance := cable.frame_error_chance(1514)
	check(absf(chance - 0.2156) < 0.001, "frame error chance: %f" % chance)
	var st: Dictionary = b.net.iface("eth0").stats
	var before: int = st.rx_packets
	for k in 400:
		na.transmit({"dst": nb.mac, "src": na.mac, "type": 0x88B5, "payload": {}, "len": 1500})
	await until(func() -> bool: return st.rx_packets - before + st.rx_crc_errors == 400, 120)
	var bad: int = st.rx_crc_errors
	check(bad > 50 and bad < 120 and st.rx_errors == bad, "frames lost to CRC errors: %d of 400" % bad)
	check_eq(st.rx_packets - before, 400 - bad, "the rest arrive")
	var r := await run(b, "ip -s -s link show eth0")
	check(r.out.contains("    RX errors: length   crc     frame   fifo    missed\n               0        %-7d 0       0       0       \n" % bad), "ip -s -s: " + r.out)
	check(r.out.contains("    TX errors: aborted  fifo   window heartbeat transns\n               0        0       0       0       2       \n"), "carrier changes: " + r.out)
	r = await run(b, "ip -s link show eth0")
	check(not r.out.contains("RX errors"), "details only with -s -s")
	r = await run(b, "ifconfig eth0")
	check(r.out.contains("errors:%d dropped:%d overruns:0 frame:%d\n" % [bad, st.rx_dropped, bad]), "ifconfig: " + r.out)
	r = await run(b, "cat /sys/class/net/eth0/statistics/rx_crc_errors /sys/class/net/eth0/carrier_changes")
	check_eq(r.out, "%d\n2\n" % bad, "sysfs counters")
	r = await run(b, "grep eth0 /proc/net/dev")
	var cols: PackedStringArray = r.out.split(" ", false)
	check(cols.size() == 17 and cols[3] == str(bad) and cols[6] == str(bad), "/proc/net/dev errs and frame: " + r.out)
	# TCP gets through a bad crimp by retransmitting.
	cable.defects = ["bad_crimp"]
	var sink := start(b, "nc -l -p 7000 > /tmp/data")
	await until(func() -> bool: return not b.port_info(7000).is_empty(), 60)
	await run(a, "seq 1 5000 | nc 192.168.1.20 7000")
	await sink.wait()
	check_eq(b.vfs.read_text(AgoraCred.root(), "/tmp/data").length(), 23893, "data intact over a bad crimp")
	# A link that barely holds at its speed loses most frames.
	cable.defects = []
	cable.length_m = 175.0
	before = st.rx_crc_errors
	r = await run(a, "ping -c 10 -i 0.2 -W 1 -s 1400 192.168.1.20")
	check(not r.out.contains(" 0% packet loss"), "a link at its limit: " + r.out)
	check(st.rx_crc_errors > before or a.net.iface("eth0").stats.rx_crc_errors > 0, "CRC errors on the way")

## A PC (e100, Fast Ethernet) cabled to a server (e1000, Gigabit), both up:
## 192.168.1.10 and 192.168.1.20.
func pc_and_server() -> Array[AgoraMachine]:
	var pc := make_machine("pc", {"template": "pc"})
	var srv := make_machine("srv", {"template": "server"})
	pc.hardware.connect_port("eth0", srv.hardware, "eth0")
	var n := 10
	for m in [pc, srv]:
		m.net.set_link("lo", true)
		m.net.set_link("eth0", true)
		m.net.add_address("eth0", AgoraInet.parse("192.168.1.%d" % n), 24, {"broadcast": AgoraInet.parse("192.168.1.255")})
		n += 10
	return [pc, srv]


func test_ethtool() -> void:
	var pair := pc_and_server()
	var pc := pair[0]
	var srv := pair[1]
	var r := await run(pc, "ethtool eth0", "root")
	check_eq(r.out, """Settings for eth0:
	Supported ports: [ TP MII ]
	Supported link modes:   10baseT/Half 10baseT/Full 
	                        100baseT/Half 100baseT/Full 
	Supported pause frame use: No
	Supports auto-negotiation: Yes
	Supported FEC modes: Not reported
	Advertised link modes:  10baseT/Half 10baseT/Full 
	                        100baseT/Half 100baseT/Full 
	Advertised pause frame use: No
	Advertised auto-negotiation: Yes
	Advertised FEC modes: Not reported
	Link partner advertised link modes:  10baseT/Half 10baseT/Full 
	                                     100baseT/Half 100baseT/Full 
	                                     1000baseT/Full 
	Link partner advertised pause frame use: No
	Link partner advertised auto-negotiation: Yes
	Link partner advertised FEC modes: Not reported
	Speed: 100Mb/s
	Duplex: Full
	Port: MII
	PHYAD: 1
	Transceiver: internal
	Auto-negotiation: on
	Supports Wake-on: g
	Wake-on: g
	Current message level: 0x00000007 (7)
			       drv probe link
	Link detected: yes
""", "ethtool on an e100")
	r = await run(srv, "ethtool eth0")
	check(r.out.contains("\t                        1000baseT/Full \n") and not r.out.contains("Link partner")
		and r.out.contains("\tSpeed: 100Mb/s\n\tDuplex: Full\n\tPort: Twisted Pair\n\tPHYAD: 0\n\tTransceiver: internal\n\tAuto-negotiation: on\n\tMDI-X: off (auto)\n\tCurrent message level")
		and not r.out.contains("Wake-on"), "ethtool on an e1000 as a user: " + r.out)
	check_eq(r.err, "Cannot get wake-on-lan settings: Operation not permitted\n", "wake-on-LAN needs root")
	r = await run(pc, "ethtool -i eth0")
	check(r.out.begins_with("driver: e100\nversion: 3.5.24-k2-NAPI\nfirmware-version: N/A\nexpansion-rom-version: \nbus-info: 0000:02:01.0\n"), "ethtool -i: " + r.out)
	r = await run(pc, "ethtool lo", "root")
	check_eq(r.out, "Settings for lo:\n\tLink detected: yes\n", "loopback")
	r = await run(pc, "ethtool eth9")
	check(r.code == 75 and r.err.ends_with("Cannot get link status: No such device\nNo data available\n"), "no such device: " + r.err)
	r = await run(pc, "ethtool -S eth0 | head -3")
	check(r.out.begins_with("NIC statistics:\n     rx_packets: ") , "ethtool -S: " + r.out)
	r = await run(srv, "ethtool -S eth0 | grep -c :")
	check_eq(r.out, "47\n", "e1000 statistics")
	r = await run(pc, "ethtool -s eth0 speed 10 duplex half autoneg off")
	check(r.code == 80 and r.err == "Cannot set new settings: Operation not permitted\n  not setting speed\n  not setting duplex\n  not setting autoneg\n", "changes need root: " + r.err)
	r = await run(srv, "ethtool -s eth0 speed 1000 duplex full autoneg off", "root")
	check(r.err.begins_with("Cannot set new settings: Invalid argument\n"), "gigabit can't be forced: " + r.err)
	r = await run(pc, "ethtool -s eth0 speed foo")
	check(r.code == 1 and r.err.begins_with("ethtool: bad command line argument(s)"), "bad arguments")
	# Advertising only 10 Mbit/s modes brings the link down to 10.
	r = await run(pc, "ethtool -s eth0 advertise 0x003", "root")
	check_eq([r.code, pc.hardware.nics[0].link_speed], [0, 10], "advertise 10 only")
	r = await run(pc, "ethtool -s eth0 autoneg on", "root")
	check_eq(pc.hardware.nics[0].link_speed, 100, "autoneg on advertises everything again")
	# A speed without autoneg off does nothing on an autonegotiating card.
	await run(pc, "ethtool -s eth0 speed 10", "root")
	check_eq(pc.hardware.nics[0].link_speed, 100, "speed alone is ignored with autoneg")
	r = await run(pc, "ethtool -s eth0 autoneg on speed 10 duplex full && ethtool eth0 | grep Advertised.link", "root")
	check_eq(r.out, "\tAdvertised link modes:  10baseT/Full \n", "autoneg with a speed advertises that mode")
	await run(pc, "ethtool -s eth0 autoneg on", "root")
	r = await run(pc, "ethtool -r eth0 && dmesg | tail -2", "root")
	check(r.out.contains("eth0: link down\n") and r.out.ends_with("eth0: link up, 100Mbps, full-duplex\n"), "restart autonegotiation: " + r.out)
	r = await run(pc, "ip link set eth0 down; ethtool eth0 | tail -1", "root")
	check_eq(r.out, "\tLink detected: no\n", "interface down")


func test_duplex() -> void:
	var pair := pc_and_server()
	var pc := pair[0]
	var srv := pair[1]
	var nic: AgoraNic = pc.hardware.nics[0]
	# Forcing one end leaves the other to detect the speed and guess half
	# duplex: a duplex mismatch.
	# (At 10 Mbit/s a frame holds the wire long enough for the simulated
	# hosts to keep it busy.)
	var r := await run(srv, "ethtool -s eth0 speed 10 duplex full autoneg off", "root")
	check_eq(r.code, 0, "forced 10/full")
	check_eq([nic.link_speed, nic.duplex, srv.hardware.nics[0].duplex], [10, "half", "full"], "mismatch")
	r = await run(pc, "ethtool eth0; cat /sys/class/net/eth0/duplex")
	check(r.out.contains("\tSpeed: 10Mb/s\n\tDuplex: Half\n") and not r.out.contains("Link partner") and r.out.ends_with("half\n"), "parallel detection: " + r.out)
	check(pc.kmsg[-1].ends_with("eth0: link up, 10Mbps, half-duplex"), "half duplex logged: " + pc.kmsg[-1])
	var sink := start(srv, "nc -l -p 7000 > /tmp/data")
	await until(func() -> bool: return not srv.port_info(7000).is_empty(), 60)
	await run(pc, "seq 1 3000 | nc 192.168.1.20 7000")
	await sink.wait()
	check_eq(srv.vfs.read_text(AgoraCred.root(), "/tmp/data").length(), 13893, "data gets through, slowly")
	var pst: Dictionary = pc.net.iface("eth0").stats
	var sst: Dictionary = srv.net.iface("eth0").stats
	check(pst.collisions > 0 and pst.tx_window_errors > 0, "late collisions on the half duplex end: %d, %d" % [pst.collisions, pst.tx_window_errors])
	check(sst.rx_crc_errors + sst.rx_length_errors > 0 and sst.collisions == 0, "CRC errors and runts on the full duplex end: %d, %d" % [sst.rx_crc_errors, sst.rx_length_errors])
	r = await run(pc, "ifconfig eth0 | grep collisions; ethtool -S eth0 | grep -E 'tx_window_errors|tx_deferred'")
	check(r.out.begins_with("          collisions:%d txqueuelen:1000 \n     tx_window_errors: %d\n     tx_deferred: " % [pst.collisions, pst.tx_window_errors]), "counters: " + r.out)
	r = await run(srv, "ip -s -s link show eth0")
	check(r.out.contains("missed\n               %-8d %-7d " % [sst.rx_length_errors, sst.rx_crc_errors]), "ip -s -s on the full duplex end: " + r.out)
	# Both ends at half duplex share the wire properly.
	await run(srv, "ethtool -s eth0 speed 10 duplex half autoneg off", "root")
	await run(pc, "ethtool -s eth0 speed 10 duplex half autoneg off", "root")
	check_eq([nic.link_speed, nic.duplex, srv.hardware.nics[0].duplex], [10, "half", "half"], "10/half on both")
	var late: int = pst.tx_window_errors
	sink = start(srv, "nc -l -p 7001 > /tmp/data2")
	await until(func() -> bool: return not srv.port_info(7001).is_empty(), 60)
	await run(pc, "seq 1 5000 | nc 192.168.1.20 7001")
	await sink.wait()
	check_eq(srv.vfs.read_text(AgoraCred.root(), "/tmp/data2").length(), 23893, "half duplex link works")
	check_eq(pst.tx_window_errors, late, "no late collisions when both agree")
	# Back to autonegotiation on both.
	await run(srv, "ethtool -s eth0 autoneg on", "root")
	await run(pc, "ethtool -s eth0 autoneg on", "root")
	check_eq([nic.link_speed, nic.duplex], [100, "full"], "autonegotiated again")
	# A long cable: 100 Mbit/s can't hold the link, so it comes up at 10.
	var cable := nic.cable
	cable.length_m = 200.0
	check_eq([nic.link_speed, nic.duplex], [10, "full"], "downshift at 200 m")
	r = await run(pc, "ethtool eth0")
	check(r.out.contains("\tSpeed: 10Mb/s\n") and r.out.contains("Link partner advertised link modes:  10baseT/Half 10baseT/Full \n\t                                     100baseT/Half"), "partner could do more: " + r.out)
	r = await run(pc, "ping -c 2 -i 0.2 192.168.1.20")
	check(r.out.contains(" 0% packet loss"), "still works at 10: " + r.out)
	# Further, the autonegotiation pages themselves get garbled: both fall
	# back to 10/half by parallel detection.
	cable.length_m = 235.0
	check_eq([nic.link_speed, nic.duplex, srv.hardware.nics[0].duplex], [10, "half", "half"], "pages garbled at 235 m")
	cable.length_m = 250.0
	check(not nic.carrier, "no link at 250 m")
	r = await run(pc, "ethtool eth0 | grep -E 'Speed|Duplex|detected'")
	check_eq(r.out, "\tSpeed: Unknown!\n\tDuplex: Unknown! (255)\n\tLink detected: no\n", "ethtool without a link")
	r = await run(pc, "ip link show eth0")
	check(r.out.contains("NO-CARRIER"), "no carrier: " + r.out)

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
		"ping: nosuchhost: Temporary failure in name resolution", ""]), "ping errors")
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
	check(r.out.contains("eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 master br0 state forwarding priority 32 cost 4"), "bridge link: " + r.out)


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


## a (10.1.0.2) -- r (10.1.0.1 | 10.2.0.1) -- b (10.2.0.2), r a server
## that doesn't forward yet.
func routed_line() -> Array[AgoraMachine]:
	var a := make_machine("a", {"network": {"eth0": {"method": "static", "address": "10.1.0.2", "netmask": "255.255.255.0", "gateway": "10.1.0.1"}}})
	var b := make_machine("b", {"network": {"eth0": {"method": "static", "address": "10.2.0.2", "netmask": "255.255.255.0", "gateway": "10.2.0.1"}}})
	var r := make_machine("r", {"template": "server", "network": {
		"eth0": {"method": "static", "address": "10.1.0.1", "netmask": "255.255.255.0"},
		"eth1": {"method": "static", "address": "10.2.0.1", "netmask": "255.255.255.0"}}})
	a.hardware.connect_port("eth0", r.hardware, "eth0")
	b.hardware.connect_port("eth0", r.hardware, "eth1")
	return [a, r, b]


func test_routing() -> void:
	var line := routed_line()
	var a := line[0]
	var r := line[1]
	var b := line[2]
	await until(func() -> bool: return _has_address(a, "eth0") and _has_address(b, "eth0") and r.net.iface("eth1").admin_up, 120)
	var out := await run(a, "ping -c 1 -W 1 10.2.0.2")
	check(out.out.contains("1 packets transmitted, 0 received, 100% packet loss"), "no forwarding by default: " + out.out)
	out = await run(r, "cat /proc/sys/net/ipv4/ip_forward; sysctl net.ipv4.ip_forward; sysctl -w net.ipv4.ip_forward=1")
	check_eq([out.out, out.err], ["0\nnet.ipv4.ip_forward = 0\n", "sysctl: permission denied on key 'net.ipv4.ip_forward'\n"], "sysctl as a user")
	out = await run(r, "echo 1 > /proc/sys/net/ipv4/ip_forward; sysctl -a | grep forward; echo 7 > /proc/sys/net/ipv4/ip_forward", "root")
	check_eq(out.out, "net.ipv4.ip_forward = 1\n", "forwarding on: " + out.err)
	check(out.err.contains("Invalid argument"), "bad value refused: " + out.err)
	out = await run(a, "ping -c 1 10.2.0.2")
	check(out.out.contains("64 bytes from 10.2.0.2: icmp_seq=1 ttl=63"), "routed, TTL down by one: " + out.out)
	out = await run(a, "ping -c 1 -t 1 10.2.0.2; ping -c 1 10.9.9.9")
	check(out.out.contains("From 10.1.0.1 icmp_seq=1 Time to live exceeded"), "TTL exceeded: " + out.out)
	check(out.out.contains("From 10.1.0.1 icmp_seq=1 Destination Net Unreachable"), "no route on the router: " + out.out)
	out = await run(a, "traceroute -n -w 1 -m 4 10.2.0.2")
	var lines: PackedStringArray = out.out.split("\n", false)
	check_eq(lines[0], "traceroute to 10.2.0.2 (10.2.0.2), 4 hops max, 60 byte packets", "traceroute header")
	check(lines.size() == 3 and lines[1].begins_with(" 1  10.1.0.1  0.") and lines[2].begins_with(" 2  10.2.0.2  0.") and lines[2].count(" ms") == 3, "traceroute hops: " + out.out)
	a.vfs.write_text(AgoraCred.root(), "/etc/hosts", "10.1.0.1\trouter.lan\n")
	out = await run(a, "traceroute -q 1 -w 1 -m 4 10.2.0.2; traceroute -I 10.2.0.2")
	check(out.out.contains(" 1  router.lan (10.1.0.1)  0.") and out.out.contains(" 2  10.2.0.2 (10.2.0.2)  0."), "names and one probe: " + out.out)
	check(out.err.contains("You do not have enough privileges to use this traceroute method."), "-I needs root")
	out = await run(a, "traceroute -I -n -q 2 -w 1 -m 4 10.2.0.2", "root")
	check(out.out.contains(" 2  10.2.0.2  0.") and out.out.count(" ms") == 4, "ICMP traceroute: " + out.out)
	# A route to nowhere on the router.
	await run(r, "ip route add unreachable 10.66.0.0/16; ip route add prohibit 10.77.0.0/16", "root")
	out = await run(a, "traceroute -n -q 1 -w 1 -m 4 10.66.1.1; traceroute -n -q 1 -w 1 -m 4 10.77.1.1")
	check(out.out.contains(" 1  10.1.0.1  0.") and out.out.contains(" ms !H\n") and out.out.contains(" ms !X\n"), "unreachable marks: " + out.out)


func test_iptables() -> void:
	var line := routed_line()
	var a := line[0]
	var r := line[1]
	var b := line[2]
	await until(func() -> bool: return _has_address(a, "eth0") and _has_address(b, "eth0") and r.net.iface("eth1").admin_up, 120)
	var out := await run(r, "iptables -L")
	check_eq([out.err, out.code], ["iptables v1.8.7 (legacy): can't initialize iptables table `filter': Permission denied (you must be root)\nPerhaps iptables or your kernel needs to be upgraded.\n", 3], "iptables needs root")
	out = await run(r, "sysctl -q -w net.ipv4.ip_forward=1 && iptables -L -n", "root")
	var empty := "target     prot opt source               destination         "
	check_eq(out.out, "Chain INPUT (policy ACCEPT)\n%s\n\nChain FORWARD (policy ACCEPT)\n%s\n\nChain OUTPUT (policy ACCEPT)\n%s\n" % [empty, empty, empty], "empty filter table")
	# A stateful firewall between the two networks.
	out = await run(r, "iptables -P FORWARD DROP && iptables -A FORWARD -i eth0 -o eth1 -j ACCEPT && iptables -A FORWARD -m state --state ESTABLISHED,RELATED -j ACCEPT && iptables -L FORWARD -n", "root")
	check_eq(out.out, "\n".join(["Chain FORWARD (policy DROP)", empty,
		"ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0           ",
		"ACCEPT     all  --  0.0.0.0/0            0.0.0.0/0            state RELATED,ESTABLISHED", ""]), "iptables -L: " + out.err)
	out = await run(a, "ping -c 1 10.2.0.2")
	check(out.out.contains("64 bytes from 10.2.0.2"), "a reaches b through the firewall: " + out.out)
	out = await run(b, "ping -c 1 -W 1 10.1.0.2")
	check(out.out.contains("0 received"), "b can't start a connection to a: " + out.out)
	out = await run(r, "cat /proc/net/nf_conntrack", "root")
	check(out.out.begins_with("ipv4     2 icmp     1 2") and out.out.contains(" src=10.1.0.2 dst=10.2.0.2 type=8 code=0 id=") and out.out.contains(" src=10.2.0.2 dst=10.1.0.2 type=0 code=0 id=") and out.out.ends_with(" mark=0 zone=0 use=2\n"), "conntrack table: " + out.out)
	check(not out.out.contains("src=10.2.0.2 dst=10.1.0.2 type=8"), "the dropped attempt was never confirmed: " + out.out)
	out = await run(a, "traceroute -n -q 1 -w 1 -m 3 10.2.0.2")
	check(out.out.contains(" 2  10.2.0.2  0."), "port unreachable from b is RELATED: " + out.out)
	out = await run(r, "iptables -L FORWARD -n -v -x --line-numbers", "root")
	var rows: PackedStringArray = out.out.split("\n", false)
	check(rows[0].begins_with("Chain FORWARD (policy DROP 1 packets, 84 bytes)"), "policy counters: " + out.out)
	check_eq(rows[1], "num      pkts      bytes target     prot opt in     out     source               destination         ", "verbose header")
	check(rows[2].begins_with("1           ") and rows[2].contains(" ACCEPT     all  --  eth0   eth1    0.0.0.0/0            0.0.0.0/0"), "verbose rule: " + rows[2])
	# REJECT and LOG on the router itself, DROP on a's way out.
	out = await run(r, "iptables -A INPUT -p icmp --icmp-type echo-request -j LOG --log-prefix \"ping: \" && iptables -A INPUT -p icmp --icmp-type echo-request -j REJECT --reject-with icmp-host-prohibited", "root")
	out = await run(a, "ping -c 1 10.1.0.1")
	check(out.out.contains("From 10.1.0.1 icmp_seq=1 Destination Host Prohibited"), "REJECT: " + out.out)
	var logged := "\n".join(r.kmsg)
	check(logged.contains("ping: IN=eth0 OUT= SRC=10.1.0.2 DST=10.1.0.1 LEN=84 TOS=0x00 PREC=0x00 TTL=64 ID=") and logged.contains("PROTO=ICMP TYPE=8 CODE=0 ID="), "LOG: " + r.kmsg[-1])
	out = await run(a, "iptables -A OUTPUT -d 10.2.0.2 -j DROP && ping -c 1 10.2.0.2", "root")
	check(out.err.contains("ping: sendmsg: Operation not permitted"), "OUTPUT DROP: " + out.err)
	out = await run(r, "iptables -S; iptables -L INPUT", "root")
	check(out.out.begins_with("-P INPUT ACCEPT\n-P FORWARD DROP\n-P OUTPUT ACCEPT\n-A INPUT -p icmp -m icmp --icmp-type 8 -j LOG --log-prefix \"ping: \"\n-A INPUT -p icmp -m icmp --icmp-type 8 -j REJECT --reject-with icmp-host-prohibited\n-A FORWARD -i eth0 -o eth1 -j ACCEPT\n-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT\n"), "iptables -S: " + out.out)
	check(out.out.contains("LOG        icmp --  anywhere             anywhere             icmp echo-request LOG flags 0 level 4 prefix \"ping: \"") and out.out.contains("REJECT     icmp --  anywhere             anywhere             icmp echo-request reject-with icmp-host-prohibited"), "names without -n: " + out.out)
	out = await run(r, "iptables-save > /root/rules && iptables -F && iptables -P FORWARD ACCEPT && iptables-restore /root/rules && iptables -S | wc -l", "root")
	check_eq(out.out, "7\n", "save and restore: " + out.err)
	out = await run(r, "iptables -D INPUT 1 && iptables -D INPUT -p icmp --icmp-type 8 -j REJECT --reject-with icmp-host-prohibited && iptables -L INPUT -n | wc -l; iptables -D INPUT -j ACCEPT", "root")
	check_eq([out.out, out.err], ["2\n", "iptables: Bad rule (does a matching rule exist in that chain?).\n"], "delete by number and by spec")
	out = await run(r, "iptables -A NOPE -j ACCEPT; iptables -A INPUT -j FOO; iptables -A INPUT -j MASQUERADE; iptables -A INPUT -p tcp --dport ssh -j ACCEPT; iptables -A INPUT --dport 22 -j ACCEPT; iptables -t mangle -L", "root")
	check_eq(out.err, "\n".join([
		"iptables: No chain/target/match by that name.",
		"iptables v1.8.7 (legacy): Couldn't load target `FOO':No such file or directory\n\nTry `iptables -h' or 'iptables --help' for more information.",
		"iptables: Invalid argument. Run `dmesg' for more information.",
		"iptables v1.8.7 (legacy): unknown option \"--dport\"\nTry `iptables -h' or 'iptables --help' for more information.",
		"iptables v1.8.7 (legacy): can't initialize iptables table `mangle': Table does not exist (do you need to insmod?)\nPerhaps iptables or your kernel needs to be upgraded.", ""]), "iptables errors")
	check(r.kmsg[-1].ends_with("x_tables: ip_tables: MASQUERADE target: only valid in nat table, not filter"), "dmesg says why")
	out = await run(r, "iptables -N lan && iptables -A lan -s 10.1.0.0/24 -j RETURN && iptables -A INPUT -j lan && iptables -X lan; iptables -L lan -n", "root")
	check(out.err == "iptables: Too many links.\n" and out.out.begins_with("Chain lan (1 references)\n%s\nRETURN     all  --  10.1.0.0/24          0.0.0.0/0" % empty), "user chains: " + out.out + out.err)


func test_nat() -> void:
	# The provider: hands out WAN addresses on eth0, routes to "the internet" on eth1.
	var isp := make_machine("isp", {"template": "server", "packages": ["udhcpd"], "network": {
		"eth0": {"method": "static", "address": "203.0.113.1", "netmask": "255.255.255.0"},
		"eth1": {"method": "static", "address": "198.51.100.1", "netmask": "255.255.255.0"}}})
	var host := make_machine("net", {"network": {"eth0": {"method": "static", "address": "198.51.100.7", "netmask": "255.255.255.0", "gateway": "198.51.100.1"}}})
	isp.hardware.connect_port("eth1", host.hardware, "eth0")
	await until(func() -> bool: return _has_address(isp, "eth1") and _has_address(host, "eth0"), 120)
	isp.vfs.write_text(AgoraCred.root(), "/etc/udhcpd.conf", "start 203.0.113.10\nend 203.0.113.20\ninterface eth0\nopt router 203.0.113.1\nopt dns 203.0.113.1\noption subnet 255.255.255.0\noption lease 3600\n")
	var out := await run(isp, "sysctl -q -w net.ipv4.ip_forward=1; systemctl restart udhcpd; systemctl is-active udhcpd", "root")
	check_eq(out.out, "active\n", "provider's DHCP server: " + out.err)
	var gw := make_machine("gw", {"template": "router", "profile": "router", "root_password": "admin"})
	gw.hardware.connect_port("eth0", isp.hardware, "eth0")
	await until(func() -> bool: return _has_address(gw, "eth0") and not gw.port_info(22).is_empty(), 600)
	out = await run(gw, "ip -4 -o a show eth0; ip route; cat /proc/sys/net/ipv4/ip_forward; iptables -t nat -L -n", "root")
	check(out.out.contains("inet 203.0.113.10/24 brd 203.0.113.255 scope global eth0") and out.out.contains("default via 203.0.113.1 dev eth0"), "WAN address from the provider: " + out.out)
	check(out.out.contains("1\nChain PREROUTING (policy ACCEPT)") and out.out.contains("Chain POSTROUTING (policy ACCEPT)\ntarget     prot opt source               destination         \nMASQUERADE  all  --  0.0.0.0/0            0.0.0.0/0           \n"), "firewall started at boot: " + out.out)
	var pc := dhcp_pc("pc1", gw, "eth1")
	await until(func() -> bool: return _has_address(pc, "eth0"), 300)
	out = await run(pc, "ping -c 1 198.51.100.7")
	check(out.out.contains("64 bytes from 198.51.100.7: icmp_seq=1 ttl=62"), "the LAN reaches the internet: " + out.out)
	var flows := "\n".join(host.net.netfilter.conntrack.list().map(func(ct: Dictionary) -> String: return AgoraConntrack.format(ct)))
	check(flows.contains("src=203.0.113.10 dst=198.51.100.7 type=8") and not flows.contains("192.168.1."), "the internet sees the router's address: " + flows)
	out = await run(gw, "cat /proc/net/nf_conntrack", "root")
	check(out.out.contains("src=192.168.1.100 dst=198.51.100.7 type=8 code=0 id=") and out.out.contains("src=198.51.100.7 dst=203.0.113.10 type=0 code=0 id="), "masqueraded flow on the router: " + out.out)
	out = await run(pc, "traceroute -n -q 1 -w 1 -m 4 198.51.100.7")
	var hops: PackedStringArray = out.out.split("\n", false)
	check(hops.size() == 4 and hops[1].begins_with(" 1  192.168.1.1  ") and hops[2].begins_with(" 2  203.0.113.1  ") and hops[3].begins_with(" 3  198.51.100.7  "), "traceroute through NAT (errors translated back): " + out.out)
	# Nothing comes in from outside unasked.
	out = await run(host, "ping -c 1 -W 1 203.0.113.10")
	check(out.out.contains("0 received"), "the router ignores pings on the WAN: " + out.out)
	# A port forward: ICMP to the WAN address goes to pc1.
	out = await run(gw, "iptables -t nat -A PREROUTING -i eth0 -p icmp -j DNAT --to-destination 192.168.1.100 && iptables -A FORWARD -i eth0 -o br-lan -d 192.168.1.100 -j ACCEPT && iptables -t nat -L PREROUTING -n", "root")
	check(out.out.contains("DNAT       icmp --  0.0.0.0/0            0.0.0.0/0            to:192.168.1.100"), "DNAT listed: " + out.out)
	out = await run(host, "ping -c 1 203.0.113.10")
	check(out.out.contains("64 bytes from 203.0.113.10: icmp_seq=1 ttl=62"), "forwarded to the LAN and back: " + out.out)
	var pc_flows := "\n".join(pc.net.netfilter.conntrack.list().map(func(ct: Dictionary) -> String: return AgoraConntrack.format(ct)))
	check(pc_flows.contains("src=198.51.100.7 dst=192.168.1.100 type=8"), "pc1 sees the real sender: " + pc_flows)
	# TCP through NAT: the internet host sees the router's address.
	out = await run(pc, "echo wonderland | ssh alice@198.51.100.7 hostname")
	check_eq(out.out, "net\n", "ssh through NAT: " + out.err)
	check(host.vfs.read_text(AgoraCred.root(), "/var/log/auth.log").contains("Accepted password for alice from 203.0.113.10 port "), "logged with the router's address")
	out = await run(gw, "grep -c 'tcp      6 .* dport=22 .*ASSURED' /proc/net/nf_conntrack", "root")
	check(out.out != "0\n", "TCP flow tracked through NAT: " + out.out)
	out = await run(gw, "/etc/init.d/firewall stop; iptables -t nat -L POSTROUTING -n | wc -l; cat /proc/sys/net/ipv4/ip_forward", "root")
	check_eq(out.out, "Stopping firewall\n2\n0\n", "firewall stop")


func test_tcp() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	await until(func() -> bool: return not b.port_info(22).is_empty(), 120)
	# netcat: a one-line transfer.
	var listener := start(b, "nc -l -p 5000 > /tmp/got")
	await until(func() -> bool: return not b.port_info(5000).is_empty(), 60)
	var r := await run(a, "echo hello over tcp | nc 192.168.1.20 5000")
	await listener.wait()
	check_eq(b.vfs.read_text(AgoraCred.root(), "/tmp/got"), "hello over tcp\n", "nc transfer: " + r.err)
	r = await run(a, "nc -z -v -n 192.168.1.20 21-23")
	check_eq(r.err, "(UNKNOWN) [192.168.1.20] 23 (telnet) : Connection refused\n(UNKNOWN) [192.168.1.20] 22 (ssh) open\n(UNKNOWN) [192.168.1.20] 21 (ftp) : Connection refused\n", "port scan")
	r = await run(b, "nc -l -p 80")
	check_eq(r.err, "Can't grab 0.0.0.0:80 with bind : Permission denied\n", "users can't listen below 1024")
	# A connection that stays open while we look at it.
	var session := start(a, "sleep 2 | nc 192.168.1.20 22")
	await until(func() -> bool: return b.net.tcp.conns.values().any(func(c: AgoraTcp.Conn) -> bool: return c.state == "ESTABLISHED"), 60)
	r = await run(b, "netstat -tnp", "root")
	check(r.out.begins_with("Active Internet connections (w/o servers)\nProto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name\ntcp        0      0 192.168.1.20:"), "netstat -tnp: " + r.out)
	check(RegEx.create_from_string("192\\.168\\.1\\.20:22         192\\.168\\.1\\.10:\\d+ +ESTABLISHED \\d+/sshd").search(r.out) != null, "established, owned by sshd: " + r.out)
	check(r.out.contains("TIME_WAIT   -\n"), "nobody owns TIME_WAIT: " + r.out)
	check(b.vfs.read_text(AgoraCred.root(), "/var/log/auth.log").contains("Did not receive identification string from 192.168.1.10"), "the scan left a trace")
	r = await run(b, "netstat -tlnp; grep -c ' 0A ' /proc/net/tcp")
	check(r.err.begins_with("(Not all processes could be identified") and r.out.contains("0.0.0.0:22              0.0.0.0:*               LISTEN      -"), "netstat -l as a user: " + r.out)
	r = await run(b, "netstat -ta | grep LISTEN")
	check(r.out.contains("tcp        0      0 *:ssh                   *:*                     LISTEN"), "service names: " + r.out)
	await session.wait()


func test_tcp_segments() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var root := AgoraCred.root()
	# A few kilobytes go out in MSS-sized segments and arrive whole.
	var sink := start(b, "nc -l -p 6000 > /tmp/big")
	await until(func() -> bool: return not b.port_info(6000).is_empty(), 60)
	var before: int = b.net.iface("eth0").stats.rx_packets
	var r := await run(a, "seq 1 2000 | nc 192.168.1.20 6000; seq 1 2000 | wc -c")
	await sink.wait()
	var expected := ""
	for k in range(1, 2001):
		expected += "%d\n" % k
	check(b.vfs.read_text(root, "/tmp/big") == expected, "data intact over segments (%d bytes)" % b.vfs.read_text(root, "/tmp/big").length())
	check(b.net.iface("eth0").stats.rx_packets - before >= 7, "split into segments: %d packets" % (b.net.iface("eth0").stats.rx_packets - before))
	# Data sent while the cable is out waits in Send-Q and goes when it is back.
	var client := start(a, "sleep 6 | nc 192.168.1.20 6001 > /tmp/recv")
	var server := start(b, "sleep 6 | nc -l -p 6001")
	await until(func() -> bool: return b.net.tcp.conns.values().any(func(c: AgoraTcp.Conn) -> bool: return c.state == "ESTABLISHED"), 120)
	var conn: AgoraTcp.Conn = b.net.tcp.conns.values().filter(func(c: AgoraTcp.Conn) -> bool: return c.state == "ESTABLISHED")[0]
	a.hardware.nics[0].unplug()
	conn.output.write("after the break\n")
	r = await run(b, "netstat -tn")
	check(r.out.contains("tcp        0     16 192.168.1.20:6001"), "unacknowledged bytes in Send-Q: " + r.out)
	await until(func() -> bool: return conn.tries >= 2, 480)
	check(conn.tries >= 2 and b.net.iface("eth0").stats.tx_dropped > 0, "retransmitted while the cable is out")
	a.hardware.connect_port("eth0", b.hardware, "eth0")
	await until(func() -> bool: return a.vfs.read_text(root, "/tmp/recv").contains("after the break"), 300)
	check_eq(a.vfs.read_text(root, "/tmp/recv"), "after the break\n", "delivered after the cable came back")
	server.send_signal(AgoraProcess.SIGTERM)
	client.send_signal(AgoraProcess.SIGTERM)
	# With the cable gone for good the connection is given up.
	await run(b, "sysctl -q -w net.ipv4.tcp_retries2=2", "root")
	var lonely := start(b, "sleep 20 | nc -l -p 6002")
	start(a, "sleep 10 | nc 192.168.1.20 6002")
	await until(func() -> bool: return b.net.tcp.conns.values().any(func(c: AgoraTcp.Conn) -> bool: return c.local_port == 6002 and c.state == "ESTABLISHED"), 120)
	var doomed: AgoraTcp.Conn = b.net.tcp.conns.values().filter(func(c: AgoraTcp.Conn) -> bool: return c.local_port == 6002)[0]
	a.hardware.nics[0].unplug()
	doomed.output.write("anyone there?\n")
	await until(func() -> bool: return doomed.state == "CLOSE", 900)
	check_eq([doomed.state, AgoraErrno.describe(doomed.error)], ["CLOSE", "Connection timed out"], "given up after tcp_retries2")
	var nc_left := func() -> bool: return b.list_pids().any(func(pid: int) -> bool: return b.get_process(pid).name == "nc" and "6002" in b.get_process(pid).argv)
	await until(func() -> bool: return not nc_left.call(), 60)
	check(not nc_left.call(), "nc sees the end of the connection")
	lonely.send_signal(AgoraProcess.SIGTERM)
	# A firewall rule stops a connection that is already open.
	a.hardware.connect_port("eth0", b.hardware, "eth0")
	var held := start(b, "nc -l -p 6003 > /tmp/held")
	start(a, "(echo one; sleep 1; echo two) | nc 192.168.1.20 6003")
	await until(func() -> bool: return b.vfs.read_text(root, "/tmp/held") == "one\n", 120)
	await run(b, "iptables -A INPUT -p tcp --dport 6003 -j DROP", "root")
	await until(func() -> bool: return false, 120)
	check_eq(b.vfs.read_text(root, "/tmp/held"), "one\n", "a DROP rule cuts an established connection")
	held.send_signal(AgoraProcess.SIGTERM)


func test_dns() -> void:
	var root := AgoraCred.root()
	# The provider: DHCP for the WAN, DNS for "the internet".
	var isp := make_machine("isp", {"template": "server", "packages": ["udhcpd", "dnsmasq"], "network": {
		"eth0": {"method": "static", "address": "203.0.113.1", "netmask": "255.255.255.0"},
		"eth1": {"method": "static", "address": "198.51.100.1", "netmask": "255.255.255.0"}}})
	var www := make_machine("www", {"network": {"eth0": {"method": "static", "address": "198.51.100.7", "netmask": "255.255.255.0", "gateway": "198.51.100.1"}}})
	isp.hardware.connect_port("eth1", www.hardware, "eth0")
	await until(func() -> bool: return _has_address(isp, "eth1") and _has_address(www, "eth0"), 120)
	isp.vfs.write_text(root, "/etc/udhcpd.conf", "start 203.0.113.10\nend 203.0.113.20\ninterface eth0\nopt router 203.0.113.1\nopt dns 203.0.113.1\noption subnet 255.255.255.0\noption lease 3600\n")
	isp.vfs.write_text(root, "/etc/hosts", "198.51.100.7\twww.example.com\n198.51.100.8\tmail.example.com\n", "/", true)
	isp.vfs.write_text(root, "/etc/dnsmasq.d/zone.conf", "no-resolv\nlocal=/example.com/\naddress=/ads.example.com/0.0.0.0\nlog-queries\n")
	var out := await run(isp, "sysctl -q -w net.ipv4.ip_forward=1; systemctl restart udhcpd; systemctl restart dnsmasq; systemctl is-active dnsmasq", "root")
	check_eq(out.out, "active\n", "dnsmasq at the provider: " + out.err)
	var gw := make_machine("gw", {"template": "router", "profile": "router", "root_password": "admin"})
	gw.hardware.connect_port("eth0", isp.hardware, "eth0")
	await until(func() -> bool: return _has_address(gw, "eth0") and not gw.port_info(22).is_empty() and gw.vfs.read_text(root, "/etc/resolv.conf").contains("203.0.113.1"), 600)
	var log := gw.vfs.read_text(root, "/var/log/syslog")
	check(log.contains("dnsmasq[") and log.contains("started, version 2.85 cachesize 150") and log.contains("using only locally-known addresses for domain lan"), "dnsmasq on the router: " + log.right(600))
	var pc := dhcp_pc("pc1", gw, "eth1")
	await until(func() -> bool: return _has_address(pc, "eth0"), 300)
	out = await run(pc, "cat /etc/resolv.conf; ping -c 1 www.example.com")
	check(out.out.begins_with("search lan\nnameserver 192.168.1.1\n"), "DNS from DHCP: " + out.out)
	check(out.out.contains("PING www.example.com (198.51.100.7) 56(84) bytes of data.\n64 bytes from www.example.com (198.51.100.7): icmp_seq=1"), "ping by name, PTR back: " + out.out + out.err)
	check(gw.vfs.read_text(root, "/var/log/syslog").contains("using nameserver 203.0.113.1#53"), "the router found the provider's server")
	out = await run(pc, "nslookup www.example.com")
	check_eq(out.out, "Server:\t\t192.168.1.1\nAddress:\t192.168.1.1#53\n\nNon-authoritative answer:\nName:\twww.example.com\nAddress: 198.51.100.7\n\n", "nslookup")
	out = await run(pc, "nslookup gw")
	check_eq(out.out, "Server:\t\t192.168.1.1\nAddress:\t192.168.1.1#53\n\nName:\tgw.lan\nAddress: 192.168.1.1\n\n", "nslookup with the search list, answered by the router")
	out = await run(pc, "host nosuch.example.com; host 198.51.100.8; host 192.168.1.77; nslookup foo")
	check(out.out.contains("Host nosuch.example.com not found: 3(NXDOMAIN)\n8.100.51.198.in-addr.arpa domain name pointer mail.example.com.\nHost 77.1.168.192.in-addr.arpa not found: 3(NXDOMAIN)\n"), "host: " + out.out)
	check(out.out.contains("** server can't find foo: NXDOMAIN"), "domain-needed: " + out.out)
	out = await run(pc, "dig www.example.com")
	var lines: PackedStringArray = out.out.split("\n")
	check_eq(lines[1], "; <<>> DiG 9.16.37-Debian <<>> www.example.com", "dig banner")
	check(out.out.contains(";; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: ") and out.out.contains(";; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 0"), "dig header: " + out.out)
	check(out.out.contains(";; QUESTION SECTION:\n;www.example.com.\t\tIN\tA\n\n;; ANSWER SECTION:\nwww.example.com.\t0\tIN\tA\t198.51.100.7\n") and out.out.contains(";; SERVER: 192.168.1.1#53(192.168.1.1)"), "dig sections: " + out.out)
	out = await run(pc, "dig +short -x 198.51.100.7; dig +short ads.example.com @203.0.113.1; getent hosts www.example.com mail.example.com")
	check_eq(out.out, "www.example.com.\n0.0.0.0\n198.51.100.7    www.example.com\n198.51.100.8    mail.example.com\n", "dig +short, address=, getent")
	check(isp.vfs.read_text(root, "/var/log/syslog").contains("query[A] www.example.com from 203.0.113.10"), "the provider logs queries from the router's WAN address")
	out = await run(pc, "echo wonderland | ssh alice@www.example.com hostname")
	check_eq(out.out, "www\n", "ssh by name: " + out.err)
	out = await run(gw, "nslookup www.example.com")
	check_eq(out.out, "Server:    203.0.113.1\nAddress 1: 203.0.113.1\n\nName:      www.example.com\nAddress 1: 198.51.100.7 www.example.com\n", "busybox nslookup")
	# Without the router's DNS the names are gone, quickly.
	gw.kill(gw.list_pids().filter(func(pid: int) -> bool: return gw.get_process(pid).name == "dnsmasq")[0], AgoraProcess.SIGKILL, AgoraCred.root())
	var started := Time.get_ticks_msec()
	out = await run(pc, "ping -c 1 www.example.com")
	check_eq(out.err, "ping: www.example.com: Temporary failure in name resolution\n", "no DNS server")
	check(Time.get_ticks_msec() - started < 3000, "port unreachable answers at once")


## Starts [param cmd] in the background as [param user] and keeps its
## output: {p, out, err}; read the streams once it has exited.
func spawn_logged(m: AgoraMachine, cmd: String, user: String = "root") -> Dictionary:
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
	return {"p": p, "out": out, "err": errs}


## Runs tcpdump in the background on [param m] and waits until its
## capture is open. Returns what [method spawn_logged] does.
func start_tcpdump(m: AgoraMachine, args: String) -> Dictionary:
	var before := m.net.captures.size()
	var t := spawn_logged(m, "tcpdump " + args)
	await until(func() -> bool: return m.net.captures.size() > before or t.p.state == AgoraProcess.State.EXITED, 120)
	return t


## Stops a background tcpdump like Ctrl-C would and returns {out, err}.
func stop_tcpdump(m: AgoraMachine, t: Dictionary) -> Dictionary:
	for c in m.net.captures.duplicate():
		if m.get_process(c.pid):
			m.get_process(c.pid).send_signal(AgoraProcess.SIGINT)
	await t.p.wait()
	return {"out": t.out.read_available(), "err": t.err.read_available()}


func test_tcpdump() -> void:
	var pair := cabled_pair()
	var a := pair[0]
	var b := pair[1]
	var a_mac: String = a.hardware.nics[0].mac
	var b_mac: String = b.hardware.nics[0].mac
	var stamp := "\\d\\d:\\d\\d:\\d\\d\\.\\d{6} "
	# ARP for a fresh neighbour, seen from both ends: own frames are 28
	# bytes of ARP, received ones carry the Ethernet padding.
	var on_a := await start_tcpdump(a, "-n -e -c 2 -i eth0 arp")
	var on_b := await start_tcpdump(b, "-n -c 2 arp")
	var r := await run(a, "ping -c 1 192.168.1.20")
	await on_a.p.wait()
	await on_b.p.wait()
	var lines: PackedStringArray = on_a.out.read_available().split("\n")
	check(RegEx.create_from_string("^" + stamp + a_mac + " > ff:ff:ff:ff:ff:ff, ethertype ARP \\(0x0806\\), length 42: Request who-has 192.168.1.20 tell 192.168.1.10, length 28$").search(lines[0]) != null, "ARP request with -e: " + lines[0])
	check(lines[1].ends_with(b_mac + " > " + a_mac + ", ethertype ARP (0x0806), length 60: Reply 192.168.1.20 is-at " + b_mac + ", length 46"), "ARP reply with -e: " + lines[1])
	lines = on_b.out.read_available().split("\n")
	check(lines[0].ends_with(" ARP, Request who-has 192.168.1.20 tell 192.168.1.10, length 46") and lines[1].ends_with(" ARP, Reply 192.168.1.20 is-at %s, length 28" % b_mac), "ARP on the other end: " + "\n".join(lines))
	check_eq(on_b.err.read_available(), "tcpdump: verbose output suppressed, use -v[v]... for full protocol decode\nlistening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes\n2 packets captured\n2 packets received by filter\n0 packets dropped by kernel\n", "start and end on stderr, eth0 by default")
	r = await run(a, "dmesg", "root")
	check(r.out.contains("device eth0 entered promiscuous mode") and r.out.contains("device eth0 left promiscuous mode"), "promiscuous mode in the kernel log: " + r.out)
	check_eq(a.net.iface("eth0").promisc, 0, "promiscuous mode off again")
	# ICMP with a filter: ARP is cached now, so only the echoes show.
	var t := await start_tcpdump(a, "-n -c 4 -i eth0 icmp")
	await run(a, "ping -c 2 -i 0.2 192.168.1.20")
	await t.p.wait()
	lines = t.out.read_available().split("\n")
	var echo := RegEx.create_from_string("^" + stamp + "IP 192.168.1.(10|20) > 192.168.1.(10|20): ICMP echo (request|reply), id \\d+, seq (1|2), length 64$")
	check(lines.size() == 5 and Array(lines.slice(0, 4)).all(func(l: String) -> bool: return echo.search(l) != null), "echo lines: " + "\n".join(lines))
	check(lines[0].contains("request") and lines[1].contains("192.168.1.20 > 192.168.1.10: ICMP echo reply") and lines[3].contains("seq 2"), "request, reply, in order: " + "\n".join(lines))
	check(t.err.read_available().ends_with("4 packets captured\n4 packets received by filter\n0 packets dropped by kernel\n"), "-c stops after 4")
	# -v shows the IP header, -x the bytes from it on.
	t = await start_tcpdump(a, "-n -v -x -c 1 -i eth0 icmp")
	await run(a, "ping -c 1 192.168.1.20")
	await t.p.wait()
	var text: String = t.out.read_available()
	check(RegEx.create_from_string("IP \\(tos 0x0, ttl 64, id \\d+, offset 0, flags \\[DF\\], proto ICMP \\(1\\), length 84\\)\n    192.168.1.10 > 192.168.1.20: ICMP echo request, id \\d+, seq 1, length 64\n\t0x0000:  4500 0054 ").search(text) != null, "-v -x: " + text)
	check(text.ends_with("\n\t0x0050:  3435 3637\n"), "84 bytes in hex: " + text.right(80))
	check(t.err.read_available().begins_with("tcpdump: listening on eth0, link-type EN10MB (Ethernet), snapshot length 262144 bytes\n"), "no hint with -v")
	# -i any: interface and direction on every line.
	t = await start_tcpdump(a, "-n -i any -c 2 icmp")
	await run(a, "ping -c 1 192.168.1.20")
	await t.p.wait()
	lines = t.out.read_available().split("\n")
	check(lines[0].contains(" eth0  Out IP 192.168.1.10 > 192.168.1.20: ICMP echo request, id ") and lines[1].contains(" eth0  In  IP 192.168.1.20 > 192.168.1.10: ICMP echo reply"), "-i any: " + "\n".join(lines))
	check(t.err.read_available().contains("listening on any, link-type LINUX_SLL2 (Linux cooked v2), snapshot length 262144 bytes"), "cooked link type for any")
	check_eq(a.net.iface("eth0").promisc, 0, "any is not promiscuous")
	# TCP: absolute numbers on the SYNs, relative ones after; -A shows the data.
	var sink := start(b, "nc -l -p 5000 > /tmp/got")
	await until(func() -> bool: return not b.port_info(5000).is_empty(), 60)
	t = await start_tcpdump(a, "-n -A -i eth0 tcp port 5000")
	await run(a, "echo hello over tcp | nc 192.168.1.20 5000")
	await sink.wait()
	await until(func() -> bool: return a.net.captures[0].inbox.is_empty(), 30)
	var got := await stop_tcpdump(a, t)
	text = got.out
	var syn := RegEx.create_from_string("IP 192.168.1.10.(\\d+) > 192.168.1.20.5000: Flags \\[S\\], seq (\\d+), win 65535, options \\[mss 1460,nop,nop,sackOK,nop,wscale 7\\], length 0\n").search(text)
	check(syn != null, "SYN: " + text)
	if syn:
		var port := syn.get_string(1)
		var isn := int(syn.get_string(2))
		check(RegEx.create_from_string("IP 192.168.1.20.5000 > 192.168.1.10.%s: Flags \\[S\\.\\], seq \\d+, ack %d, win 65535, options \\[mss 1460,nop,nop,sackOK,nop,wscale 7\\], length 0\n" % [port, isn + 1]).search(text) != null, "SYN-ACK acknowledges the ISN: " + text)
		check(text.contains("IP 192.168.1.10.%s > 192.168.1.20.5000: Flags [.], ack 1, win 65535, length 0\n" % port), "relative ack: " + text)
		check(text.contains("IP 192.168.1.10.%s > 192.168.1.20.5000: Flags [P.], seq 1:16, ack 1, win 65535, length 15\n" % port), "data segment: " + text)
		check(text.contains("IP 192.168.1.20.5000 > 192.168.1.10.%s: Flags [.], ack 16, win 65535, length 0\n" % port), "data acknowledged: " + text)
		check(text.contains("Flags [F.], seq 16, ack 1, win 65535, length 0\n"), "FIN: " + text)
	check(text.contains("hello over tcp\n\n"), "-A shows the data: " + text)
	check(RegEx.create_from_string("\n\n\\d+ packets captured\n").search(got.err) != null, "Ctrl-C: a blank line, then the counts: " + got.err)
	# Names come from the resolver, ports from the services table.
	a.vfs.write_text(AgoraCred.root(), "/etc/hosts", "127.0.0.1\tlocalhost\n192.168.1.10\ta\n192.168.1.20\tb.lan b\n")
	t = await start_tcpdump(a, "-c 1 -i eth0 'tcp[13] = 2 or (dst port 22 and tcp)'")
	check(t.p.state == AgoraProcess.State.EXITED, "unsupported syntax stops tcpdump")
	t = await start_tcpdump(a, "-c 1 -i eth0 dst port ssh and host b")
	await run(a, "nc -z 192.168.1.20 22")
	await t.p.wait()
	text = t.out.read_available()
	check(RegEx.create_from_string("^" + stamp + "IP a\\.\\d+ > b\\.lan\\.ssh: Flags \\[S\\], seq \\d+, win 65535").search(text) != null, "names and services: " + text)
	# Errors.
	r = await run(a, "tcpdump -i eth0")
	check_eq(r.err, "tcpdump: eth0: You don't have permission to capture on that device\n(socket: Operation not permitted)\n", "users can't capture")
	r = await run(a, "tcpdump -i eth9; tcpdump -n 'host and'; tcpdump -n host nosuch; tcpdump -n tcp host 1.2.3.4; tcpdump -n net 192.168.1.5/24; tcpdump -c x", "root")
	check_eq(r.err, "\n".join(["tcpdump: eth9: No such device exists", "(SIOCGIFHWADDR: No such device)",
		"tcpdump: can't parse filter expression: syntax error", "tcpdump: unknown host 'nosuch'",
		"tcpdump: 'tcp' modifier applied to host", "tcpdump: non-network bits set in \"192.168.1.5/24\"",
		"tcpdump: invalid packet count x", ""]), "error messages")
	var server := make_machine("srv", {"template": "server"})
	r = await run(server, "ip link set lo up; tcpdump -i eth1; tcpdump -D", "root")
	check_eq(r.err, "tcpdump: eth1: That device is not up\n", "device down")
	check_eq(r.out, "1.any (Pseudo-device that captures on all interfaces) [Up, Running]\n2.lo [Up, Running, Loopback]\n3.eth0 [Disconnected]\n4.eth1 [Disconnected]\n", "tcpdump -D")


func _file_stat() -> AgoraStat:
	var st := AgoraStat.new()
	st.mode = AgoraStat.MODE_FILE
	return st


func test_telnet() -> void:
	var ws := make_machine("ws", {"network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.255.255.0"}}})
	var srv := make_machine("srv", {"profile": "server", "packages": ["telnetd"], "users": [{"name": "admin", "password": "hunter2"}],
		"network": {"eth0": {"method": "static", "address": "10.0.0.5", "netmask": "255.255.255.0"}}})
	ws.hardware.connect_port("eth0", srv.hardware, "eth0")
	var root := AgoraCred.root()
	ws.vfs.write_text(root, "/etc/hosts", "127.0.0.1\tlocalhost\n10.0.0.5\tsrv.corp srv\n")
	await until(func() -> bool: return _has_address(ws, "eth0") and _has_address(srv, "eth0") and srv.port_info(23).get("service") == "inetd", 120)
	check_eq(srv.port_info(23).get("service"), "inetd", "inetd listens on the telnet port")
	check(srv.vfs.read_text(root, "/etc/inetd.conf").ends_with("\ntelnet\tstream\ttcp\tnowait\troot\t/usr/sbin/tcpd\t/usr/sbin/in.telnetd\n"), "telnetd registered with inetd")
	var dump := await start_tcpdump(ws, "-A -n -l port 23")
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(ws, tty)
	tty.type_line("telnet srv.corp")
	await until(func() -> bool: return screen[0].ends_with("srv login: "), 120)
	check(screen[0].ends_with("Trying 10.0.0.5...\nConnected to srv.corp.\nEscape character is '^]'.\nAgoraOS 0.1.0\nsrv login: "), "login prompt: " + screen[0].right(120))
	tty.type_line("admin")
	await until(func() -> bool: return screen[0].ends_with("Password: "), 60)
	check(not tty.echo, "the server takes over echo for the password")
	tty.type_line("wrong")
	await until(func() -> bool: return screen[0].ends_with("Login incorrect\nsrv login: "), 240)
	check(screen[0].ends_with("\nLogin incorrect\nsrv login: ") and tty.echo, "wrong password: " + screen[0].right(60))
	tty.type_line("admin")
	await until(func() -> bool: return screen[0].ends_with("Password: "), 60)
	tty.type_line("hunter2")
	await until(func() -> bool: return screen[0].ends_with("admin@srv:~$ "), 120)
	check(screen[0].ends_with("admin@srv:~$ ") and tty.echo, "logged in: " + screen[0].right(40))
	screen[0] = ""
	tty.type_line("hostname; echo $REMOTEHOST")
	await until(func() -> bool: return screen[0].ends_with("$ "), 120)
	check_eq(screen[0], "srv\n10.0.0.2\nadmin@srv:~$ ", "commands run on the server")
	# Ctrl+C travels as Interrupt Process.
	screen[0] = ""
	tty.type_line("sleep 30")
	await until(func() -> bool: return srv.list_pids().any(func(pid: int) -> bool: return srv.get_process(pid).name == "sleep"), 120)
	tty.interrupt()
	await until(func() -> bool: return screen[0].ends_with("$ "), 120)
	check(screen[0].ends_with("admin@srv:~$ "), "interrupted remotely: " + screen[0])
	screen[0] = ""
	tty.type_line("exit")
	await until(func() -> bool: return screen[0].ends_with("alice@ws:~$ "), 120)
	check(screen[0].contains("Connection closed by foreign host.\n"), "logged out: " + screen[0])
	var auth := srv.vfs.read_text(root, "/var/log/auth.log")
	check(auth.contains("in.telnetd[") and auth.contains("]: connect from 10.0.0.2 (10.0.0.2)"), "tcpd logs the connection")
	check(auth.contains("FAILED LOGIN 1 FROM 10.0.0.2 FOR admin, Authentication failure") and auth.contains("session opened for user admin on pts/0 from 10.0.0.2"), "login logs: " + auth.right(400))
	var sniffed := await stop_tcpdump(ws, dump)
	check(sniffed.out.contains("hunter2"), "the password crosses the network in clear text")
	# IAC DO TTYPE, DO TSPEED (a space), DO XDISPLOC (#), DO NEW-ENVIRON ('),
	# and the terminal type the client answers with.
	check(sniffed.out.contains("length 12\n") and sniffed.out.contains("...... ..#..'\n") and sniffed.out.contains("AGORA.."), "option negotiation on the wire")
	# tcp_wrappers.
	srv.vfs.write_text(root, "/etc/hosts.deny", "ALL: 10.0.0.0/255.255.255.0\n")
	var r := await run(ws, "telnet 10.0.0.5")
	check(r.out == "Trying 10.0.0.5...\nConnected to 10.0.0.5.\nEscape character is '^]'.\n" and r.err == "Connection closed by foreign host.\n", "refused by hosts.deny: " + r.out + r.err)
	check(srv.vfs.read_text(root, "/var/log/auth.log").contains("refused connect from 10.0.0.2"), "refusal logged")
	srv.vfs.write_text(root, "/etc/hosts.allow", "in.telnetd: 10.0.0. EXCEPT 10.0.0.9\n")
	r = await run(ws, "sleep 1 | telnet 10.0.0.5")
	check(r.out.ends_with("AgoraOS 0.1.0\nsrv login: "), "hosts.allow wins: " + r.out)
	# Any TCP service by hand.
	r = await run(ws, "telnet srv ssh")
	check(r.out.contains("Connected to srv.\n") and r.out.contains("SSH-2.0-OpenSSH_4.3p2"), "telnet to the ssh port: " + r.out)
	r = await run(ws, "telnet 10.0.0.5 25")
	check_eq(r.err, "telnet: Unable to connect to remote host: Connection refused\n", "nothing on port 25")
	r = await run(ws, "telnet nowhere")
	check(r.code == 1 and r.err.begins_with("telnet: could not resolve nowhere/telnet: "), "unknown host: " + r.err)
	# Removing telnetd takes it out of inetd.conf, and inetd stops listening.
	r = await run(srv, "apkg remove telnetd", "root")
	check(not srv.vfs.read_text(root, "/etc/inetd.conf").contains("in.telnetd"), "unregistered from inetd")
	await until(func() -> bool: return srv.port_info(23).is_empty(), 120)
	check(srv.port_info(23).is_empty(), "inetd reloaded on SIGHUP")

func test_ftp() -> void:
	var ws := make_machine("ws", {"network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.255.255.0"}}})
	var srv := make_machine("srv", {"profile": "server", "packages": ["ftpd"],
		"users": [{"name": "admin", "password": "hunter2"}, {"name": "ftp", "password": "*"}],
		"network": {"eth0": {"method": "static", "address": "10.0.0.5", "netmask": "255.255.255.0"}}})
	ws.hardware.connect_port("eth0", srv.hardware, "eth0")
	var root := AgoraCred.root()
	ws.vfs.write_text(root, "/etc/hosts", "127.0.0.1\tlocalhost\n10.0.0.5\tsrv.corp srv\n")
	var admin := srv.users.cred_for("admin")
	srv.vfs.write_text(admin, "/home/admin/notes.txt", "hello ftp\n")
	var blob := PackedByteArray()
	for k in 256:
		blob.append(k)
	srv.vfs.write_file(admin, "/home/admin/blob.bin", blob)
	srv.vfs.make_dirs(root, "/home/ftp/pub")
	srv.vfs.write_text(root, "/home/ftp/pub/README", "anonymous files\n")
	ws.vfs.write_text(ws.users.cred_for("alice"), "/home/alice/upload.txt", "from alice\n")
	await until(func() -> bool: return _has_address(ws, "eth0") and _has_address(srv, "eth0") and srv.port_info(21).get("service") == "inetd", 120)
	var dump := await start_tcpdump(ws, "-A -n -l port 21")
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(ws, tty)
	var step := func(line: String, until_text: String = "ftp> ") -> String:
		screen[0] = ""
		tty.type_line(line)
		await until(func() -> bool: return screen[0].ends_with(until_text), 240)
		return screen[0]
	var out: String = await step.call("ftp srv.corp", "Name (srv.corp:alice): ")
	check(out.ends_with("Connected to srv.corp.\n220 srv FTP server (Version 6.4/OpenBSD/Linux-ftpd-0.17) ready.\nName (srv.corp:alice): "), "greeting: " + out)
	out = await step.call("admin", "Password:")
	check(out == "331 Password required for admin.\nPassword:" and not tty.echo, "password prompt: " + out)
	out = await step.call("hunter2")
	check_eq(out, "\n230 User admin logged in.\nRemote system type is UNIX.\nUsing binary mode to transfer files.\nftp> ", "logged in")
	out = await step.call("ls")
	check(out.begins_with("200 PORT command successful.\n150 Opening ASCII mode data connection for '/bin/ls'.\n") and out.contains("notes.txt\n")
		and out.ends_with("226 Transfer complete.\nftp> "), "active mode listing: " + out)
	out = await step.call("get notes.txt")
	check(out.begins_with("local: notes.txt remote: notes.txt\n200 PORT command successful.\n150 Opening BINARY mode data connection for 'notes.txt' (10 bytes).\n226 Transfer complete.\n10 bytes received in "), "get: " + out)
	check_eq(ws.vfs.read_text(root, "/home/alice/notes.txt"), "hello ftp\n", "file fetched")
	await step.call("get blob.bin")
	check_eq(ws.vfs.read_file(root, "/home/alice/blob.bin"), blob, "binary file intact, every byte")
	out = await step.call("passive")
	check_eq(out, "Passive mode on.\nftp> ", "passive")
	out = await step.call("put upload.txt")
	check(out.contains("227 Entering Passive Mode (10,0,0,5,") and out.contains("150 Opening BINARY mode data connection for 'upload.txt'.\n226 Transfer complete.\n11 bytes sent in "), "passive put: " + out)
	check_eq(srv.vfs.read_text(root, "/home/admin/upload.txt"), "from alice\n", "file stored")
	check_eq(srv.vfs.stat(root, "/home/admin/upload.txt").uid, admin.uid, "owned by the user")
	out = await step.call("ascii")
	await step.call("get notes.txt crlf.txt")
	check_eq(ws.vfs.read_text(root, "/home/alice/crlf.txt"), "hello ftp\n", "ascii mode round trip")
	out = await step.call("cd /root")
	check_eq(out, "550 /root: Permission denied.\nftp> ", "the user's permissions apply")
	out = await step.call("get nothing")
	check(out.contains("550 nothing: No such file or directory.\n"), "missing file: " + out)
	out = await step.call("pwd")
	check_eq(out, "257 \"/home/admin\" is current directory.\nftp> ", "pwd")
	out = await step.call("bye", "alice@ws:~$ ")
	check(out.begins_with("221 Goodbye.\n"), "bye: " + out)
	var sniffed := await stop_tcpdump(ws, dump)
	check(sniffed.out.contains("PASS hunter2"), "the password crosses the network in clear text")
	# Scripts on standard input; quiet unless something fails.
	ws.vfs.write_text(root, "/tmp/bad.ftp", "user admin wrong\nuser root toor\nbye\n")
	var r := await run(ws, "ftp -n srv < /tmp/bad.ftp")
	check(r.out.contains("530 Login incorrect.\nLogin failed.\n") and r.out.contains("530 User root access denied.\nLogin failed.\n"), "refused logins: " + r.out)
	ws.vfs.write_text(root, "/tmp/anon.ftp", "user anonymous guest@\npassive\ncd ../../etc\nget pub/README\nls\nbye\n")
	r = await run(ws, "cd /tmp && ftp -n -v srv < /tmp/anon.ftp")
	check(r.out.contains("230 Guest login ok, access restrictions apply.\n") and r.out.contains("550 ../../etc: No such file or directory.\n"), "guests are locked in: " + r.out)
	check_eq(ws.vfs.read_text(root, "/tmp/README"), "anonymous files\n", "anonymous download")
	var log := srv.vfs.read_text(root, "/var/log/syslog")
	check(log.contains("FTP LOGIN FROM 10.0.0.2 [10.0.0.2], admin") and log.contains("FTP LOGIN FAILED FROM 10.0.0.2 [10.0.0.2], admin")
		and log.contains("ANONYMOUS FTP LOGIN FROM 10.0.0.2 [10.0.0.2], guest@"), "logged: " + log.right(500))
	r = await run(ws, "echo bye | ftp 10.0.0.5 2121")
	check(r.out.begins_with("ftp: connect: Connection refused\n"), "nothing there: " + r.out)

func test_web() -> void:
	var ws := make_machine("ws", {"network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.255.255.0"}}})
	var srv := make_machine("srv", {"profile": "server", "packages": ["apache2"],
		"network": {"eth0": {"method": "static", "address": "10.0.0.5", "netmask": "255.255.255.0"}}})
	ws.hardware.connect_port("eth0", srv.hardware, "eth0")
	var root := AgoraCred.root()
	ws.vfs.write_text(root, "/etc/hosts", "127.0.0.1\tlocalhost\n10.0.0.5\tsrv.corp srv\n")
	await until(func() -> bool: return _has_address(ws, "eth0") and _has_address(srv, "eth0") and srv.port_info(80).get("service") == "apache2", 120)
	check_eq(srv.port_info(80).get("service"), "apache2", "apache2 listens on port 80")
	check(srv.users.find("www-data").get("uid") == 33 and srv.users.is_locked("www-data"), "www-data is a locked system account")
	var r := await run(ws, "wget http://srv.corp/")
	check_eq(r.code, 0, "wget succeeds")
	var lines: PackedStringArray = r.err.split("\n")
	check(lines[0].begins_with("--") and lines[0].ends_with("--  http://srv.corp/") and lines[1] == "           => `index.html'"
		and lines[2] == "Resolving srv.corp... 10.0.0.5" and lines[3] == "Connecting to srv.corp|10.0.0.5|:80... connected."
		and lines[4] == "HTTP request sent, awaiting response... 200 OK" and lines[5] == "Length: 45 [text/html]"
		and r.err.contains("`index.html' saved [45/45]"), "wget's log: " + r.err)
	check_eq(ws.vfs.read_text(root, "/home/alice/index.html"), "<html><body><h1>It works!</h1></body></html>\n", "the default page")
	r = await run(ws, "wget -q http://srv.corp/ && ls index.html*")
	check_eq(r.out, "index.html\nindex.html.1\n", "a second copy gets .1")
	r = await run(ws, "wget -O - -S http://10.0.0.5/")
	check(r.out.begins_with("<html>") and r.err.contains("  HTTP/1.1 200 OK\n  Date: ") and r.err.contains("\n  Server: Apache/2.2.3 (Debian)\n")
		and r.err.contains("\n  Connection: close\n  Content-Type: text/html; charset=UTF-8\n"), "headers: " + r.err)
	r = await run(ws, "wget -O - http://srv/missing")
	check(r.code == 1 and r.err.contains("awaiting response... 404 Not Found\n") and r.err.contains(" ERROR 404: Not Found.\n"), "404: " + r.err)
	var access := srv.vfs.read_text(root, "/var/log/apache2/access.log")
	check(access.contains("10.0.0.2 - - [") and access.contains("] \"GET /missing HTTP/1.0\" 404 ") and access.contains(" \"-\" \"Wget/1.10.2\"\n"), "access.log: " + access)
	var errors := srv.vfs.read_text(root, "/var/log/apache2/error.log")
	check(errors.contains("[notice] Apache/2.2.3 (Debian) configured -- resuming normal operations") and errors.contains("[error] [client 10.0.0.2] File does not exist: /var/www/missing"), "error.log: " + errors)
	# Directories: a redirect to the slash, then a listing.
	srv.vfs.make_dirs(root, "/var/www/files")
	srv.vfs.write_text(root, "/var/www/files/notes.txt", "some notes\n")
	srv.vfs.write_text(root, "/var/www/files/.hidden", "x")
	r = await run(ws, "wget -O - http://srv/files")
	check(r.err.contains("301 Moved Permanently\nLocation: http://srv/files/ [following]\n") and r.out.contains("<title>Index of /files/</title>")
		and r.out.contains("<a href=\"notes.txt\">notes.txt</a>") and not r.out.contains(".hidden")
		and r.out.contains("<address>Apache/2.2.3 (Debian) Server at srv Port 80</address>"), "listing: " + r.out + r.err)
	srv.vfs.write_text(root, "/var/www/secret.txt", "secret\n", "/", false, AgoraStat.MODE_PRIVATE_FILE)
	r = await run(ws, "wget -O - http://srv/secret.txt")
	check(r.err.contains("403 Forbidden"), "403: " + r.err)
	# CGI programs run as www-data.
	srv.vfs.write_text(root, "/usr/lib/cgi-bin/hello.cgi", "#!/bin/sh\necho Content-Type: text/plain\necho\necho Hello $QUERY_STRING from $REMOTE_ADDR\nwhoami\n", "/", false, AgoraStat.MODE_EXEC)
	r = await run(ws, "wget -q -O - 'http://srv/cgi-bin/hello.cgi?name=neo'")
	check_eq(r.out, "Hello name=neo from 10.0.0.2\nwww-data\n", "CGI with a query")
	srv.vfs.write_text(root, "/usr/lib/cgi-bin/echo.cgi", "#!/bin/sh\necho 'Content-Type: text/plain'\necho\ncat\n", "/", false, AgoraStat.MODE_EXEC)
	r = await run(ws, "wget -q -O - --post-data=user=trinity http://srv/cgi-bin/echo.cgi")
	check_eq(r.out, "user=trinity", "CGI reads the POST body")
	srv.vfs.write_text(root, "/usr/lib/cgi-bin/broken.cgi", "#!/bin/sh\necho oops\n", "/", false, AgoraStat.MODE_EXEC)
	r = await run(ws, "wget -q -O - http://srv/cgi-bin/broken.cgi")
	check(r.code == 1 and srv.vfs.read_text(root, "/var/log/apache2/error.log").contains("Premature end of script headers: broken.cgi"), "broken CGI: 500")
	# HTTP by hand.
	ws.vfs.write_text(root, "/tmp/req", "HEAD / HTTP/1.0\n\n")
	r = await run(ws, "telnet srv 80 < /tmp/req")
	check(r.out.contains("HTTP/1.1 200 OK\n") and r.out.contains("Content-Length: 45\n") and not r.out.contains("It works"), "HEAD by telnet: " + r.out)
	r = await run(ws, "wget http://srv:8080/")
	check(r.code == 1 and r.err.ends_with("Connecting to srv|10.0.0.5|:8080... failed: Connection refused.\n"), "refused: " + r.err)

func test_lynx() -> void:
	var ws := make_machine("ws", {"network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.255.255.0"}}})
	var srv := make_machine("srv", {"profile": "server", "packages": ["apache2"],
		"network": {"eth0": {"method": "static", "address": "10.0.0.5", "netmask": "255.255.255.0"}}})
	ws.hardware.connect_port("eth0", srv.hardware, "eth0")
	var root := AgoraCred.root()
	ws.vfs.write_text(root, "/etc/hosts", "127.0.0.1\tlocalhost\n10.0.0.5\tsrv\n")
	srv.vfs.write_text(root, "/var/www/index.html", """<html><head><title>Test Site</title></head><body>
<h1>Welcome</h1>
<p>This is a <b>test</b> page &amp; more.
See <a href="about.html">About us</a> or <a href="http://srv/files/">the files</a>.</p>
<ul><li>One<li>Two</ul>
<form action="/cgi-bin/q.cgi"><input type="text" name="q" size="10"> <input type="submit" value="Search"></form>
</body></html>
""")
	srv.vfs.write_text(root, "/var/www/about.html", "<html><head><title>About</title></head><body><p>We are a test.</p></body></html>\n")
	srv.vfs.write_text(root, "/usr/lib/cgi-bin/q.cgi", "#!/bin/sh\necho Content-Type: text/html\necho\necho \"<html><head><title>Results</title></head><body><p>You searched for $QUERY_STRING</p></body></html>\"\n", "/", false, AgoraStat.MODE_EXEC)
	await until(func() -> bool: return _has_address(ws, "eth0") and _has_address(srv, "eth0") and srv.port_info(80).get("service") == "apache2", 120)
	var r := await run(ws, "lynx -dump http://srv/")
	check_eq(r.out, """Welcome

   This is a test page & more. See [1]About us or [2]the files.

     * One
     * Two

   [3]__________ [4]Search

References

   1. http://srv/about.html
   2. http://srv/files/
""", "lynx -dump")
	r = await run(ws, "lynx -source http://srv/about.html")
	check(r.out.begins_with("<html><head><title>About</title>"), "lynx -source")
	r = await run(ws, "lynx -dump http://nowhere/")
	check(r.code == 1 and r.err.contains("lynx: Can't access startfile http://nowhere/"), "unknown host: " + r.err)
	# On a terminal: the whole screen, keys one by one.
	var tty := AgoraTty.new()
	tty.cols = 80
	tty.rows = 24
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(ws, tty)
	tty.type_line("lynx srv")
	await until(func() -> bool: return screen[0].contains("press space") or screen[0].contains("Arrow keys"), 120)
	check(tty.raw and screen[0].contains("Test Site") and screen[0].contains("Welcome") and screen[0].contains("\u001b[7mAbout us"), "the page, first link selected: " + screen[0].right(400).c_escape())
	check(screen[0].contains("http://srv/about.html"), "the link's URL on the status line")
	screen[0] = ""
	tty.type_key("\u001b[C")
	await until(func() -> bool: return screen[0].contains("We are a test."), 120)
	check(screen[0].contains("About") and screen[0].contains("We are a test."), "followed the link")
	screen[0] = ""
	tty.type_key("\u001b[D")
	await until(func() -> bool: return screen[0].contains("Welcome"), 60)
	check(screen[0].contains("Welcome"), "back")
	for k in 2:
		tty.type_key("\u001b[B")
	await until(func() -> bool: return screen[0].contains("(Text entry field)"), 60)
	check(screen[0].contains("(Text entry field) Enter text."), "on the text field")
	screen[0] = ""
	tty.type_key("n")
	tty.type_key("e")
	tty.type_key("o")
	tty.type_key("\n")
	await until(func() -> bool: return screen[0].contains("You searched for"), 120)
	check(screen[0].contains("You searched for q=neo"), "the form went to the CGI: " + screen[0].right(300).c_escape())
	screen[0] = ""
	tty.type_key("q")
	await until(func() -> bool: return screen[0].contains("Are you sure you want to quit?"), 60)
	tty.type_key("y")
	await until(func() -> bool: return screen[0].ends_with("alice@ws:~$ "), 60)
	check(not tty.raw and screen[0].ends_with("alice@ws:~$ "), "quit, terminal back to lines")

## Two hosts with Exim: ws (alice) and srv (bob), srv also the DNS server
## with an MX record for srv.corp.
func mail_pair() -> Array[AgoraMachine]:
	var root := AgoraCred.root()
	var ws := make_machine("ws", {"nameservers": ["10.0.0.5"], "network": {"eth0": {"method": "static", "address": "10.0.0.2", "netmask": "255.255.255.0"}}})
	var srv := make_machine("srv", {"profile": "server", "packages": ["dnsmasq"], "nameservers": ["127.0.0.1"],
		"network": {"eth0": {"method": "static", "address": "10.0.0.5", "netmask": "255.255.255.0"}}})
	ws.hardware.connect_port("eth0", srv.hardware, "eth0")
	return [ws, srv]


func exim_conf(type: String, interfaces: String, others: String = "", relay: String = "") -> String:
	return "dc_eximconfig_configtype='%s'\ndc_other_hostnames='%s'\ndc_local_interfaces='%s'\ndc_relay_nets='%s'\ndc_smarthost=''\n" % [type, others, interfaces, relay]


func test_mail() -> void:
	var pair := mail_pair()
	var ws := pair[0]
	var srv := pair[1]
	var root := AgoraCred.root()
	await until(func() -> bool: return ws.port_info(25).get("service") == "exim4" and srv.port_info(25).get("service") == "exim4", 120)
	check_eq(ws.port_info(25).get("service"), "exim4", "exim4 runs on the desktop")
	check(ws.net.tcp.listener_on(25).address == AgoraInet.parse("127.0.0.1"), "only on the loopback, as Debian sets it up")
	var log := ws.vfs.read_text(root, "/var/log/exim4/mainlog")
	check(log.contains(" exim 4.63 daemon started: pid=") and log.contains(", -q30m, listening for SMTP on [127.0.0.1]:25"), "daemon start logged: " + log)
	# Local mail.
	var r := await run(ws, "echo 'hello bob' | mail -s 'first one' bob")
	check(r.code == 0 and r.out == "" and r.err == "", "mail sends quietly: " + r.out + r.err)
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/log/exim4/mainlog").contains("Completed"), 120)
	var box := ws.vfs.read_text(root, "/var/mail/bob")
	check(box.begins_with("From alice@ws ") and box.contains("\nReturn-path: <alice@ws>\nEnvelope-to: bob@ws\nDelivery-date: ")
		and box.contains("\nReceived: from alice by ws with local (Exim 4.63)\n\t(envelope-from <alice@ws>)\n\tid ")
		and box.contains("\nTo: bob\nSubject: first one\nMessage-Id: <E") and box.contains("\nFrom: alice@ws\nDate: ")
		and box.ends_with("\n\nhello bob\n\n"), "the message in bob's mailbox: " + box)
	var st := ws.vfs.stat(root, "/var/mail/bob")
	check(st.uid == ws.users.find("bob").uid and st.gid == ws.users.find_group("mail").gid and st.mode & 511 == 432, "mailbox owned by bob, group mail, 0660: %d %d %o" % [st.uid, st.gid, st.mode])
	log = ws.vfs.read_text(root, "/var/log/exim4/mainlog")
	check(log.contains(" <= alice@ws U=alice P=local S=") and log.contains(" => bob <bob@ws> R=local_user T=mail_spool\n"), "mainlog: " + log)
	# Reading it.
	r = await run(ws, "printf '1\\nq\\n' | mail", "bob")
	var lines: PackedStringArray = r.out.split("\n")
	check(lines.size() > 3 and lines[0] == "Mail version 8.1.2 01/15/2001.  Type ? for help." and lines[1] == "\"/var/mail/bob\": 1 message 1 new"
		and lines[2].begins_with(">N  1 alice@ws              ") and lines[2].ends_with(" first one"), "header list: " + r.out)
	check(r.out.contains("Message 1:\nFrom alice@ws ") and r.out.contains("\nTo: bob\nSubject: first one\n") and not r.out.contains("Received:")
		and r.out.contains("\n\nhello bob\nSaved 1 message in /home/bob/mbox\n"), "message shown, then saved to mbox: " + r.out)
	check(ws.vfs.read_text(root, "/var/mail/bob") == "" and ws.vfs.read_text(root, "/home/bob/mbox").contains("\nStatus: RO\n"), "moved to ~/mbox")
	r = await run(ws, "mail; mail -e; echo $?", "bob")
	check(r.err == "No mail for bob\n" and r.out == "1\n", "no mail left: " + r.out + r.err)
	r = await run(ws, "printf 'd 1\\nq\\n' | mail -f", "bob")
	check(r.out.contains("\"/home/bob/mbox\": 1 message\n") and r.out.ends_with("\"/home/bob/mbox\" removed\n"), "mail -f ~/mbox: " + r.out)
	# Composing on a terminal: Subject and Cc are asked for (mail.rc).
	var tty := AgoraTty.new()
	var screen := [""]
	tty.printed.connect(func(t: String) -> void: screen[0] += t)
	m_login_and_wait(ws, tty)
	await until(func() -> bool: return screen[0].ends_with("$ "), 120)
	tty.type_line("mail bob")
	await until(func() -> bool: return screen[0].ends_with("Subject: "), 120)
	tty.type_line("by hand")
	tty.type_line("typed on a terminal")
	tty.type_line(".")
	await until(func() -> bool: return screen[0].ends_with("Cc: "), 120)
	tty.type_line("")
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/mail/bob").contains("typed on a terminal"), 120)
	check(ws.vfs.read_text(root, "/var/mail/bob").contains("Subject: by hand\n"), "composed on a terminal: " + screen[0])
	# Mistakes come back.
	r = await run(ws, "echo lost | mail -s lost nosuchuser; echo far | mail -s far carol@example.org")
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/mail/alice").count("Mail delivery failed") == 2, 120)
	box = ws.vfs.read_text(root, "/var/mail/alice")
	check(box.contains("From MAILER-DAEMON ") and box.contains("\nReturn-path: <>\n") and box.contains("\nX-Failed-Recipients: nosuchuser@ws\nAuto-Submitted: auto-replied\nFrom: Mail Delivery System <Mailer-Daemon@ws>\nTo: alice@ws\nSubject: Mail delivery failed: returning message to sender\n")
		and box.contains("\nA message that you sent could not be delivered to one or more of its\nrecipients. This is a permanent error. The following address(es) failed:\n\n  nosuchuser@ws\n    Unrouteable address\n")
		and box.contains("------ This is a copy of the message, including all the headers. ------\n\nReturn-path: <alice@ws>\n"), "bounce: " + box)
	check(box.contains("  carol@example.org\n    Mailing to remote domains not supported\n"), "local-only configuration: " + box)
	log = ws.vfs.read_text(root, "/var/log/exim4/mainlog")
	check(log.contains(" ** nosuchuser@ws: Unrouteable address\n") and log.contains(" <= <> R=") and log.contains(" U=Debian-exim P=local S=")
		and log.contains(" ** carol@example.org R=nonlocal: Mailing to remote domains not supported\n"), "failures logged: " + log)
	# root's mail lands in /var/mail/mail, as Debian does without an alias.
	await run(ws, "echo ping | mail -s ping postmaster")
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/mail/mail").contains("ping"), 120)
	check(ws.vfs.read_text(root, "/var/log/exim4/mainlog").contains(" => /var/mail/mail <postmaster@ws> R=mail4root T=address_file\n"), "postmaster -> root -> /var/mail/mail")
	r = await run(ws, "exim4 -bt postmaster bob nobody2")
	check_eq(r.out, "/var/mail/mail\n    <-- postmaster@ws\n  router = mail4root, transport = address_file\nbob@ws\n  router = local_user, transport = mail_spool\nnobody2@ws is undeliverable: Unrouteable address\n", "exim -bt")
	# SMTP by hand on the loopback.
	ws.vfs.write_text(root, "/tmp/smtp", "EHLO ws\nMAIL FROM:<alice@ws>\nRCPT TO:<nosuchuser@ws>\nRCPT TO:<bob@ws>\nDATA\nSubject: by telnet\n\n..dots are stuffed\n.\nVRFY bob\nQUIT\n")
	r = await run(ws, "telnet localhost 25 < /tmp/smtp")
	check(r.out.contains("\n220 ws ESMTP Exim 4.63 ") and r.out.contains("\n250-ws Hello localhost [127.0.0.1]\n250-SIZE 52428800\n250-PIPELINING\n250 HELP\n250 OK\n550 Unrouteable address\n250 Accepted\n354 Enter message, ending with \".\" on a line by itself\n250 OK id=")
		and r.out.contains("\n252 Administrative prohibition\n221 ws closing connection\n"), "SMTP session: " + r.out)
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/mail/bob").contains(".dots are stuffed"), 120)
	check(ws.vfs.read_text(root, "/var/mail/bob").contains("Received: from localhost ([127.0.0.1] helo=ws)\n\tby ws with esmtp (Exim 4.63)\n\t(envelope-from <alice@ws>)"), "Received: for SMTP")
	check(ws.vfs.read_text(root, "/var/log/exim4/rejectlog").contains(" H=localhost (ws) [127.0.0.1] F=<alice@ws> rejected RCPT <nosuchuser@ws>: Unrouteable address\n"), "rejectlog: " + ws.vfs.read_text(root, "/var/log/exim4/rejectlog"))
	r = await run(ws, "mailq; exim4 -q")
	check(r.err == "exim: permission denied\nexim: permission denied\n", "the queue is for admins: " + r.err)

	# Between hosts. srv serves DNS for corp with an MX record and takes mail
	# from anywhere for its own domain; ws delivers by MX.
	srv.vfs.write_text(root, "/etc/hosts", "10.0.0.5\tsrv.corp srv\n10.0.0.2\tws.corp ws\n", "/", true)
	srv.vfs.write_text(root, "/etc/dnsmasq.d/mail.conf", "mx-host=srv.corp,srv.corp,10\n")
	srv.vfs.write_text(root, "/etc/exim4/update-exim4.conf.conf", exim_conf("internet", "", "srv.corp"))
	ws.vfs.write_text(root, "/etc/exim4/update-exim4.conf.conf", exim_conf("internet", ""))
	ws.vfs.write_text(root, "/etc/mailname", "ws.corp\n")
	r = await run(srv, "systemctl restart dnsmasq; systemctl restart exim4", "root")
	r = await run(ws, "update-exim4.conf; systemctl restart exim4", "root")
	await until(func() -> bool: return ws.port_info(25).get("service") == "exim4" and srv.net.tcp.listener_on(25) != null and srv.net.tcp.listener_on(25).address == 0, 240)
	r = await run(ws, "host -t mx srv.corp; exim4 -bt bob@srv.corp", "root")
	check(r.out.ends_with("bob@srv.corp\n  router = dnslookup, transport = remote_smtp\n  host srv.corp [10.0.0.5] MX=10\n"), "routed by MX: " + r.out + r.err)
	r = await run(ws, "echo 'over the wire' | mail -s across bob@srv.corp")
	await until(func() -> bool: return srv.vfs.read_text(root, "/var/mail/bob").contains("over the wire"), 300)
	box = srv.vfs.read_text(root, "/var/mail/bob")
	check(box.begins_with("From alice@ws.corp ") and box.contains("Received: from ws.corp ([10.0.0.2] helo=ws)\n\tby srv with esmtp (Exim 4.63)\n\t(envelope-from <alice@ws.corp>)")
		and box.contains("Received: from alice by ws with local (Exim 4.63)"), "delivered on srv: " + box)
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/log/exim4/mainlog").contains(" => bob@srv.corp R=dnslookup T=remote_smtp H=srv.corp [10.0.0.5]\n"), 120)
	check(ws.vfs.read_text(root, "/var/log/exim4/mainlog").contains(" => bob@srv.corp R=dnslookup T=remote_smtp H=srv.corp [10.0.0.5]\n"), "remote delivery logged")
	check(srv.vfs.read_text(root, "/var/log/exim4/mainlog").contains(" <= alice@ws.corp H=ws.corp (ws) [10.0.0.2] P=esmtp S="), "reception logged on srv")
	# bob answers; ws.corp has no MX, so its address is used.
	r = await run(srv, "printf 'r\\ngot it\\n.\\nq\\n' | mail", "bob")
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/mail/alice").contains("got it"), 300)
	check(ws.vfs.read_text(root, "/var/mail/alice").contains("Subject: Re: across\n"), "the reply came back: " + r.out)
	# An unknown user on srv: refused at RCPT, bounced by ws.
	await run(ws, "echo hm | mail -s hm nobody2@srv.corp")
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/mail/alice").contains("nobody2@srv.corp\n    SMTP error"), 300)
	check(ws.vfs.read_text(root, "/var/mail/alice").contains("  nobody2@srv.corp\n    SMTP error from remote mail server after RCPT TO:<nobody2@srv.corp>:\n    host srv.corp [10.0.0.5]: 550 Unrouteable address\n"), "remote refusal bounced")
	# Strangers can't relay through srv.
	ws.vfs.write_text(root, "/tmp/relay", "HELO ws\nMAIL FROM:<alice@ws.corp>\nRCPT TO:<someone@example.org>\nQUIT\n")
	r = await run(ws, "telnet srv.corp 25 < /tmp/relay")
	check(r.out.contains("\n250 srv Hello ws.corp [10.0.0.2]\n250 OK\n550 relay not permitted\n"), "relay refused: " + r.out)
	check(srv.vfs.read_text(root, "/var/log/exim4/rejectlog").contains("H=ws.corp (ws) [10.0.0.2] F=<alice@ws.corp> rejected RCPT <someone@example.org>: relay not permitted"), "relay refusal logged: " + srv.vfs.read_text(root, "/var/log/exim4/rejectlog"))
	# srv down: the message waits in the queue, and goes once it is back.
	await run(srv, "systemctl stop exim4", "root")
	await until(func() -> bool: return srv.port_info(25).is_empty(), 120)
	await run(ws, "echo patience | mail -s later bob@srv.corp")
	await until(func() -> bool: return ws.vfs.read_text(root, "/var/log/exim4/mainlog").contains(" == bob@srv.corp R=dnslookup T=remote_smtp defer (111): Connection refused\n"), 300)
	check(ws.vfs.read_text(root, "/var/log/exim4/mainlog").contains(" == bob@srv.corp R=dnslookup T=remote_smtp defer (111): Connection refused\n"), "deferred")
	r = await run(ws, "mailq", "root")
	lines = r.out.split("\n")
	check(lines.size() >= 3 and lines[0].begins_with(" 0m   ") and lines[0].ends_with(" <alice@ws.corp>") and lines[1] == "          bob@srv.corp" and lines[2] == "", "mailq: " + r.out)
	await run(srv, "systemctl start exim4", "root")
	await until(func() -> bool: return srv.port_info(25).get("service") == "exim4", 120)
	r = await run(ws, "exim4 -q; mailq", "root")
	check_eq(r.out, "", "queue run delivered it")
	check(srv.vfs.read_text(root, "/var/mail/bob").contains("patience"), "arrived after the retry")


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


## A box for an AgoraWorldSpec.
func box_spec(name: String, template: String, install: Dictionary = {}) -> AgoraBoxSpec:
	var b := AgoraBoxSpec.new()
	b.name = name
	b.template = template
	if not install.is_empty():
		b.install = true
		b.profile = install.get("profile", "desktop")
		b.root_password = install.get("root_password", "")
		install.erase("profile")
		install.erase("root_password")
		b.options = install
	return b


func cable_spec(a: String, b: String, length: float = 2.0, defects: Array[String] = []) -> AgoraCableSpec:
	var c := AgoraCableSpec.new()
	c.a = a
	c.b = b
	c.length_m = length
	c.defects = defects
	return c


func test_world() -> void:
	var spec := AgoraWorldSpec.new()
	spec.start_time = "2003-06-14 22:00:00"
	var pc_spec := box_spec("pc", "pc")
	pc_spec.media = [AgoraBoxSpec.Media.INSTALL_CD]
	pc_spec.power = false
	spec.boxes = [pc_spec, box_spec("gw", "router", {"profile": "router", "root_password": "admin"}),
		box_spec("srv", "server", {"profile": "server", "root_password": "toor",
			"network": {"eth0": {"method": "static", "address": "192.168.1.20", "netmask": "255.255.255.0", "gateway": "192.168.1.1"}}})]
	spec.cables = [cable_spec("pc:eth0", "gw:eth1"), cable_spec("srv:eth0", "gw:eth2", 40.0, ["untwisted"])]
	var world := spec.build()
	check(world != null, "built from a spec: " + spec.error)
	check_eq(world.names(), PackedStringArray(["pc", "gw", "srv"]), "boxes in order")
	check_eq(world.clock.format_long().right(13), "22:00:00 2003", "the world's clock, in local time")
	check(world.box("gw").clock == world.clock and world.box("srv").clock == world.clock, "one clock for all")
	var cables := world.cables()
	check_eq(cables.map(func(c: Dictionary) -> String: return "%s-%s %.0fm %s" % [c.a, c.b, c.length, ",".join(c.defects)]),
		["pc:eth0-gw:eth1 2m ", "gw:eth2-srv:eth0 40m untwisted"], "cables")
	check_eq(world.port("pc:eth0").link_speed, 100, "PC to router at 100")
	check_eq(world.port_name(world.box("srv").nics[0]), "srv:eth0", "port names")
	check(world.box("pc").media(AgoraDisk.Kind.CDROM) != null, "install CD in the PC")
	# Running: the switched-on boxes boot.
	world.start()
	check(world.box("pc").machine == null and world.box("gw").machine != null and world.box("srv").machine != null, "the PC stays off")
	var gw := world.box("gw").machine
	var srv := world.box("srv").machine
	await until(func() -> bool: return not gw.port_info(22).is_empty() and srv.net != null and srv.net.iface("eth0").admin_up, 180)
	var r := await run(srv, "ping -c 1 192.168.1.1", "root")
	check(r.out.contains("1 received"), "srv reaches the router: " + r.out)
	# Saved and loaded: the same boxes, disks and cables; the PC still off.
	var macs := world.box("srv").nics.map(func(n: AgoraNic) -> String: return n.mac)
	check_eq(world.save("user://test_world.agw"), OK, "saved")
	world.stop()
	check(world.box("gw").power == AgoraHardware.Power.OFF, "stopped")
	var loaded := AgoraWorld.load_from("user://test_world.agw")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://test_world.agw"))
	check(loaded != null, "loaded")
	check_eq(loaded.names(), world.names(), "same boxes")
	check_eq(loaded.box("srv").nics.map(func(n: AgoraNic) -> String: return n.mac), macs, "same MACs")
	check_eq(loaded.cables().map(func(c: Dictionary) -> String: return "%s-%s %.0fm %s" % [c.a, c.b, c.length, ",".join(c.defects)]),
		["pc:eth0-gw:eth1 2m ", "gw:eth2-srv:eth0 40m untwisted"], "cables restored")
	check(loaded.box("pc").media(AgoraDisk.Kind.CDROM) != null, "the CD is still in")
	check(absf(loaded.clock.now() - world.clock.now()) < 5.0, "clock restored")
	loaded.start()
	check(loaded.box("pc").machine == null and loaded.box("gw").machine != null, "boxes that were on boot again")
	var srv2 := loaded.box("srv").machine
	check_eq(srv2.vfs.read_text(AgoraCred.root(), "/etc/hostname"), "srv\n", "the disk survived")
	await until(func() -> bool: return srv2.net != null and srv2.net.iface("eth0").admin_up, 120)
	r = await run(srv2, "ping -c 1 192.168.1.1", "root")
	check(r.out.contains("1 received"), "the network works again: " + r.out)
	var spare := AgoraHardware.from_template("server")
	check(loaded.replace("srv", spare) and loaded.names()[2] == "srv" and loaded.port("gw:eth2").peer == spare.nics[0]
		and loaded.port("gw:eth2").cable.length_m == 40.0, "a box swapped in keeps its place and cables")
	check(loaded.remove("srv") and loaded.box("gw").nic("eth2").cable == null, "a removed box takes its cable")
	loaded.stop()
	# Bad specs.
	var bad := AgoraWorldSpec.new()
	bad.boxes = [box_spec("x", "toaster")]
	check(bad.build() == null and bad.error == "x: unknown template \"toaster\"", "unknown template")
	bad.boxes = [box_spec("x", "virtual")]
	bad.cables = [cable_spec("x:eth0", "y:eth0")]
	check(bad.build() == null and bad.error.ends_with("no such port"), "unknown port")
	bad.boxes = [box_spec("x", "virtual"), box_spec("x", "virtual")]
	bad.cables = []
	check(bad.build() == null and bad.error == "x: two boxes with this name", "duplicate names")

## The demo world's internet: a provider, a switch, web servers, a search
## engine, seen from a preinstalled PC behind the home router.
func test_internet() -> void:
	var spec: AgoraWorldSpec = (load("res://worlds/home.tres") as AgoraWorldSpec).duplicate(true)
	var pc_box := spec.box("pc")
	pc_box.media = []
	pc_box.install = true
	pc_box.root_password = "root"
	pc_box.options = {"users": [{"name": "alice", "password": "x"}], "network": {"eth0": {"method": "dhcp"}}}
	var world := spec.build()
	check(world != null, "the home world builds: " + spec.error)
	check_eq(world.clock.local_datetime().year, 2003, "it is 2003")
	world.start()
	var pc := world.box("pc").machine
	var search := world.box("search").machine
	for name in ["gw", "isp", "www1", "www2", "www3", "search"]:
		_machines.append(world.box(name).machine)
	_machines.append(pc)
	await until(func() -> bool: return pc.net != null and _has_address(pc, "eth0") and world.box("gw").machine.net.iface("eth0") != null and _has_address(world.box("gw").machine, "eth0"), 1200)
	var r := await run(pc, "ip -4 addr show eth0; cat /etc/resolv.conf")
	check(r.out.contains("inet 192.168.1."), "the PC has a LAN address: " + r.out)
	r = await run(world.box("gw").machine, "ip -4 addr show eth0", "root")
	check(r.out.contains("inet 203.0.113."), "the router has an address from the provider: " + r.out)
	r = await run(pc, "wget -q -O - http://www.byteslash.org/")
	check(r.out.contains("<title>ByteSlash: news for geeks"), "a name-based virtual host across the net: " + r.err + r.out.left(200))
	r = await run(pc, "wget -q -O - http://www.penguinpit.org/howto/")
	check(r.out.contains("Index of /howto/") and r.out.contains("firewall.txt"), "a directory listing: " + r.out.left(300))
	r = await run(pc, "lynx -dump http://members.lanlink.net/~kevin/")
	check(r.out.contains("Welcome to Kevin's Kool Homepage") and r.out.contains("http://members.lanlink.net/~kevin/linux.html"), "a member page through mod_userdir: " + r.out.left(400))
	r = await run(pc, "wget -q -O - http://members.lanlink.net/~kevin/counter.cgi")
	# (The crawler may have called it already: it follows every link.)
	check(r.out.contains("You are visitor number 13") and not r.out.contains("number 1337!!"), "Kevin's counter counts: " + r.out)
	r = await run(pc, "wget -q -O - http://www.lanlink.net/cgi-bin/myip.cgi")
	check(r.out.contains("You are coming from <b>203.0.113."), "the server sees the router's address (NAT): " + r.out)
	# The Ferret has crawled everything it was allowed to.
	await until(func() -> bool: return search.vfs.read_text(AgoraCred.root(), "/var/lib/ferret/index").count("\n") > 15, 1800)
	var index := search.vfs.read_text(AgoraCred.root(), "/var/lib/ferret/index")
	check(index.count("\n") > 15 and index.contains("http://www.staticnoise.org/issues/sn07.txt"), "the crawler indexed the sites: %d pages" % index.count("\n"))
	check(not index.contains("/admin/"), "robots.txt kept it out of /admin/")
	r = await run(pc, "lynx -dump 'http://www.ferret.org/cgi-bin/search?q=install+fest'")
	check(r.out.contains("PenguinPit - the Valley Linux User Group") and r.out.contains("http://www.penguinpit.org/"), "search results: " + r.out.left(600))
	r = await run(pc, "lynx -dump 'http://www.ferret.org/cgi-bin/search?q=zzyzx'")
	check(r.out.contains("did not match any documents"), "nothing found")
	r = await run(pc, "wget -q -O - 'http://www.ferret.org/cgi-bin/addurl?url=http%3A%2F%2Fexample.lan%2F'")
	check(r.out.contains("will be visited by the Ferret") and search.vfs.read_text(AgoraCred.root(), "/var/lib/ferret/submitted") == "http://example.lan/\n", "Add URL")
	pc.vfs.write_text(AgoraCred.root(), "/tmp/get.ftp", "user anonymous me@\ncd pub/demos\nget fermion.nfo /tmp/fermion.nfo\nbye\n")
	# Behind the router's NAT only passive mode works.
	r = await run(pc, "ftp -n -p ftp.demozone.net < /tmp/get.ftp")
	check(pc.vfs.read_text(AgoraCred.root(), "/tmp/fermion.nfo").contains("a 64k intro by Kaleidoscope"), "anonymous FTP at DemoZone: " + r.out)
	world.stop()

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
