extends AgoraProgram
## ftp (netkit-ftp 0.17): the Internet file transfer program. Commands come
## from the terminal ("ftp> ") or a script on standard input. Data goes
## over a second connection: by default the server connects back to a port
## we open (active mode, PORT), which a NAT router in between breaks;
## "passive" makes us connect to the server instead (PASV).
##
## -p starts in passive mode, -n skips the automatic login, -v shows every
## reply (the default on a terminal), -i turns off prompting for mget.

var p: AgoraProcess
var _ctrl: AgoraTcp.Conn
var _host := ""
var _verbose := false
var _passive := false
var _binary := true
var _auto_login := true
var _interactive := false
var _connected := false
var _done := false

const COMMANDS := {
	"!": "escape to the shell", "ascii": "set ascii transfer type", "binary": "set binary transfer type",
	"bye": "terminate ftp session and exit", "cd": "change remote working directory",
	"cdup": "change remote working directory to parent directory", "close": "terminate ftp session",
	"delete": "delete remote file", "dir": "list contents of remote directory", "get": "receive file",
	"help": "print local help information", "lcd": "change local working directory",
	"ls": "list contents of remote directory", "mget": "get multiple files", "mkdir": "make directory on the remote machine",
	"mput": "send multiple files", "nlist": "nlist contents of remote directory", "open": "connect to remote ftp",
	"passive": "enter passive transfer mode", "put": "send one file", "pwd": "print working directory on remote machine",
	"quit": "terminate ftp session and exit", "recv": "receive file", "rename": "rename file",
	"rmdir": "remove directory on the remote machine", "send": "send one file", "size": "show size of remote file",
	"status": "show current status", "system": "show remote system type", "type": "set file transfer type",
	"user": "send new user information", "verbose": "toggle verbose mode", "?": "print local help information",
}


func summary() -> String:
	return "Internet file transfer program"


func usage() -> String:
	return "usage: ftp [-pinv] [host [port]]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv)
	_interactive = p.tty != null
	_verbose = _interactive or a.has("v")
	_passive = a.has("p")
	_auto_login = not a.has("n")
	if not a.operands.is_empty():
		await _open(a.operands)
	while not _done and not p.is_dead():
		if _interactive:
			p.out("ftp> ")
		var line: Variant = await p.read_line()
		if line == null:
			break
		var words := str(line).strip_edges().split(" ", false)
		if words.is_empty():
			continue
		await _run(words[0], words.slice(1))
	if _connected:
		await _quit()
	return 0


func _run(cmd: String, args: PackedStringArray) -> void:
	if not COMMANDS.has(cmd):
		p.outln("?Invalid command")
		return
	match cmd:
		"open":
			if _connected:
				p.outln("Already connected to %s, use close first." % _host)
			elif args.is_empty():
				p.outln("usage: open host-name [port]")
			else:
				await _open(args)
			return
		"bye", "quit":
			if _connected:
				await _quit()
			_done = true
			return
		"help", "?":
			if args.is_empty():
				p.outln("Commands may be abbreviated.  Commands are:\n")
				var names := COMMANDS.keys()
				names.sort()
				var line := ""
				for k in names.size():
					line += "%-16s" % names[k]
					if k % 5 == 4:
						p.outln(line.strip_edges(false, true))
						line = ""
				if not line.is_empty():
					p.outln(line.strip_edges(false, true))
			else:
				for name in args:
					p.outln("%-16s%s" % [name, COMMANDS.get(name, "?Invalid help command %s" % name)])
			return
		"passive":
			_passive = not _passive
			p.outln("Passive mode %s." % ("on" if _passive else "off"))
			return
		"verbose":
			_verbose = not _verbose
			p.outln("Verbose mode %s." % ("on" if _verbose else "off"))
			return
		"lcd":
			var dir: String = args[0] if not args.is_empty() else str(p.env.get("HOME", "/"))
			var path := AgoraPath.normalize(dir, p.cwd)
			if p.machine.vfs.is_dir(p.cred, path):
				p.cwd = path
				p.outln("Local directory now %s" % path)
			else:
				p.outln("local: %s: No such file or directory" % dir)
			return
		"status":
			p.outln("Connected to %s." % _host if _connected else "Not connected.")
			p.outln("Mode: stream; Type: %s; Form: non-print; Structure: file" % ("binary" if _binary else "ascii"))
			p.outln("Verbose: %s; Passive: %s" % ["on" if _verbose else "off", "on" if _passive else "off"])
			return
	if not _connected:
		p.outln("Not connected.")
		return
	match cmd:
		"close":
			await _quit()
		"user":
			if args.is_empty():
				p.outln("usage: user username [password]")
			else:
				await _login(args[0], args[1] if args.size() > 1 else null)
		"pwd":
			await _simple("PWD")
		"cd":
			await _simple("CWD " + (args[0] if not args.is_empty() else ""))
		"cdup":
			await _simple("CDUP")
		"system":
			await _simple("SYST", true)
		"binary":
			_binary = true
			await _simple("TYPE I")
		"ascii":
			_binary = false
			await _simple("TYPE A")
		"type":
			if args.is_empty():
				p.outln("Using %s mode to transfer files." % ("binary" if _binary else "ascii"))
			else:
				await _run("binary" if args[0] in ["binary", "image"] else "ascii", [])
		"delete":
			await _simple("DELE " + _arg(args))
		"mkdir":
			await _simple("MKD " + _arg(args))
		"rmdir":
			await _simple("RMD " + _arg(args))
		"size":
			await _simple("SIZE " + _arg(args), true)
		"rename":
			if args.size() < 2:
				p.outln("usage: rename from-name to-name")
				return
			var r := await _command("RNFR " + args[0])
			if r.code == 350:
				await _simple("RNTO " + args[1])
		"ls", "dir", "nlist":
			# netkit's ls is the long listing, like dir; nlist gives bare names.
			await _transfer("NLST" if cmd == "nlist" else "LIST", _arg(args), "", false)
		"get", "recv":
			if args.is_empty():
				p.outln("usage: get remote-file [local-file]")
				return
			var local := args[1] if args.size() > 1 else AgoraPath.basename(args[0])
			await _transfer("RETR", args[0], local, false)
		"put", "send":
			if args.is_empty():
				p.outln("usage: put local-file [remote-file]")
				return
			var remote := args[1] if args.size() > 1 else AgoraPath.basename(args[0])
			await _transfer("STOR", remote, args[0], true)
		"mget":
			for pattern in args:
				var names := await _names(pattern)
				for n in names:
					await _transfer("RETR", n, AgoraPath.basename(n), false)
		"mput":
			for name in args:
				await _transfer("STOR", AgoraPath.basename(name), name, true)


