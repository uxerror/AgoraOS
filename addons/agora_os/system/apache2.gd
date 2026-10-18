extends AgoraProgram
## apache2 (Apache 2.2.3 as Debian ships it): the web server. It reads
## /etc/apache2/apache2.conf and what that includes (ports.conf, conf.d/,
## sites-enabled/), listens on the Listen ports, and answers HTTP/1.0 and
## 1.1 requests (GET, HEAD, POST) one per connection.
##
## Files come from DocumentRoot with www-data's permissions; a directory
## gets its DirectoryIndex file, a listing if its <Directory> has Options
## Indexes, or 403. ScriptAlias directories hold CGI programs, run as
## www-data with the CGI/1.1 environment, the request body on stdin and
## the response on stdout. Requests go to the CustomLog in the combined
## format, problems to the ErrorLog, and error pages look like Apache's.
##
## <VirtualHost> blocks are name-based: the Host header picks the one whose
## ServerName or ServerAlias matches, and the first one answers the rest.

const VERSION := "2.2.3"
const DEFAULT_CONF := "/etc/apache2/apache2.conf"
const READ_TIMEOUT := 30.0
const CGI_TIMEOUT := 30.0
const DAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const REASONS := {
	200: "OK", 301: "Moved Permanently", 302: "Found", 304: "Not Modified", 400: "Bad Request",
	403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Time-out",
	500: "Internal Server Error", 501: "Method Not Implemented",
}

var p: AgoraProcess
var _www: AgoraCred
var _conf := {}
var _listeners: Array[AgoraTcp.Listener] = []


func summary() -> String:
	return "Apache Hypertext Transfer Protocol Server"


func usage() -> String:
	return "Usage: apache2 [-D name] [-f file] [-k start|stop] [-v] [-t]"


func main(proc: AgoraProcess) -> int:
	p = proc
	var a := AgoraArgs.parse(p.argv, "fdkD")
	if a.has("v"):
		p.outln("Server version: Apache/%s (Debian)" % VERSION)
		p.outln("Server built:   Jan 18 2007 12:00:00")
		return 0
	_conf = load_config(p, a.value("f") if a.has("f") else DEFAULT_CONF)
	if a.has("t"):
		p.errln("Syntax OK")
		return 0
	if not p.cred.is_root():
		return p.fail("(13)Permission denied: make_sock: could not bind to address 0.0.0.0:80\nno listening sockets available, shutting down", 1)
	var user: String = _conf.user
	if p.machine.users.find(user).is_empty():
		return p.fail("apache2: bad user name %s" % user, 1)
	_www = p.machine.users.cred_for(user)
	for port: int in _conf.listen:
		var l := p.machine.net.tcp.listen(p, port)
		if l == null:
			_error("", "(98)%s: make_sock: could not bind to address 0.0.0.0:%d" % [AgoraErrno.describe(p.machine.net.tcp.last_error), port])
			p.errln("(98)Address already in use: make_sock: could not bind to address 0.0.0.0:%d" % port)
			p.errln("no listening sockets available, shutting down")
			for other in _listeners:
				other.close()
			return 1
		_listeners.append(l)
	_error("", "Apache/%s (Debian) configured -- resuming normal operations" % VERSION, "notice")
	for l in _listeners:
		_accept_loop(l)
	while p.is_running():
		await p.sleep(1.0)
	for l in _listeners:
		l.close()
	_error("", "caught SIGTERM, shutting down", "notice")
	return 0


func _accept_loop(l: AgoraTcp.Listener) -> void:
	while p.is_running():
		var conn: AgoraTcp.Conn = await l.accept(p.is_dead)
		if conn == null:
			return
		_handle(conn)


# --- configuration -------------------------------------------------------------

