extends AgoraProgram
## in.ftpd (linux-ftpd 0.17, a port of OpenBSD's ftpd): the FTP server,
## started by inetd with the control connection on its standard input and
## output. Passwords come as plain text, like everything else on it.
##
## Users listed in /etc/ftpusers may not log in. "anonymous" (or "ftp")
## logs in as the ftp user, if there is one, locked into its home. Files
## are read and written with the user's permissions. Data goes over a
## second connection: in active mode (PORT) the server connects from port
## 20 to the client; in passive mode (PASV) the client connects to a port
## the server opened. TYPE A turns newlines into CR LF on the wire.

const VERSION := "6.4/OpenBSD/Linux-ftpd-0.17"
## How long a passive data port waits for the client.
const PASV_TIMEOUT := 10.0

var p: AgoraProcess
var _ctrl: AgoraTcp.Conn
var _client := "unknown"
var _user := ""
var _cred: AgoraCred
var _guest := false
var _logged_in := false
## Where the session is locked in (the ftp user's home for guests).
var _root := "/"
## The working directory as the client sees it.
var _cwd := "/"
var _ascii := true
var _port_addr := -1
var _port_port := -1
var _pasv: AgoraTcp.Listener
var _rename_from := ""


func summary() -> String:
	return "Internet File Transfer Protocol server"


func usage() -> String:
	return "usage: in.ftpd [-l] [-A] (started by inetd)"


func main(proc: AgoraProcess) -> int:
	p = proc
	_ctrl = p.socket
	if _ctrl:
		_client = AgoraInet.to_str(_ctrl.remote_addr)
		_port_addr = _ctrl.remote_addr # RFC 959's default data port
		_port_port = _ctrl.remote_port
	_log("connection from %s" % _client)
	_reply(220, "%s FTP server (Version %s) ready." % [p.machine.hostname, VERSION])
	while p.is_running():
		var line: Variant = await p.stdin.read_line(p.is_dead)
		if line == null:
			break
		var text := str(line).trim_suffix("\r")
		var verb := text.get_slice(" ", 0).to_upper()
		var arg := text.substr(verb.length() + 1) if text.length() > verb.length() else ""
		if verb == "QUIT":
			_reply(221, "Goodbye.")
			break
		await _command(verb, arg)
	if _pasv:
		_pasv.close()
	return 0


func _reply(code: int, text: String) -> void:
	p.stdout.write("%d %s\r\n" % [code, text])


func _log(message: String) -> void:
	p.machine.log_event("daemon", "ftpd[%d]" % p.pid, message)


func _command(verb: String, arg: String) -> void:
	match verb:
		"USER":
			_cmd_user(arg)
			return
		"PASS":
			await _cmd_pass(arg)
			return
		"NOOP":
			_reply(200, "NOOP command successful.")
			return
		"SYST":
			_reply(215, "UNIX Type: L8")
			return
		"HELP":
			p.stdout.write("214- The following commands are recognized (* =>'s unimplemented).\r\n")
			p.stdout.write("   USER    PORT    RETR    DELE    MKD     RNFR    PASV    CDUP    TYPE\r\n")
			p.stdout.write("   PASS    LIST    STOR    RMD     PWD     RNTO    NLST    CWD     SIZE\r\n")
			p.stdout.write("   SYST    NOOP    HELP    QUIT    XPWD    XCWD    XMKD    XRMD\r\n")
			_reply(214, "Direct comments to ftp-bugs@%s." % p.machine.hostname)
			return
	if not _logged_in:
		_reply(530, "Please login with USER and PASS.")
		return
	match verb:
		"PWD", "XPWD":
			_reply(257, "\"%s\" is current directory." % _cwd)
		"CWD", "XCWD":
			_chdir(arg if not arg.is_empty() else "~")
		"CDUP", "XCUP":
			_chdir("..")
		"TYPE":
			match arg.to_upper().get_slice(" ", 0):
				"A":
					_ascii = true
					_reply(200, "Type set to A.")
				"I", "L":
					_ascii = false
					_reply(200, "Type set to I.")
				_:
					_reply(504, "Type %s not implemented." % arg)
		"PORT":
			var n := arg.split(",")
			if n.size() != 6:
				_reply(501, "Syntax error in parameters or arguments.")
				return
			_port_addr = AgoraInet.parse(".".join(n.slice(0, 4)))
			_port_port = n[4].to_int() * 256 + n[5].to_int()
			if _pasv:
				_pasv.close()
				_pasv = null
			_reply(200, "PORT command successful.")
		"PASV":
			if _pasv:
				_pasv.close()
			_pasv = p.machine.net.tcp.listen(p, 0, _ctrl.local_addr if _ctrl else 0, 1)
			if _pasv == null:
				_reply(425, "Can't open passive connection: %s." % AgoraErrno.describe(p.machine.net.tcp.last_error))
				return
			var a := AgoraInet.to_str(_ctrl.local_addr if _ctrl else 0x7F000001).replace(".", ",")
			_reply(227, "Entering Passive Mode (%s,%d,%d)" % [a, _pasv.port >> 8, _pasv.port & 255])
		"LIST", "NLST":
			await _list(verb, arg)
		"RETR":
			await _retrieve(arg)
		"STOR":
			await _store(arg)
		"SIZE":
			var st := p.machine.vfs.stat(_cred, _real(arg))
			if st == null or not st.is_file():
				_reply(550, "%s: %s" % [arg, "not a plain file." if st else AgoraErrno.describe(p.machine.vfs.errno)])
			else:
				_reply(213, str(st.size))
		"DELE":
			_simple(p.machine.vfs.unlink(_cred, _real(arg)), arg, 250, "DELE command successful.")
		"MKD", "XMKD":
			_simple(p.machine.vfs.mkdir(_cred, _real(arg)), arg, 257, "\"%s\" new directory created." % arg)
		"RMD", "XRMD":
			_simple(p.machine.vfs.rmdir(_cred, _real(arg)), arg, 250, "RMD command successful.")
		"RNFR":
			if p.machine.vfs.stat(_cred, _real(arg), "/", false) == null:
				_reply(550, "%s: %s" % [arg, AgoraErrno.describe(p.machine.vfs.errno)])
				return
			_rename_from = arg
			_reply(350, "File exists, ready for destination name")
		"RNTO":
			if _rename_from.is_empty():
				_reply(503, "Bad sequence of commands.")
				return
			_simple(p.machine.vfs.rename(_cred, _real(_rename_from), _real(arg)), arg, 250, "RNTO command successful.")
			_rename_from = ""
		_:
			_reply(500, "'%s': command not understood." % verb)