static func _arg(args: PackedStringArray) -> String:
	return " ".join(args)


# --- the control connection ----------------------------------------------------

func _open(args: PackedStringArray) -> void:
	var host := args[0]
	var port := args[1].to_int() if args.size() > 1 and args[1].is_valid_int() else 21
	var found: Dictionary = await AgoraResolver.resolve(p, host)
	var addr: int = found.get("addr", -1)
	if addr < 0:
		p.outln("ftp: %s: %s" % [host, AgoraResolver.message(found.error)])
		return
	var r: Dictionary = await p.machine.net.tcp.open_connection(p, addr, port)
	if r.has("error"):
		p.outln("ftp: connect: %s" % AgoraErrno.describe(r.error))
		return
	_ctrl = r.conn
	_ctrl.pid = p.pid
	_ctrl.nodelay = true
	_host = host
	_connected = true
	p.outln("Connected to %s." % host)
	var hello := await _reply()
	_show(hello, true)
	if hello.code != 220 or not _auto_login:
		return
	var default_user := str(p.env.get("USER", ""))
	if _interactive:
		p.out("Name (%s:%s): " % [host, default_user])
	var name: Variant = await p.read_line()
	if name == null:
		return
	var user := str(name).strip_edges()
	await _login(user if not user.is_empty() else default_user, null)


func _login(user: String, password: Variant) -> void:
	var r := await _command("USER " + user)
	_show(r, true)
	if r.code == 331:
		if password == null:
			password = await read_secret(p, "Password:")
			if password == null:
				return
		r = await _command("PASS " + str(password))
		_show(r, true)
	if r.code != 230:
		p.outln("Login failed.")
		return
	var syst := await _command("SYST")
	if syst.code == 215 and syst.text.begins_with("UNIX Type: L8"):
		p.outln("Remote system type is UNIX.")
		p.outln("Using binary mode to transfer files.")
		_binary = true
		await _command("TYPE I")


func _quit() -> void:
	var r := await _command("QUIT")
	_show(r, true)
	_ctrl.close()
	_connected = false


## Reads one reply, multi-line ones included: {code, text, lines}.
func _reply() -> Dictionary:
	var stop := func() -> bool: return p.is_dead()
	var lines: PackedStringArray = []
	var first: Variant = await _ctrl.input.read_line(stop)
	if first == null:
		_lost()
		return {"code": 421, "text": "Service not available, remote server has closed connection", "lines": lines}
	var line := str(first).trim_suffix("\r")
	lines.append(line)
	var code := line.left(3).to_int()
	if line.length() > 3 and line[3] == "-":
		while true:
			var more: Variant = await _ctrl.input.read_line(stop)
			if more == null:
				break
			var l := str(more).trim_suffix("\r")
			lines.append(l)
			if l.begins_with("%d " % code):
				break
	return {"code": code, "text": lines[-1].substr(4), "lines": lines}


func _lost() -> void:
	if _connected:
		p.outln("421 Service not available, remote server has closed connection")
		_connected = false
		_ctrl.close()


func _command(text: String) -> Dictionary:
	_ctrl.output.write(text + "\r\n")
	return await _reply()


## Shows a reply: everything when verbose, and errors always.
func _show(r: Dictionary, always_errors: bool) -> void:
	if _verbose or (always_errors and r.code >= 400):
		for l in r.lines:
			p.outln(l)