## The parts of the configuration this server uses: listen, user,
## server_name, doc_root, index, dirs ({path: options}), script_alias,
## error_log, custom_log, tokens, signature.
static func load_config(proc: AgoraProcess, path: String) -> Dictionary:
	var conf := {
		"listen": [], "user": "www-data", "server_name": proc.machine.hostname, "doc_root": "/var/www",
		"index": PackedStringArray(["index.html"]), "dirs": {}, "script_alias": {}, "alias": {},
		"error_log": "/var/log/apache2/error.log", "custom_log": "", "tokens": "Full", "signature": "On",
		"ignore": PackedStringArray([".??*", "*~", "*#", "HEADER*", "README*", "RCS", "CVS", "*,v", "*,t"]),
		"vhosts": [], "names": PackedStringArray(), "userdir": "", "userdir_off": PackedStringArray(),
		"cgi_ext": PackedStringArray(),
	}
	_read_config(proc, path, conf, ["", conf], 0)
	# Each virtual host falls back on the main server's settings.
	for vh: Dictionary in conf.vhosts:
		for key in ["server_name", "doc_root", "custom_log", "error_log"]:
			if not vh.has(key):
				vh[key] = conf[key]
		if not vh.has("script_alias"):
			vh.script_alias = conf.script_alias
		if not vh.has("alias"):
			vh.alias = conf.alias
	if (conf.listen as Array).is_empty():
		conf.listen = [80]
	return conf


static func _read_config(proc: AgoraProcess, path: String, conf: Dictionary, dir: Array, depth: int) -> void:
	if depth > 8:
		return
	var st := proc.stat(path)
	if st == null:
		return
	if st.is_dir():
		var names := proc.list_dir(path)
		names.sort()
		for n in names:
			if not n.begins_with("."):
				_read_config(proc, path.trim_suffix("/") + "/" + n, conf, dir, depth + 1)
		return
	for raw_line in proc.read_text(path).split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var words := _words(line)
		var key := words[0].to_lower()
		var args := words.slice(1)
		if key.begins_with("<directory"):
			dir[0] = AgoraPath.normalize(line.substr(line.find(" ") + 1).trim_suffix(">").strip_edges().trim_prefix("\"").trim_suffix("\""))
			continue
		if key == "</directory>":
			dir[0] = ""
			continue
		if key.begins_with("<virtualhost"):
			var vh := {"names": PackedStringArray()}
			conf.vhosts.append(vh)
			dir[1] = vh
			continue
		if key == "</virtualhost>":
			dir[1] = conf
			continue
		var target: Dictionary = dir[1]
		if args.is_empty():
			continue
		match key:
			"include":
				_read_config(proc, args[0], conf, dir, depth + 1)
			"listen":
				var port := args[0].get_slice(":", args[0].count(":")).to_int()
				if port > 0 and not (conf.listen as Array).has(port):
					conf.listen.append(port)
			"user":
				conf.user = args[0]
			"servername":
				target.server_name = args[0].get_slice(":", 0)
				target.names = (target.names as PackedStringArray) + PackedStringArray([target.server_name.to_lower()])
			"serveralias":
				for n in args:
					target.names = (target.names as PackedStringArray) + PackedStringArray([n.to_lower()])
			"documentroot":
				target.doc_root = AgoraPath.normalize(args[0])
			"directoryindex":
				conf.index = args
			"scriptalias":
				if args.size() >= 2:
					if not target.has("script_alias"):
						target.script_alias = {}
					target.script_alias[args[0]] = args[1]
			"alias":
				if args.size() >= 2:
					if not target.has("alias"):
						target.alias = {}
					target.alias[args[0]] = args[1]
			"errorlog":
				target.error_log = args[0]
			"customlog":
				target.custom_log = args[0]
			"servertokens":
				conf.tokens = args[0]
			"serversignature":
				conf.signature = args[0]
			"indexignore":
				conf.ignore = (conf.ignore as PackedStringArray) + args
			"userdir":
				if args[0] == "disabled":
					conf.userdir_off = (conf.userdir_off as PackedStringArray) + args.slice(1)
				else:
					conf.userdir = args[0]
			"addhandler":
				if args[0] == "cgi-script":
					conf.cgi_ext = (conf.cgi_ext as PackedStringArray) + args.slice(1)
			"options":
				if not dir[0].is_empty():
					var opts: PackedStringArray = conf.dirs.get(dir[0], PackedStringArray())
					for o in args:
						if o.begins_with("-"):
							opts.erase(o.substr(1))
						else:
							opts.append(o.trim_prefix("+"))
					conf.dirs[dir[0]] = opts