func _simple(code: int, arg: String, ok: int, text: String) -> void:
	if code == AgoraErrno.OK:
		_reply(ok, text)
	else:
		_reply(550, "%s: %s." % [arg, AgoraErrno.describe(code)])


# --- login ---------------------------------------------------------------------

func _cmd_user(name: String) -> void:
	if _logged_in:
		_reply(530, "Already logged in.")
		return
	_user = name
	_guest = name in ["anonymous", "ftp"]
	if _guest:
		if p.machine.users.find("ftp").is_empty():
			_reply(530, "User %s unknown." % name)
			_user = ""
			return
		_reply(331, "Guest login ok, type your name as password.")
		return
	if _denied(name):
		_reply(530, "User %s access denied." % name)
		_user = ""
		return
	_reply(331, "Password required for %s." % name)


## Listed in /etc/ftpusers.
func _denied(name: String) -> bool:
	for line in p.read_text("/etc/ftpusers").split("\n", false):
		if line.strip_edges() == name:
			return true
	return false


func _cmd_pass(password: String) -> void:
	if _logged_in:
		_reply(503, "User already logged in.")
		return
	if _user.is_empty():
		_reply(503, "Login with USER first.")
		return
	var users := p.machine.users
	if _guest:
		var ftp := users.find("ftp")
		_cred = users.cred_for("ftp")
		_root = ftp.home
		_cwd = "/"
		_logged_in = true
		_log("ANONYMOUS FTP LOGIN FROM %s [%s], %s" % [_client, _client, password])
		_reply(230, "Guest login ok, access restrictions apply.")
		return
	var u := users.find(_user)
	if u.is_empty() or users.is_locked(_user) or not users.check_password(_user, password):
		_log("FTP LOGIN FAILED FROM %s [%s], %s" % [_client, _client, _user])
		await p.sleep(1.0)
		_reply(530, "Login incorrect.")
		_user = ""
		return
	_cred = users.cred_for(_user)
	_logged_in = true
	_log("FTP LOGIN FROM %s [%s], %s" % [_client, _client, _user])
	if p.machine.vfs.is_dir(_cred, u.home):
		_cwd = u.home
		_reply(230, "User %s logged in." % _user)
	else:
		_cwd = "/"
		p.stdout.write("230-No directory! Logging in with home=/\r\n")
		_reply(230, "User %s logged in." % _user)


# --- paths ---------------------------------------------------------------------

## The client's path as the session sees it (inside the guest's root).
func _virtual(path: String) -> String:
	if path == "~" or path.begins_with("~/"):
		var home := "/" if _guest else str(p.machine.users.find(_user).get("home", "/"))
		path = home + path.substr(1)
	return AgoraPath.normalize(path, _cwd)


## The path on the machine.
func _real(path: String) -> String:
	var v := _virtual(path)
	return v if _root == "/" else AgoraPath.normalize(_root + v)