func _simple(text: String, show_always: bool = false) -> Dictionary:
	var r := await _command(text)
	if show_always and not _verbose:
		p.outln(r.lines[-1])
	else:
		_show(r, true)
	return r


# --- data connections ----------------------------------------------------------

## Sets up the data connection before a transfer command. Active: listen
## and send PORT. Passive: send PASV and connect. Returns {listener} or
## {conn}, or {} after an error.
func _prepare_data() -> Dictionary:
	var tcp := p.machine.net.tcp
	if _passive:
		var r := await _command("PASV")
		_show(r, true)
		if r.code != 227:
			return {}
		var inner: String = r.text.get_slice("(", 1).get_slice(")", 0)
		var n := inner.split(",")
		if n.size() != 6:
			p.outln("Passive mode address scan failure. Shouldn't happen!")
			return {}
		var addr := AgoraInet.parse(".".join(n.slice(0, 4)))
		var c: Dictionary = await tcp.open_connection(p, addr, n[4].to_int() * 256 + n[5].to_int())
		if c.has("error"):
			p.outln("ftp: connect: %s" % AgoraErrno.describe(c.error))
			return {}
		c.conn.pid = p.pid
		return {"conn": c.conn}
	var listener := tcp.listen(p, 0, _ctrl.local_addr, 1)
	if listener == null:
		p.outln("ftp: bind: %s" % AgoraErrno.describe(tcp.last_error))
		return {}
	var a := AgoraInet.to_str(_ctrl.local_addr).replace(".", ",")
	var r := await _command("PORT %s,%d,%d" % [a, listener.port >> 8, listener.port & 255])
	_show(r, true)
	if r.code != 200:
		listener.close()
		return {}
	return {"listener": listener}


func _transfer(verb: String, remote: String, local: String, sending: bool) -> void:
	var listing := verb in ["LIST", "NLST"]
	var data_bytes := PackedByteArray()
	if sending:
		var path := AgoraPath.normalize(local, p.cwd)
		data_bytes = p.machine.vfs.read_file(p.cred, path)
		if p.machine.vfs.errno != AgoraErrno.OK:
			p.outln("local: %s: %s" % [local, AgoraErrno.describe(p.machine.vfs.errno)])
			return
	elif not listing:
		var path := AgoraPath.normalize(local, p.cwd)
		var e := p.machine.vfs.write_file(p.cred, path, PackedByteArray(), "/", true)
		if e != AgoraErrno.OK:
			p.outln("local: %s: %s" % [local, AgoraErrno.describe(e)])
			return
	if not listing and _verbose:
		p.outln("local: %s remote: %s" % [local, remote])
	var setup := await _prepare_data()
	if setup.is_empty():
		return
	var started := Time.get_ticks_usec()
	var r := await _command(verb + (" " + remote if not remote.is_empty() else ""))
	_show(r, true)
	if r.code >= 300:
		if setup.has("listener"):
			setup.listener.close()
		elif setup.has("conn"):
			setup.conn.close()
		return
	var conn: AgoraTcp.Conn = setup.get("conn")
	if setup.has("listener"):
		var listener: AgoraTcp.Listener = setup.listener
		conn = await listener.accept(p.is_dead)
		listener.close()
		if conn == null:
			return
		conn.pid = p.pid
	var count := 0
	if sending:
		var text := AgoraWire.raw(data_bytes) if _binary else data_bytes.get_string_from_utf8().replace("\n", "\r\n")
		conn.output.write(text)
		count = data_bytes.size()
		conn.close()
	else:
		var text := await conn.input.read_all(p.is_dead)
		conn.close()
		if listing or not _binary:
			text = text.replace("\r\n", "\n")
		var bytes := AgoraWire.encode(text)
		count = bytes.size()
		if listing:
			p.out(bytes.get_string_from_utf8())
		else:
			p.machine.vfs.write_file(p.cred, AgoraPath.normalize(local, p.cwd), bytes)
	var done := await _reply()
	_show(done, true)
	if not listing and _verbose and done.code == 226:
		var secs := maxf((Time.get_ticks_usec() - started) / 1000000.0, 0.0001)
		p.outln("%d bytes %s in %.2f secs (%.1f kB/s)" % [count, "sent" if sending else "received", secs, count / secs / 1024.0])


## Remote names matching [param pattern] (NLST), for mget.
func _names(pattern: String) -> PackedStringArray:
	var setup := await _prepare_data()
	if setup.is_empty():
		return []
	var r := await _command("NLST")
	_show(r, true)
	if r.code >= 300:
		return []
	var conn: AgoraTcp.Conn = setup.get("conn")
	if setup.has("listener"):
		conn = await setup.listener.accept(p.is_dead)
		setup.listener.close()
	var text := await conn.input.read_all(p.is_dead)
	conn.close()
	_show(await _reply(), true)
	var out: PackedStringArray = []
	for n in text.split("\r\n", false):
		if n.match(pattern):
			out.append(n)
	return out
