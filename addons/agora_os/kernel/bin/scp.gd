extends AgoraProgram
## scp (OpenSSH 4.3): copies files between machines over ssh. For a remote
## side it runs "ssh host scp -t TARGET" (to send) or "scp -f SOURCE" (to
## receive) and speaks the rcp protocol with the scp at the other end:
##
##   C0644 SIZE NAME\n  a file, then SIZE bytes and a NUL
##   D0755 0 NAME\n     into a directory (-r) ... E\n to come out
##   T MTIME 0 ATIME 0  the times of what follows (-p)
##
## Every line and every file is answered with a NUL (ready), or 1 and a
## message (a warning: "scp: x: No such file or directory") or 2 and one
## (fatal). Two remote sides: the first one sends to the second itself.
## With a terminal on stdout it shows a progress line per file.

## How bytes travel in a text stream (see AgoraWire.raw).
var NUL := AgoraWire.raw_byte(0)

var p: AgoraProcess
var _recursive := false
var _preserve := false
var _quiet := false
var _port := ""
var _errors := 0
var _fatal := false
## What has come from the other side and not been used yet.
var _buf := ""
var _in: AgoraStream
var _out: AgoraStream


func summary() -> String:
	return "secure copy (remote file copy program)"


func usage() -> String:
	return "usage: scp [-pqrv] [-P port] [-o ssh_option] [[user@]host1:]file1 [...] [[user@]host2:]file2"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "Pol")
	_recursive = a.has("r")
	_preserve = a.has("p")
	_quiet = a.has("q") or not is_terminal(p)
	_port = a.value("P", "")
	if a.has("t") or a.has("f"):
		# The far end, run by ssh: stdin and stdout are the connection.
		_in = p.stdin
		_out = p.stdout
		if a.has("t"):
			await _sink(a.operands[0] if not a.operands.is_empty() else ".", a.has("d"))
		elif await _wait_ready(): # the sink speaks first
			for src in a.operands:
				if not _fatal:
					await _send(src)
		return 1 if _errors > 0 else 0
	if a.operands.size() < 2:
		p.errln(usage())
		return 1
	var target: String = a.operands[-1]
	var sources: PackedStringArray = a.operands.slice(0, a.operands.size() - 1)
	var to := _remote(target)
	# Local files go to a remote target together, over one connection.
	var local: PackedStringArray = []
	if not to.is_empty():
		for src in sources:
			if _remote(src).is_empty():
				local.append(src)
		if not local.is_empty() and not await _upload(local, to, sources.size() > 1):
			_errors += 1
	for src in sources:
		if local.has(src):
			continue
		var from := _remote(src)
		if not to.is_empty() and not from.is_empty():
			# Remote to remote: the first host sends to the second.
			var cmd := "scp%s%s %s %s" % [" -r" if _recursive else "", " -p" if _preserve else "", _quote(from.path), _quote(target)]
			if await _ssh_run(from, cmd) != 0:
				_errors += 1
		elif not from.is_empty():
			if not await _download(from, target):
				_errors += 1
		else:
			# Both local: cp does it, as scp does.
			var argv := PackedStringArray(["cp"])
			if _recursive:
				argv.append("-r")
			if _preserve:
				argv.append("-p")
			argv.append_array([src, target])
			if await p.run(argv) != 0:
				_errors += 1
	return 1 if _errors > 0 else 0


## "[user@]host:path" -> {user, host, path}; {} for a local path. A colon
## after a slash is part of a local file name.
static func _remote(spec: String) -> Dictionary:
	var colon := spec.find(":")
	if colon <= 0 or (spec.find("/") >= 0 and spec.find("/") < colon):
		return {}
	var host := spec.substr(0, colon)
	var user := ""
	if host.contains("@"):
		user = host.get_slice("@", 0)
		host = host.get_slice("@", 1)
	return {"user": user, "host": host, "path": spec.substr(colon + 1)}


static func _quote(text: String) -> String:
	if text.is_empty():
		return "''"
	for ch in text:
		if not (ch.is_valid_identifier() or ch.is_valid_int() or ch in "/._-:@~+="):
			return "'" + text.replace("'", "'\\''") + "'"
	return text


