class_name AgoraHttp
extends RefCounted
## A small HTTP/1.0 client for programs (lynx, crawlers): URLs, requests
## over the TCP stack, responses, redirects, form encoding.


## {scheme, host, port, path, query, url} for an absolute URL; a bare
## "host/path" counts as http. Fragments are dropped. {} if it can't be
## read.
static func parse_url(url: String) -> Dictionary:
	url = url.strip_edges().get_slice("#", 0)
	if url.is_empty():
		return {}
	var scheme := "http"
	var rest := url
	if url.contains("://"):
		scheme = url.get_slice("://", 0).to_lower()
		rest = url.substr(url.find("://") + 3)
	elif url.begins_with("/"):
		scheme = "file"
	if scheme == "file":
		var path := rest if rest.begins_with("/") else "/" + rest.substr(rest.find("/") + 1)
		return {"scheme": "file", "host": "", "port": 0, "path": path, "query": "", "url": "file://localhost" + path}
	var host_port := rest.get_slice("/", 0).get_slice("?", 0)
	var path := rest.substr(host_port.length())
	if path.begins_with("?"):
		path = "/" + path
	if path.is_empty():
		path = "/"
	var host := host_port.get_slice(":", 0).to_lower()
	var default_port := 21 if scheme == "ftp" else 80
	var port := host_port.get_slice(":", 1).to_int() if host_port.contains(":") else default_port
	if host.is_empty():
		return {}
	return {"scheme": scheme, "host": host, "port": port, "path": path.get_slice("?", 0),
		"query": path.substr(path.find("?") + 1) if path.contains("?") else "",
		"url": "%s://%s%s%s" % [scheme, host, ":%d" % port if port != default_port else "", path]}


## [param href] read relative to the page at [param base] (an absolute URL).
static func resolve(base: String, href: String) -> String:
	href = href.strip_edges()
	if href.is_empty():
		return base.get_slice("#", 0)
	if href.contains("://") or href.begins_with("mailto:"):
		return href
	var b := parse_url(base)
	if b.is_empty():
		return href
	var origin := "file://localhost" if b.scheme == "file" else "%s://%s%s" % [b.scheme, b.host, ":%d" % b.port if b.port != 80 else ""]
	if href.begins_with("//"):
		return "%s:%s" % [b.scheme, href]
	if href.begins_with("#"):
		return b.url
	if href.begins_with("?"):
		return origin + b.path + href
	var path := href if href.begins_with("/") else AgoraPath.dirname(b.path if not b.path.ends_with("/") else b.path + "x") + "/" + href
	var query := ""
	if path.contains("?"):
		query = "?" + path.substr(path.find("?") + 1)
		path = path.get_slice("?", 0)
	var trailing := path.ends_with("/") or path.ends_with("/.") or path.ends_with("/..")
	path = AgoraPath.normalize(path)
	if trailing and not path.ends_with("/"):
		path += "/"
	return origin + path.get_slice("#", 0) + query.get_slice("#", 0)


## application/x-www-form-urlencoded, as browsers send forms.
static func form_encode(fields: Array) -> String:
	var parts: PackedStringArray = []
	for f: Array in fields:
		parts.append("%s=%s" % [_escape(str(f[0])), _escape(str(f[1]))])
	return "&".join(parts)


static func _escape(text: String) -> String:
	var out := ""
	for b in text.to_utf8_buffer():
		var c := char(b)
		if (b >= 0x30 and b <= 0x39) or (b >= 0x41 and b <= 0x5A) or (b >= 0x61 and b <= 0x7A) or c in ["-", "_", ".", "*"]:
			out += c
		elif b == 0x20:
			out += "+"
		else:
			out += "%%%02X" % b
	return out


## Decodes a form value: "+" is a space, %XX a byte.
static func form_decode(text: String) -> String:
	var raw := text.replace("+", " ").to_utf8_buffer()
	var out := PackedByteArray()
	var k := 0
	while k < raw.size():
		if raw[k] == 0x25 and k + 2 < raw.size():
			var hex := raw.slice(k + 1, k + 3).get_string_from_ascii()
			if hex.is_valid_hex_number():
				out.append(("0x" + hex).hex_to_int())
				k += 3
				continue
		out.append(raw[k])
		k += 1
	return out.get_string_from_utf8()