## Words of a directive line, with "quoted strings" kept together.
static func _words(line: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur := ""
	var quoted := false
	for c in line.replace("\t", " "):
		if c == "\"":
			quoted = not quoted
		elif c == " " and not quoted:
			if not cur.is_empty():
				out.append(cur)
			cur = ""
		else:
			cur += c
	if not cur.is_empty():
		out.append(cur)
	return out


func _server() -> String:
	match str(_conf.tokens).to_lower():
		"prod", "productonly": return "Apache"
		"major": return "Apache/2"
		"minor": return "Apache/2.2"
		"min", "minimal": return "Apache/" + VERSION
	return "Apache/%s (Debian)" % VERSION


## Options of the <Directory> closest above [param path].
func _options(path: String) -> PackedStringArray:
	var best := ""
	for d: String in _conf.dirs:
		var hit := AgoraPath.is_inside(path, d)
		if d.contains("*"):
			hit = path.match(d) or path.match(d + "/*")
		if hit and d.length() > best.length():
			best = d
	return _conf.dirs.get(best, PackedStringArray())


# --- logs ----------------------------------------------------------------------

func _error(client: String, message: String, level: String = "error") -> void:
	var line := "[%s] [%s] %s%s\n" % [_ctime(), level, "[client %s] " % client if not client.is_empty() else "", message]
	_append(_conf.get("error_log", ""), line)


func _append(path: String, line: String) -> void:
	if path.is_empty():
		return
	var root := AgoraCred.root()
	var vfs := p.machine.vfs
	if not vfs.exists(root, path):
		vfs.make_dirs(root, AgoraPath.dirname(path))
		vfs.write_text(root, path, "", "/", false, 416) # 0o640
		vfs.chown(root, path, 0, 4) # root:adm
	vfs.write_text(root, path, line, "/", true)


func _ctime() -> String:
	var d := p.machine.clock.local_datetime()
	return "%s %s %02d %02d:%02d:%02d %d" % [DAYS[d.weekday], MONTHS[d.month - 1], d.day, d.hour, d.minute, d.second, d.year]


## [18/Oct/2026:12:00:00 +0300], as %t logs it.
func _log_time() -> String:
	var clock := p.machine.clock
	var d := clock.local_datetime()
	var tz := clock.tz_offset_minutes
	return "[%02d/%s/%d:%02d:%02d:%02d %s%02d%02d]" % [d.day, MONTHS[d.month - 1], d.year, d.hour, d.minute, d.second,
		"-" if tz < 0 else "+", absi(tz) / 60, absi(tz) % 60]


## RFC 1123 date in GMT, as HTTP wants it.
static func http_date(unix: float) -> String:
	var d := Time.get_datetime_dict_from_unix_time(int(unix))
	return "%s, %02d %s %d %02d:%02d:%02d GMT" % [DAYS[d.weekday], d.day, MONTHS[d.month - 1], d.year, d.hour, d.minute, d.second]


# --- requests ------------------------------------------------------------------

func _handle(conn: AgoraTcp.Conn) -> void:
	var client := AgoraInet.to_str(conn.remote_addr)
	var deadline := Time.get_ticks_msec() + int(READ_TIMEOUT * 1000)
	var stop := func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline
	var first: Variant = await conn.input.read_line(stop)
	if first == null:
		conn.close()
		return
	var req := {"line": str(first).trim_suffix("\r"), "client": client, "conn": conn, "headers": {}, "body": ""}
	var parts: PackedStringArray = (req.line as String).split(" ", false)
	if parts.size() == 2:
		parts.append("HTTP/0.9")
	if parts.size() != 3 or not parts[2].begins_with("HTTP/"):
		_finish(req, await _error_page(req, 400, ""))
		return
	req.method = parts[0]
	req.target = parts[1]
	req.protocol = parts[2]
	if req.protocol != "HTTP/0.9":
		while true:
			var line: Variant = await conn.input.read_line(stop)
			if line == null:
				conn.close()
				return
			var h := str(line).trim_suffix("\r")
			if h.is_empty():
				break
			if h.contains(":"):
				req.headers[h.get_slice(":", 0).strip_edges().to_lower()] = h.substr(h.find(":") + 1).strip_edges()
		var length := str(req.headers.get("content-length", "0")).to_int()
		var body := ""
		while AgoraWire.encode(body).size() < length:
			var chunk: Variant = await conn.input.read_some(stop)
			if chunk == null:
				break
			body += chunk
		req.body = body
	req.vh = _vhost(req)
	var response: Dictionary
	if req.method not in ["GET", "HEAD", "POST"]:
		response = await _error_page(req, 501, "")
	else:
		response = await _respond(req)
	_finish(req, response)


## {status, headers (Array of [name, value]), body, size} for a request.
func _respond(req: Dictionary) -> Dictionary:
	var target: String = req.target
	var path := _url_decode(target.get_slice("?", 0))
	if path.is_empty() or not path.begins_with("/"):
		return await _error_page(req, 400, "")
	req.query = target.substr(target.find("?") + 1) if target.contains("?") else ""
	var vh: Dictionary = req.vh
	for prefix: String in vh.script_alias:
		if path.begins_with(prefix) or path + "/" == prefix:
			return await _cgi(req, prefix, path)
	var fs_path := _map(vh, path)
	var vfs := p.machine.vfs
	var st := vfs.stat(_www, fs_path)
	if st == null:
		if vfs.errno == AgoraErrno.EACCES:
			_error(req.client, "(13)Permission denied: access to %s denied" % path)
			return await _error_page(req, 403, path)
		_error(req.client, "File does not exist: %s" % fs_path)
		return await _error_page(req, 404, path)
	if st.is_dir():
		if not path.ends_with("/"):
			var host := str(req.headers.get("host", vh.server_name))
			var loc := "http://%s%s/%s" % [host, path, "?" + req.query if not req.query.is_empty() else ""]
			var page := await _error_page(req, 301, path, loc)
			page.headers.insert(0, ["Location", loc])
			return page
		for index in _conf.index:
			var candidate: String = fs_path.trim_suffix("/") + "/" + index
			if vfs.stat(_www, candidate) != null:
				return await _file(req, candidate, path + index)
		if "Indexes" in _options(fs_path):
			return await _listing(req, fs_path, path)
		_error(req.client, "Directory index forbidden by Options directive: %s" % fs_path.trim_suffix("/") + "/")
		return await _error_page(req, 403, path)
	if ("." + fs_path.get_extension()) in _conf.cgi_ext and "ExecCGI" in _options(AgoraPath.dirname(fs_path)):
		return await _run_cgi(req, fs_path, path, "")
	return await _file(req, fs_path, path)


## The file a URL path names: an Alias, or under DocumentRoot.
func _map(vh: Dictionary, path: String) -> String:
	# /~user/... is the user's public_html (mod_userdir).
	if path.begins_with("/~") and not str(_conf.userdir).is_empty():
		var name := path.substr(2).get_slice("/", 0)
		var u := p.machine.users.find(name)
		if not u.is_empty() and not (_conf.userdir_off as PackedStringArray).has(name):
			return AgoraPath.normalize(str(u.home) + "/" + str(_conf.userdir) + "/" + path.substr(2 + name.length()))
	for prefix: String in vh.alias:
		if path.begins_with(prefix):
			return AgoraPath.normalize(str(vh.alias[prefix]) + "/" + path.substr(prefix.length()))
	return AgoraPath.normalize(str(vh.doc_root) + "/" + path)


## The virtual host a request is for: by its Host header, else the first.
func _vhost(req: Dictionary) -> Dictionary:
	var hosts: Array = _conf.vhosts
	if hosts.is_empty():
		return _conf
	var name := str(req.headers.get("host", "")).get_slice(":", 0).to_lower()
	for vh: Dictionary in hosts:
		if (vh.names as PackedStringArray).has(name):
			return vh
	return hosts[0]


static func _url_decode(text: String) -> String:
	if not text.contains("%"):
		return text
	var out := PackedByteArray()
	var k := 0
	var raw := text.to_utf8_buffer()
	while k < raw.size():
		if raw[k] == 0x25 and k + 2 < raw.size() and text.substr(k + 1, 2).is_valid_hex_number():
			out.append(("0x" + raw.slice(k + 1, k + 3).get_string_from_ascii()).hex_to_int())
			k += 3
		else:
			out.append(raw[k])
			k += 1
	return out.get_string_from_utf8()


func _file(req: Dictionary, fs_path: String, url: String) -> Dictionary:
	var vfs := p.machine.vfs
	var bytes := vfs.read_file(_www, fs_path)
	if vfs.errno == AgoraErrno.EACCES:
		_error(req.client, "(13)Permission denied: file permissions deny server access: %s" % fs_path)
		return await _error_page(req, 403, url)
	var st := vfs.stat(_www, fs_path)
	var type := _content_type(fs_path)
	return {
		"status": 200, "body": AgoraWire.raw(bytes), "size": bytes.size(),
		"headers": [
			["Last-Modified", http_date(st.mtime)],
			["ETag", "\"%x-%x-%x\"" % [abs(fs_path.hash()) & 0xFFFFF, bytes.size(), int(st.mtime) & 0xFFFFFFFF]],
			["Accept-Ranges", "bytes"], ["Content-Length", str(bytes.size())], ["Content-Type", type],
		],
	}


func _content_type(path: String) -> String:
	var ext := AgoraPath.basename(path).get_extension().to_lower()
	var type := "text/plain"
	if not ext.is_empty():
		for line in p.read_text("/etc/mime.types").split("\n", false):
			if line.begins_with("#"):
				continue
			var words := line.replace("\t", " ").split(" ", false)
			if words.size() > 1 and words.slice(1).has(ext):
				type = words[0]
				break
	# Debian's AddDefaultCharset UTF-8 is for text.
	return type + "; charset=UTF-8" if type.begins_with("text/") else type


func _signature(req: Dictionary, port: int) -> String:
	if str(_conf.signature).to_lower() == "off":
		return ""
	var vh: Dictionary = req.get("vh", _conf)
	return "<address>%s Server at %s Port %d</address>\n" % [_server(), vh.server_name, port]


## Apache's built-in error documents.
func _error_page(req: Dictionary, status: int, url: String, location: String = "") -> Dictionary:
	var reason: String = REASONS.get(status, "Error")
	var text := ""
	match status:
		301:
			text = "<p>The document has moved <a href=\"%s\">here</a>.</p>\n" % location
		400:
			text = "<p>Your browser sent a request that this server could not understand.<br />\n</p>\n"
		403:
			text = "<p>You don't have permission to access %s\non this server.</p>\n" % url
		404:
			text = "<p>The requested URL %s was not found on this server.</p>\n" % url
		500:
			text = "<p>The server encountered an internal error or\nmisconfiguration and was unable to complete\nyour request.</p>\n<p>Please contact the server administrator,\n %s and inform them of the time the error occurred,\nand anything you might have done that may have\ncaused the error.</p>\n<p>More information about this error may be available\nin the server error log.</p>\n" % "webmaster@localhost"
		501:
			text = "<p>%s to %s not supported.<br />\n</p>\n" % [req.get("method", ""), url if not url.is_empty() else req.get("target", "/")]
	var conn: AgoraTcp.Conn = req.conn
	var body := "<!DOCTYPE HTML PUBLIC \"-//IETF//DTD HTML 2.0//EN\">\n<html><head>\n<title>%d %s</title>\n</head><body>\n<h1>%s</h1>\n%s<hr>\n%s</body></html>\n" % [
		status, reason, reason if status != 404 else "Not Found", text, _signature(req, conn.local_port)]
	return {"status": status, "body": body, "size": body.to_utf8_buffer().size(),
		"headers": [["Content-Length", str(body.to_utf8_buffer().size())], ["Content-Type", "text/html; charset=iso-8859-1"]]}


func _listing(req: Dictionary, fs_path: String, url: String) -> Dictionary:
	var vfs := p.machine.vfs
	var names := vfs.list_dir(_www, fs_path)
	if names.is_empty() and vfs.errno == AgoraErrno.EACCES:
		return await _error_page(req, 403, url)
	names.sort()
	var html := "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 3.2 Final//EN\">\n<html>\n <head>\n  <title>Index of %s</title>\n </head>\n <body>\n<h1>Index of %s</h1>\n" % [url, url]
	html += "<pre><img src=\"/icons/blank.gif\" alt=\"Icon \"> <a href=\"?C=N;O=D\">Name</a>                    <a href=\"?C=M;O=A\">Last modified</a>      <a href=\"?C=S;O=A\">Size</a>  <a href=\"?C=D;O=A\">Description</a><hr>"
	if url != "/":
		html += "<img src=\"/icons/back.gif\" alt=\"[DIR]\"> <a href=\"%s\">Parent Directory</a>                             -   \n" % AgoraPath.dirname(url.trim_suffix("/")).trim_suffix("/") + "/"
	for n in names:
		if _ignored(n):
			continue
		var st := vfs.stat(_www, fs_path.trim_suffix("/") + "/" + n)
		if st == null:
			continue
		var shown := n + ("/" if st.is_dir() else "")
		var alt := "[DIR]" if st.is_dir() else ("[TXT]" if _content_type(n).begins_with("text/") else "[   ]")
		var icon := "folder.gif" if st.is_dir() else ("text.gif" if alt == "[TXT]" else "unknown.gif")
		var label := shown if shown.length() <= 23 else shown.left(20) + "..>"
		var d := p.machine.clock.local_datetime(st.mtime)
		var when := "%02d-%s-%d %02d:%02d" % [d.day, MONTHS[d.month - 1], d.year, d.hour, d.minute]
		html += "<img src=\"/icons/%s\" alt=\"%s\"> <a href=\"%s\">%s</a>%s %s  %s  \n" % [
			icon, alt, shown.uri_encode().replace("%2F", "/"), label, " ".repeat(maxi(1, 24 - label.length())), when,
			"  - " if st.is_dir() else _size(st.size)]
	html += "<hr></pre>\n%s</body></html>\n" % _signature(req, (req.conn as AgoraTcp.Conn).local_port)
	var size := html.to_utf8_buffer().size()
	return {"status": 200, "body": html, "size": size,
		"headers": [["Content-Length", str(size)], ["Content-Type", "text/html;charset=UTF-8"]]}


func _ignored(name: String) -> bool:
	for pattern in _conf.ignore:
		if name.match(pattern):
			return true
	return false


## apr_strfsize: four characters.
static func _size(n: int) -> String:
	if n < 973:
		return "%3d " % n
	var units := "KMGTPE"
	var v := float(n)
	var u := -1
	while v >= 973.0 and u < units.length() - 1:
		v /= 1024.0
		u += 1
	if v < 9.95:
		return "%.1f%s" % [v, units[u]]
	return "%3d%s" % [int(v + 0.5), units[u]]


func _finish(req: Dictionary, r: Dictionary) -> void:
	var conn: AgoraTcp.Conn = req.conn
	var status: int = r.status
	var out := ""
	if req.get("protocol", "HTTP/1.0") != "HTTP/0.9":
		out = "HTTP/1.1 %d %s\r\n" % [status, REASONS.get(status, "Error")]
		var headers: Array = [["Date", http_date(p.machine.clock.now())], ["Server", _server()]]
		headers.append_array(r.headers)
		headers.insert(headers.size() - 1, ["Connection", "close"])
		for h: Array in headers:
			out += "%s: %s\r\n" % h
		out += "\r\n"
	var sent := 0
	if req.get("method", "") != "HEAD":
		out += r.body
		sent = r.size
	conn.output.write(out)
	conn.close()
	var line: String = req.get("line", "")
	_append(str(req.get("vh", _conf).custom_log), "%s - - %s \"%s\" %d %s \"%s\" \"%s\"\n" % [
		req.client, _log_time(), line, status, str(sent) if sent > 0 else "-",
		req.headers.get("referer", "-"), req.headers.get("user-agent", "-")])


# --- CGI -----------------------------------------------------------------------

func _cgi(req: Dictionary, prefix: String, path: String) -> Dictionary:
	var vh: Dictionary = req.vh
	var dir := str(vh.script_alias[prefix]).trim_suffix("/")
	var rest := path.substr(prefix.length()) if path.length() > prefix.length() else ""
	var script_name := rest.get_slice("/", 0)
	var path_info := rest.substr(script_name.length())
	var file := dir + "/" + script_name
	var vfs := p.machine.vfs
	var st := vfs.stat(_www, file) if not script_name.is_empty() else null
	if st == null or st.is_dir():
		if script_name.is_empty() or st != null:
			_error(req.client, "attempt to invoke directory as script: %s" % dir)
			return await _error_page(req, 403, path)
		_error(req.client, "script not found or unable to stat: %s" % file)
		return await _error_page(req, 404, path)
	return await _run_cgi(req, file, prefix.trim_suffix("/") + "/" + script_name, path_info)


## Runs the CGI program [param file] for [param req].
func _run_cgi(req: Dictionary, file: String, script_url: String, path_info: String) -> Dictionary:
	var vh: Dictionary = req.vh
	var path: String = req.target.get_slice("?", 0)
	var script_name := AgoraPath.basename(file)
	var dir := AgoraPath.dirname(file)
	var conn: AgoraTcp.Conn = req.conn
	var env := {
		"GATEWAY_INTERFACE": "CGI/1.1", "SERVER_SOFTWARE": _server(), "SERVER_NAME": vh.server_name,
		"SERVER_ADDR": AgoraInet.to_str(conn.local_addr), "SERVER_PORT": str(conn.local_port),
		"REMOTE_ADDR": req.client, "REMOTE_PORT": str(conn.remote_port), "SERVER_PROTOCOL": req.protocol,
		"REQUEST_METHOD": req.method, "QUERY_STRING": req.query, "REQUEST_URI": req.target,
		"SCRIPT_NAME": script_url, "SCRIPT_FILENAME": file,
		"DOCUMENT_ROOT": vh.doc_root, "SERVER_ADMIN": "webmaster@localhost",
		"PATH": "/usr/local/bin:/usr/bin:/bin",
	}
	if not path_info.is_empty():
		env.PATH_INFO = path_info
	for h: String in req.headers:
		env["HTTP_" + h.to_upper().replace("-", "_")] = req.headers[h]
	if req.method == "POST":
		env.CONTENT_LENGTH = str(AgoraWire.encode(req.body).size())
		env.CONTENT_TYPE = req.headers.get("content-type", "")
	var stdin := AgoraStream.new()
	stdin.add_writer()
	stdin.write(req.body)
	stdin.release_writer()
	var stdout := AgoraStream.new()
	stdout.add_reader()
	var stderr := AgoraStream.new()
	stderr.add_reader()
	var child := p.machine.spawn(PackedStringArray([file]), {
		"cred": _www, "cwd": dir, "env": env, "stdin": stdin, "stdout": stdout, "stderr": stderr, "parent": p,
	})
	if child == null:
		_error(req.client, "(%d)%s: exec of '%s' failed" % [p.machine.errno, AgoraErrno.describe(p.machine.errno), file])
		_error(req.client, "Premature end of script headers: %s" % script_name)
		return await _error_page(req, 500, path)
	var deadline := Time.get_ticks_msec() + int(CGI_TIMEOUT * 1000)
	while child.is_running() and Time.get_ticks_msec() < deadline:
		await p.sleep(0.02)
	if child.is_running():
		child.send_signal(AgoraProcess.SIGKILL)
		_error(req.client, "Script timed out before returning headers: %s" % script_name)
		return await _error_page(req, 500, path)
	for line in stderr.read_available().split("\n", false):
		_error(req.client, line)
	return await _cgi_response(req, stdout.read_available(), script_name, path)


## Splits a CGI program's output into headers and body.
func _cgi_response(req: Dictionary, output: String, script_name: String, path: String) -> Dictionary:
	# The headers end at the first empty line, CR LF or bare LF.
	var lf := output.find("\n\n")
	var crlf := output.find("\r\n\r\n")
	if lf < 0 and crlf < 0:
		_error(req.client, "Premature end of script headers: %s" % script_name)
		return await _error_page(req, 500, path)
	var use_crlf := crlf >= 0 and (lf < 0 or crlf < lf)
	var end := crlf if use_crlf else lf
	var text := output.substr(0, end).replace("\r\n", "\n")
	var status := 200
	var headers: Array = []
	var type := ""
	for line in text.split("\n"):
		if not line.contains(":"):
			_error(req.client, "malformed header from script. Bad header=%s: %s" % [line, script_name])
			return await _error_page(req, 500, path)
		var name := line.get_slice(":", 0).strip_edges()
		var value := line.substr(line.find(":") + 1).strip_edges()
		match name.to_lower():
			"status":
				status = value.to_int()
			"content-type":
				type = value
			"location":
				headers.append(["Location", value])
				if status == 200:
					status = 302
			_:
				headers.append([name, value])
	var body := output.substr(end + (4 if use_crlf else 2))
	var size := AgoraWire.encode(body).size()
	headers.append(["Content-Length", str(size)])
	headers.append(["Content-Type", type if not type.is_empty() else "text/plain; charset=UTF-8"])
	return {"status": status, "body": body, "size": size, "headers": headers}
