extends AgoraProgram
## GNU Wget 1.10.2: fetches files over HTTP. Its log goes to standard
## error: the request, the response, a progress line and where the file
## was saved. Redirects are followed (up to 20). A file that exists gets
## the next free ".1", ".2"... name.
##
## Options: -O FILE (- for standard output), -q, -S (show the response
## headers), -U AGENT, --post-data=DATA, -T SECONDS, -t TRIES (accepted).

const VERSION := "1.10.2"
const MAX_REDIRECTS := 20

var p: AgoraProcess
var _quiet := false
var _show_headers := false
var _agent := "Wget/" + VERSION
var _post: Variant = null
var _timeout := 900.0


func summary() -> String:
	return "The non-interactive network downloader"


func usage() -> String:
	return "Usage: wget [OPTION]... [URL]..."


func main(proc: AgoraProcess) -> int:
	p = proc
	var urls: PackedStringArray = []
	var output := ""
	var args := p.argv.slice(1)
	var k := 0
	while k < args.size():
		var a := args[k]
		var next := args[k + 1] if k + 1 < args.size() else ""
		if a in ["-O", "-U", "-T", "-t"]:
			k += 1 # the option's value
		if a == "-O":
			output = next
		elif a.begins_with("-O") and a.length() > 2:
			output = a.substr(2)
		elif a.begins_with("--output-document="):
			output = a.get_slice("=", 1)
		elif a in ["-q", "--quiet"]:
			_quiet = true
		elif a in ["-S", "--server-response"]:
			_show_headers = true
		elif a == "-U":
			_agent = next
		elif a.begins_with("--user-agent="):
			_agent = a.substr(a.find("=") + 1)
		elif a.begins_with("--post-data="):
			_post = a.substr(a.find("=") + 1)
		elif a in ["-T", "-t"]:
			if a == "-T":
				_timeout = next.to_float()
		elif a.begins_with("--timeout="):
			_timeout = a.get_slice("=", 1).to_float()
		elif a in ["-V", "--version"]:
			p.outln("GNU Wget %s\n\nCopyright (C) 2005 Free Software Foundation, Inc." % VERSION)
			return 0
		elif a in ["-h", "--help"]:
			p.outln("GNU Wget %s, a non-interactive network retriever.\n%s" % [VERSION, usage()])
			return 0
		elif a.begins_with("-") and a.length() > 1:
			p.errln("wget: invalid option -- %s" % a.trim_prefix("-").trim_prefix("-"))
			p.errln(usage() + "\n\nTry `wget --help' for more options.")
			return 1
		else:
			urls.append(a)
		k += 1
	if urls.is_empty():
		p.errln("wget: missing URL")
		p.errln(usage() + "\n\nTry `wget --help' for more options.")
		return 1
	var status := 0
	for url in urls:
		if await _fetch(url, output) != 0:
			status = 1
	return status


func _log(text: String) -> void:
	if not _quiet:
		p.errln(text)


func _clock() -> String:
	var d := p.machine.clock.local_datetime()
	return "%02d:%02d:%02d" % [d.hour, d.minute, d.second]


## {scheme, host, port, path} or {} for a URL we can't fetch.
static func parse_url(url: String) -> Dictionary:
	var scheme := "http"
	var rest := url
	if url.contains("://"):
		scheme = url.get_slice("://", 0).to_lower()
		rest = url.substr(url.find("://") + 3)
	var host_port := rest.get_slice("/", 0)
	var path := rest.substr(host_port.length())
	if path.is_empty():
		path = "/"
	var host := host_port.get_slice(":", 0)
	var port := 80
	if host_port.contains(":"):
		port = host_port.get_slice(":", 1).to_int()
	return {"scheme": scheme, "host": host, "port": port, "path": path,
		"url": "%s://%s%s%s" % [scheme, host, ":%d" % port if port != 80 else "", path]}


## The local file name: the last part of the path, or index.html.
func _local_name(u: Dictionary) -> String:
	var path := str(u.path).get_slice("?", 0)
	var name := "" if path.ends_with("/") else AgoraPath.basename(path)
	if name.is_empty():
		name = "index.html"
	var candidate := name
	var n := 1
	while p.exists(candidate):
		candidate = "%s.%d" % [name, n]
		n += 1
	return candidate