func _chdir(arg: String) -> void:
	var v := _virtual(arg)
	var st := p.machine.vfs.stat(_cred, _real(arg))
	if st == null:
		_reply(550, "%s: %s." % [arg, AgoraErrno.describe(p.machine.vfs.errno)])
	elif not st.is_dir():
		_reply(550, "%s: Not a directory." % arg)
	elif not AgoraVfs.can_access(_cred, st, AgoraStat.X):
		_reply(550, "%s: Permission denied." % arg)
	else:
		_cwd = v
		_reply(250, "CWD command successful.")


# --- data ----------------------------------------------------------------------

## The data connection: to the client's PORT, or the one it makes to our
## PASV port. Null after replying 425.
func _open_data() -> AgoraTcp.Conn:
	if _pasv:
		var listener := _pasv
		_pasv = null
		var deadline := Time.get_ticks_msec() + int(PASV_TIMEOUT * 1000)
		var conn: AgoraTcp.Conn = await listener.accept(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
		listener.close()
		if conn == null:
			_reply(425, "Can't open data connection.")
		return conn
	var r: Dictionary = await p.machine.net.tcp.open_connection(p, _port_addr, _port_port,
		{"sport": 20, "src": _ctrl.local_addr if _ctrl else 0})
	if r.has("error"):
		_reply(425, "Can't build data connection: %s." % AgoraErrno.describe(r.error))
		return null
	return r.conn


func _send_data(conn: AgoraTcp.Conn, data: String) -> void:
	conn.output.write(data)
	conn.close()
	_reply(226, "Transfer complete.")


func _list(verb: String, arg: String) -> void:
	var flags: PackedStringArray = []
	var target := ""
	for w in arg.split(" ", false):
		if w.begins_with("-"):
			flags.append(w)
		else:
			target = w
	var real := _real(target if not target.is_empty() else ".")
	var text := ""
	if verb == "NLST":
		var names := p.machine.vfs.list_dir(_cred, real)
		if names.is_empty() and p.machine.vfs.errno != AgoraErrno.OK:
			_reply(550, "%s: %s." % [target if not target.is_empty() else ".", AgoraErrno.describe(p.machine.vfs.errno)])
			return
		for n in names:
			text += n + "\r\n"
		_reply(150, "Opening ASCII mode data connection for 'file list'.")
	else:
		# linux-ftpd runs /bin/ls -lgA, with the user's permissions.
		var out := AgoraStream.new()
		out.add_reader()
		var argv := PackedStringArray(["/bin/ls", "-lA"])
		argv.append(real)
		var ls := p.machine.spawn(argv, {"cred": _cred, "stdout": out, "stderr": out, "parent": p})
		if ls == null:
			_reply(550, "/bin/ls: %s." % AgoraErrno.describe(p.machine.errno))
			return
		await ls.wait()
		text = out.read_available().replace("\n", "\r\n")
		if _root != "/":
			text = text.replace(_root, "")
		_reply(150, "Opening ASCII mode data connection for '/bin/ls'.")
	var conn := await _open_data()
	if conn:
		_send_data(conn, text)


func _retrieve(arg: String) -> void:
	var real := _real(arg)
	var st := p.machine.vfs.stat(_cred, real)
	if st == null:
		_reply(550, "%s: %s." % [arg, AgoraErrno.describe(p.machine.vfs.errno)])
		return
	if not st.is_file():
		_reply(550, "%s: not a plain file." % arg)
		return
	var bytes := p.machine.vfs.read_file(_cred, real)
	if p.machine.vfs.errno != AgoraErrno.OK:
		_reply(550, "%s: %s." % [arg, AgoraErrno.describe(p.machine.vfs.errno)])
		return
	var data := ""
	if _ascii:
		data = bytes.get_string_from_utf8().replace("\n", "\r\n")
		_reply(150, "Opening ASCII mode data connection for '%s' (%d bytes)." % [arg, bytes.size()])
	else:
		data = AgoraWire.raw(bytes)
		_reply(150, "Opening BINARY mode data connection for '%s' (%d bytes)." % [arg, bytes.size()])
	var conn := await _open_data()
	if conn:
		_send_data(conn, data)


func _store(arg: String) -> void:
	var real := _real(arg)
	# Opening the file comes first, as fopen(3) would.
	var e := p.machine.vfs.write_file(_cred, real, PackedByteArray())
	if e != AgoraErrno.OK:
		_reply(553, "%s: %s." % [arg, AgoraErrno.describe(e)])
		return
	_reply(150, "Opening %s mode data connection for '%s'." % ["ASCII" if _ascii else "BINARY", arg])
	var conn := await _open_data()
	if conn == null:
		return
	var text := await conn.input.read_all(p.is_dead)
	conn.close()
	if _ascii:
		text = text.replace("\r\n", "\n")
	p.machine.vfs.write_file(_cred, real, AgoraWire.encode(text))
	_reply(226, "Transfer complete.")