## ssh to [param r] running [param command], its stdin and stdout ours to
## talk through. Returns the ssh process.
func _ssh(r: Dictionary, command: String) -> AgoraProcess:
	var argv := PackedStringArray(["ssh", "-x"])
	if p.tty == null:
		argv.append("-oBatchMode=yes") # nobody to ask for a password
	if not _port.is_empty():
		argv.append_array(["-p", _port])
	if not str(r.user).is_empty():
		argv.append_array(["-l", str(r.user)])
	argv.append_array([str(r.host), command])
	var to_ssh := AgoraStream.new()
	to_ssh.add_writer()
	var from_ssh := AgoraStream.new()
	from_ssh.add_reader()
	var child := p.spawn(argv, {"stdin": to_ssh, "stdout": from_ssh})
	if child == null:
		p.errln("scp: ssh: %s" % AgoraErrno.describe(p.errno))
		return null
	_in = from_ssh
	_out = to_ssh
	_buf = ""
	_fatal = false
	return child


## Runs [param command] there on our own terminal, so the far scp can
## ask for the next host's password.
func _ssh_run(r: Dictionary, command: String) -> int:
	var argv := PackedStringArray(["ssh", "-x", "-t"])
	if not _port.is_empty():
		argv.append_array(["-p", _port])
	if not str(r.user).is_empty():
		argv.append_array(["-l", str(r.user)])
	argv.append_array([str(r.host), command])
	return await p.run(argv)


func _finish(child: AgoraProcess) -> int:
	_out.release_writer()
	var code := await child.wait()
	_in.release_reader()
	return code


func _upload(srcs: PackedStringArray, to: Dictionary, many: bool) -> bool:
	var cmd := "scp%s%s -t %s%s" % [" -r" if _recursive else "", " -p" if _preserve else "", "-d " if many else "", _quote(str(to.path) if not str(to.path).is_empty() else ".")]
	var child := _ssh(to, cmd)
	if child == null:
		return false
	var before := _errors
	if await _wait_ready():
		for src in srcs:
			if not _fatal:
				await _send(src)
	var code := await _finish(child)
	return code == 0 and _errors == before


func _download(from: Dictionary, target: String) -> bool:
	var cmd := "scp%s%s -f %s" % [" -r" if _recursive else "", " -p" if _preserve else "", _quote(str(from.path) if not str(from.path).is_empty() else ".")]
	var child := _ssh(from, cmd)
	if child == null:
		return false
	var before := _errors
	await _sink(target, false)
	var code := await _finish(child)
	return code == 0 and _errors == before


# --- reading the other side ----------------------------------------------------

## Waits until [param n] characters have come; false at the end.
func _read(n: int) -> bool:
	while _buf.length() < n:
		var chunk: Variant = await _in.read_some(p.is_dead)
		if chunk == null:
			return false
		_buf += str(chunk)
	return true


func _take(n: int) -> String:
	var out := _buf.substr(0, n)
	_buf = _buf.substr(n)
	return out


## A line from the other side without its newline, or null at the end.
func _line() -> Variant:
	while not _buf.contains("\n"):
		var chunk: Variant = await _in.read_some(p.is_dead)
		if chunk == null:
			return null
		_buf += str(chunk)
	var at := _buf.find("\n")
	var line := _buf.substr(0, at)
	_buf = _buf.substr(at + 1)
	return line


## The answer to what we sent: true for NUL. A warning (1) or an error
## (2) is printed and counted; after an error, or when the other side is
## gone, [member _fatal] is set and nothing more is sent.
func _wait_ready() -> bool:
	if _fatal:
		return false
	if not await _read(1):
		_errors += 1
		_fatal = true
		return false
	var c := _take(1)
	if c == NUL:
		return true
	var message: Variant = await _line()
	p.err(str(message) + "\n")
	_errors += 1
	_fatal = c != char(1)
	return false


func _warn(text: String) -> void:
	_errors += 1
	_out.write(char(1) + "scp: " + text + "\n")


# --- sending (the source) ------------------------------------------------------

func _send(path: String) -> void:
	var st := p.stat(path)
	if st == null:
		_tell("%s: %s" % [path, AgoraErrno.describe(p.errno)])
		return
	var name := AgoraPath.basename(path.trim_suffix("/")) if path != "/" else "/"
	if _preserve:
		_out.write("T%d 0 %d 0\n" % [st.mtime, st.mtime])
		if not await _wait_ready():
			return
	if st.is_dir():
		if not _recursive:
			_tell("%s: not a regular file" % path)
			return
		_out.write("D%04o 0 %s\n" % [st.mode & 511, name])
		if not await _wait_ready():
			return
		for child in p.list_dir(path):
			if _fatal:
				return
			await _send(path.trim_suffix("/") + "/" + child)
		_out.write("E\n")
		await _wait_ready()
		return
	var data := p.read_bytes(path)
	if p.errno != AgoraErrno.OK:
		_tell("%s: %s" % [path, AgoraErrno.describe(p.errno)])
		return
	_out.write("C%04o %d %s\n" % [st.mode & 511, data.size(), name])
	if not await _wait_ready():
		return
	_out.write(AgoraWire.raw(data) + NUL)
	if await _wait_ready():
		_progress(name, data.size())