func _fetch(url: String, output: String) -> int:
	var u := parse_url(url)
	for hop in MAX_REDIRECTS + 1:
		if u.scheme != "http":
			_log("%s: Unsupported scheme." % url)
			return 1
		var target := output if not output.is_empty() else _local_name(u)
		_log("--%s--  %s" % [_clock(), u.url])
		if output != "-":
			_log("           => `%s'" % target)
		var addr := AgoraInet.parse(u.host)
		if addr < 0:
			if not _quiet:
				p.err("Resolving %s... " % u.host)
			var found: Dictionary = await AgoraResolver.resolve(p, u.host)
			addr = found.get("addr", -1)
			if addr < 0:
				_log("failed: %s." % AgoraResolver.message(found.error))
				return 1
			_log(AgoraInet.to_str(addr))
			if not _quiet:
				p.err("Connecting to %s|%s|:%d... " % [u.host, AgoraInet.to_str(addr), u.port])
		elif not _quiet:
			p.err("Connecting to %s:%d... " % [u.host, u.port])
		var r: Dictionary = await p.machine.net.tcp.open_connection(p, addr, u.port)
		if r.has("error"):
			_log("failed: %s." % AgoraErrno.describe(r.error))
			return 1
		_log("connected.")
		var conn: AgoraTcp.Conn = r.conn
		conn.pid = p.pid
		var request := "%s %s HTTP/1.0\r\nUser-Agent: %s\r\nAccept: */*\r\nHost: %s\r\nConnection: Keep-Alive\r\n" % [
			"POST" if _post != null else "GET", u.path, _agent, u.host if u.port == 80 else "%s:%d" % [u.host, u.port]]
		if _post != null:
			request += "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n" % str(_post).to_utf8_buffer().size()
		request += "\r\n" + (str(_post) if _post != null else "")
		conn.output.write(request)
		if not _quiet:
			p.err("HTTP request sent, awaiting response... ")
		var deadline := Time.get_ticks_msec() + int(_timeout * 1000)
		var text := await conn.input.read_all(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
		conn.close()
		var split := text.find("\r\n\r\n")
		if split < 0 or not text.begins_with("HTTP/"):
			_log("\n%s ERROR -1: Malformed status line." % _clock())
			return 1
		var head := text.substr(0, split).split("\r\n")
		var body := text.substr(split + 4)
		var status_line := head[0]
		var code := status_line.get_slice(" ", 1).to_int()
		var reason := status_line.substr(status_line.find(" ", status_line.find(" ") + 1) + 1)
		var headers := {}
		for h in head.slice(1):
			headers[h.get_slice(":", 0).strip_edges().to_lower()] = h.substr(h.find(":") + 1).strip_edges()
		if _show_headers and not _quiet:
			p.errln("")
			for h in head:
				p.errln("  " + h)
		else:
			_log("%d %s" % [code, reason])
		if code in [301, 302, 303, 307] and headers.has("location"):
			var loc: String = headers.location
			if loc.begins_with("/"):
				loc = "http://%s%s%s" % [u.host, ":%d" % u.port if u.port != 80 else "", loc]
			_log("Location: %s [following]" % loc)
			u = parse_url(loc)
			_post = null
			continue
		if code >= 400 or code < 200:
			_log("%s ERROR %d: %s.\n" % [_clock(), code, reason])
			return 1
		var bytes := AgoraWire.encode(body)
		var type: String = str(headers.get("content-type", "")).get_slice(";", 0)
		if headers.has("content-length"):
			var n := str(headers["content-length"]).to_int()
			_log("Length: %s%s [%s]\n" % [_commas(n), " (%s)" % _human(n) if n >= 1024 else "", type])
		else:
			_log("Length: unspecified [%s]\n" % type)
		var started := Time.get_ticks_usec()
		if output == "-":
			p.out(bytes.get_string_from_utf8())
		else:
			var e := p.machine.vfs.write_file(p.cred, AgoraPath.normalize(target, p.cwd), bytes)
			if e != AgoraErrno.OK:
				_log("%s: %s" % [target, AgoraErrno.describe(e)])
				return 1
		var secs := maxf((Time.get_ticks_usec() - started) / 1000000.0, 0.00001)
		var rate := _rate(bytes.size() / secs)
		_log("    0K %s 100%% %s\n" % [" ".repeat(52), rate])
		if output != "-":
			_log("%s (%s) - `%s' saved [%d/%d]\n" % [_clock(), rate, target, bytes.size(), bytes.size()])
		return 0
	_log("%d redirections exceeded." % MAX_REDIRECTS)
	return 1


static func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.right(3) + out
		s = s.left(s.length() - 3)
	return s + out


static func _human(n: int) -> String:
	if n < 1024 * 1024:
		return "%.1fK" % (n / 1024.0) if n < 10240 else "%dK" % (n / 1024)
	return "%.1fM" % (n / 1048576.0)


static func _rate(bytes_per_sec: float) -> String:
	if bytes_per_sec >= 1048576.0:
		return "%.2f MB/s" % (bytes_per_sec / 1048576.0)
	return "%.2f KB/s" % (bytes_per_sec / 1024.0)