## {name: value} of a query string or form body.
static func form_fields(text: String) -> Dictionary:
	var out := {}
	for pair in text.split("&", false):
		out[form_decode(pair.get_slice("=", 0))] = form_decode(pair.substr(pair.find("=") + 1) if pair.contains("=") else "")
	return out


## Fetches [param url]. [param opts]: method ("GET"), body (for POST),
## agent, timeout (seconds), redirects (how many to follow, default 5),
## status (Callable(text) told of each step, as lynx's status line).
## Returns {url (the final one), code, reason, headers, body} or {error,
## stage ("resolve", "connect", "response", "scheme")}.
static func fetch(p: AgoraProcess, url: String, opts: Dictionary = {}) -> Dictionary:
	var status: Callable = opts.get("status", Callable())
	var method: String = opts.get("method", "GET")
	var body: String = opts.get("body", "")
	var redirects: int = opts.get("redirects", 5)
	for hop in redirects + 1:
		var u := parse_url(url)
		if u.is_empty():
			return {"error": "Bad URL", "stage": "scheme"}
		if u.scheme == "file":
			var bytes := p.read_bytes(u.path)
			if p.errno != AgoraErrno.OK:
				return {"error": AgoraErrno.describe(p.errno), "stage": "connect"}
			return {"url": u.url, "code": 200, "reason": "OK", "headers": {"content-type": "text/html" if u.path.ends_with(".html") or u.path.ends_with(".htm") else "text/plain"}, "body": AgoraWire.raw(bytes)}
		if u.scheme != "http":
			return {"error": "Unsupported URL scheme!", "stage": "scheme"}
		var addr := AgoraInet.parse(u.host)
		if addr < 0:
			if status.is_valid():
				status.call("Looking up %s." % u.host)
			var found: Dictionary = await AgoraResolver.resolve(p, u.host)
			addr = found.get("addr", -1)
			if addr < 0:
				return {"error": AgoraResolver.message(found.error), "stage": "resolve"}
		if status.is_valid():
			status.call("Making HTTP connection to %s." % u.host)
		var r: Dictionary = await p.machine.net.tcp.open_connection(p, addr, u.port)
		if r.has("error"):
			return {"error": AgoraErrno.describe(r.error), "stage": "connect", "code_errno": r.error}
		var conn: AgoraTcp.Conn = r.conn
		conn.pid = p.pid
		var path: String = u.path + ("?" + u.query if not u.query.is_empty() else "")
		var request := "%s %s HTTP/1.0\r\nHost: %s\r\nAccept: text/html, text/plain, */*\r\nUser-Agent: %s\r\n" % [
			method, path, u.host if u.port == 80 else "%s:%d" % [u.host, u.port], opts.get("agent", "AgoraOS")]
		if method == "POST":
			request += "Content-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\n" % AgoraWire.encode(body).size()
		conn.output.write(request + "\r\n" + (body if method == "POST" else ""))
		if status.is_valid():
			status.call("HTTP request sent; waiting for response.")
		var deadline := Time.get_ticks_msec() + int(float(opts.get("timeout", 60.0)) * 1000)
		var text := await conn.input.read_all(func() -> bool: return p.is_dead() or Time.get_ticks_msec() > deadline)
		conn.close()
		var split := text.find("\r\n\r\n")
		if not text.begins_with("HTTP/") or split < 0:
			if text.is_empty():
				return {"error": "Unexpected network read error; connection aborted.", "stage": "response"}
			return {"url": u.url, "code": 200, "reason": "OK", "headers": {}, "body": text} # HTTP/0.9
		var head := text.substr(0, split).split("\r\n")
		var headers := {}
		for h in head.slice(1):
			headers[h.get_slice(":", 0).strip_edges().to_lower()] = h.substr(h.find(":") + 1).strip_edges()
		var code := head[0].get_slice(" ", 1).to_int()
		var reason := head[0].substr(head[0].find(" ", head[0].find(" ") + 1) + 1)
		if code in [301, 302, 303, 307] and headers.has("location") and hop < redirects:
			url = resolve(u.url, headers.location)
			if code == 303 or code == 302:
				method = "GET"
			continue
		return {"url": u.url, "code": code, "reason": reason, "headers": headers, "body": text.substr(split + 4), "status_line": head[0]}
	return {"error": "Too many redirections.", "stage": "response"}