## A problem on the sending side: the receiver hears of it (and prints it
## when it is us at the far end), and so do we.
func _tell(text: String) -> void:
	_errors += 1
	if _out == p.stdout:
		_out.write(char(1) + "scp: " + text + "\n")
	else:
		p.errln("scp: " + text)


func _progress(name: String, size: int) -> void:
	if _quiet:
		return
	var width := (p.tty.cols if p.tty else 80) - 39
	var shown := "%d" % size if size < 1024 else ("%dKB" % (size / 1024) if size < 1048576 else "%.1fMB" % (size / 1048576.0))
	p.outln("%s %3d%% %5s %5.1fKB/s   00:00" % [name.rpad(maxi(10, width)).left(maxi(10, width)), 100, shown, size / 1024.0])


# --- receiving (the sink) ------------------------------------------------------

## Receives what the source sends into [param target]: a directory, or
## the name for a single file. [param must_be_dir] (-d) for several files.
func _sink(target: String, must_be_dir: bool) -> void:
	var is_dir := p.is_dir(target)
	if must_be_dir and not is_dir:
		_out.write(char(2) + "scp: %s: Not a directory\n" % target)
		_errors += 1
		return
	_out.write(NUL)
	var dirs: Array[String] = [target]
	var times := -1
	while true:
		var line: Variant = await _line()
		if line == null:
			return
		var text := str(line)
		if text.is_empty():
			continue
		var kind := text.left(1)
		var body := text.substr(1)
		match kind:
			char(1), char(2):
				p.errln(body)
				_errors += 1
				if kind == char(2):
					return
				continue
			"T":
				times = body.get_slice(" ", 0).to_int()
				_out.write(NUL)
				continue
			"E":
				if dirs.size() > 1:
					dirs.pop_back()
				_out.write(NUL)
				continue
			"C", "D":
				var w := body.split(" ", false, 2)
				if w.size() < 3:
					_out.write(char(2) + "scp: protocol error: bad mode\n")
					_errors += 1
					return
				var mode := _octal(w[0])
				var size := w[1].to_int()
				var name := w[2]
				if name.contains("/") or name == "..":
					_out.write(char(2) + "scp: protocol error: unexpected filename: %s\n" % name)
					_errors += 1
					return
				# At the top: into the target directory, or as the target.
				var dest: String = (dirs[-1].trim_suffix("/") + "/" + name) if dirs.size() > 1 or is_dir else target
				if kind == "D":
					if not _recursive:
						_out.write(char(2) + "scp: received directory without -r\n")
						_errors += 1
						return
					if not p.is_dir(dest):
						var e := p.mkdir(dest, mode)
						if e != AgoraErrno.OK:
							_out.write(char(1) + "scp: %s: %s\n" % [dest, AgoraErrno.describe(e)])
							_errors += 1
							return
					dirs.append(dest)
					_out.write(NUL)
					times = -1
					continue
				_out.write(NUL)
				if not await _read(size + 1):
					return
				var raw := _take(size)
				_take(1) # the NUL after the data
				var bytes := PackedByteArray()
				for k in raw.length():
					bytes.append(maxi(AgoraWire.byte_of(raw.unicode_at(k)), 0) & 255)
				var e := p.write_bytes(dest, bytes, false, mode)
				if e != AgoraErrno.OK:
					_out.write(char(1) + "scp: %s: %s\n" % [dest, AgoraErrno.describe(e)])
					_errors += 1
					times = -1
					continue
				if _preserve:
					p.machine.vfs.chmod(p.cred, dest, mode, p.cwd)
				if times >= 0:
					p.machine.vfs.touch_time(p.cred, dest, times, p.cwd)
				times = -1
				_out.write(NUL)
				_progress(name, size)
			_:
				_out.write(char(2) + "scp: protocol error: expected control record\n")
				_errors += 1
				return


static func _octal(text: String) -> int:
	var n := 0
	for ch in text:
		if ch < "0" or ch > "7":
			return 420
		n = n * 8 + ch.to_int()
	return n
