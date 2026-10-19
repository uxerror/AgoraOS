class_name AgoraMimeMail
extends RefCounted
## MIME mail (RFC 2045-2047): reading messages with parts, attachments and
## encoded text, and putting them together the way mail programs of 2003
## did. Used by Pigeon Mail; mail and popa3d see messages as plain text.
##
## A parsed part is {type ("text/plain"), params ({charset, name,
## boundary...}), encoding, filename, disposition, text (decoded, for text
## parts), data (PackedByteArray, decoded), parts (for multipart)}.

const B64_LINE := 76


## [param headers] and [param body] of a message (as [AgoraMbox] gives
## them) taken apart.
static func parse(headers: Array, body: String) -> Dictionary:
	var ctype := AgoraMbox.field(headers, "content-type")
	if ctype.is_empty():
		ctype = "text/plain; charset=us-ascii"
	var part := {"type": "", "params": {}, "encoding": AgoraMbox.field(headers, "content-transfer-encoding").to_lower(),
		"filename": "", "disposition": "", "text": "", "data": PackedByteArray(), "parts": []}
	var ct := header_params(ctype)
	part.type = str(ct.value).to_lower()
	part.params = ct.params
	var cd := header_params(AgoraMbox.field(headers, "content-disposition"))
	part.disposition = str(cd.value).to_lower()
	part.filename = decode_words(str(cd.params.get("filename", ct.params.get("name", ""))))
	if part.type.begins_with("multipart/") and ct.params.has("boundary"):
		for chunk in split_multipart(body, str(ct.params.boundary)):
			var m := AgoraMbox.parse_message(chunk)
			(part.parts as Array).append(parse(m.headers, str(m.body)))
		return part
	var data := decode_body(body, part.encoding)
	part.data = data
	if part.type.begins_with("text/"):
		part.text = bytes_to_text(data, str(ct.params.get("charset", "us-ascii")))
	return part


## "text/plain; charset=\"iso-8859-1\"" -> {value: "text/plain", params:
## {charset: "iso-8859-1"}}; parameter names in lower case.
static func header_params(text: String) -> Dictionary:
	var pieces: PackedStringArray = []
	var cur := ""
	var quoted := false
	for ch in text:
		if ch == "\"":
			quoted = not quoted
			cur += ch
		elif ch == ";" and not quoted:
			pieces.append(cur)
			cur = ""
		else:
			cur += ch
	pieces.append(cur)
	var params := {}
	for k in range(1, pieces.size()):
		var piece := pieces[k].strip_edges()
		var eq := piece.find("=")
		if eq > 0:
			params[piece.substr(0, eq).strip_edges().to_lower()] = piece.substr(eq + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
	return {"value": pieces[0].strip_edges(), "params": params}


## The parts of a multipart body, each as text (headers, blank line, body).
static func split_multipart(body: String, boundary: String) -> PackedStringArray:
	var out: PackedStringArray = []
	var cur: PackedStringArray = []
	var inside := false
	for line in body.replace("\r\n", "\n").split("\n"):
		if line.strip_edges(false, true) == "--" + boundary + "--":
			if inside:
				out.append("\n".join(cur))
			return out
		if line.strip_edges(false, true) == "--" + boundary:
			if inside:
				out.append("\n".join(cur))
			cur = PackedStringArray()
			inside = true
			continue
		if inside:
			cur.append(line)
	if inside:
		out.append("\n".join(cur))
	return out


static func decode_body(body: String, encoding: String) -> PackedByteArray:
	match encoding:
		"base64":
			var clean := ""
			for line in body.split("\n"):
				clean += line.strip_edges()
			return Marshalls.base64_to_raw(clean) if not clean.is_empty() else PackedByteArray()
		"quoted-printable":
			return qp_decode(body)
	return body.to_utf8_buffer()


## Quoted-printable to bytes: =XX, and "=" at the end of a line joins it to
## the next.
static func qp_decode(text: String) -> PackedByteArray:
	var out := PackedByteArray()
	var lines := text.replace("\r\n", "\n").split("\n")
	for k in lines.size():
		var line := lines[k].strip_edges(false, true)
		var soft := line.ends_with("=")
		if soft:
			line = line.substr(0, line.length() - 1)
		var i := 0
		var bytes := line.to_utf8_buffer()
		while i < bytes.size():
			if bytes[i] == 0x3D and i + 2 < bytes.size():
				var hex := char(bytes[i + 1]) + char(bytes[i + 2])
				if hex.is_valid_hex_number():
					out.append(hex.hex_to_int())
					i += 3
					continue
			out.append(bytes[i])
			i += 1
		if not soft and k < lines.size() - 1:
			out.append(0x0A)
	return out


## Bytes to quoted-printable, lines of at most 76 characters.
static func qp_encode(data: PackedByteArray) -> String:
	var out := ""
	var line := ""
	for k in data.size():
		var b := data[k]
		if b == 0x0A:
			out += line + "\n"
			line = ""
			continue
		var piece := char(b) if (b >= 33 and b <= 126 and b != 0x3D) or (b == 0x20 and k + 1 < data.size() and data[k + 1] != 0x0A) else "=%02X" % b
		if line.length() + piece.length() > 75:
			out += line + "=\n"
			line = ""
		line += piece
	return out + line


static func base64_lines(data: PackedByteArray) -> String:
	var text := Marshalls.raw_to_base64(data)
	var out := ""
	for k in range(0, text.length(), B64_LINE):
		out += text.substr(k, B64_LINE) + "\n"
	return out


## Decoded bytes as text in [param charset].
static func bytes_to_text(data: PackedByteArray, charset: String) -> String:
	match charset.to_lower():
		"utf-8", "utf8":
			return data.get_string_from_utf8()
		"iso-8859-1", "latin1", "windows-1252", "iso-8859-15":
			var s := ""
			for b in data:
				s += char(b)
			return s
	return data.get_string_from_utf8() # us-ascii is a part of it


## RFC 2047 encoded words in a header ("=?iso-8859-1?Q?caf=E9?=") as text.
static func decode_words(text: String) -> String:
	var re := RegEx.create_from_string("=\\?([^?]+)\\?([QqBb])\\?([^?]*)\\?=")
	var out := ""
	var last := 0
	for m in re.search_all(text):
		var gap := text.substr(last, m.get_start() - last)
		if not (last > 0 and gap.strip_edges().is_empty()):
			out += gap
		var data: PackedByteArray
		if m.get_string(2).to_upper() == "B":
			data = Marshalls.base64_to_raw(m.get_string(3))
		else:
			data = qp_decode(m.get_string(3).replace("_", " "))
		out += bytes_to_text(data, m.get_string(1))
		last = m.get_end()
	return out + text.substr(last)


# --- what a reader wants -------------------------------------------------------

## The text to show: the first text/plain part, else text/html (with
## "html": true), else nothing. {text, html}
static func body_of(part: Dictionary) -> Dictionary:
	if not str(part.type).begins_with("multipart/"):
		if str(part.type) in ["text/plain", "text/html"] and part.disposition != "attachment":
			return {"text": part.text, "html": part.type == "text/html"}
		return {}
	var html := {}
	for sub: Dictionary in part.parts:
		var found := body_of(sub)
		if found.is_empty():
			continue
		if not found.html:
			return found
		if html.is_empty():
			html = found
	return html


## The attachments: parts with a file name, or not text: [{filename, type,
## data}].
static func attachments(part: Dictionary) -> Array:
	var out: Array = []
	if str(part.type).begins_with("multipart/"):
		for sub: Dictionary in part.parts:
			out.append_array(attachments(sub))
		return out
	if not str(part.filename).is_empty() or part.disposition == "attachment" or not str(part.type).begins_with("text/"):
		out.append({"filename": part.filename if not str(part.filename).is_empty() else "attachment", "type": part.type, "data": part.data})
	return out


# --- putting a message together ------------------------------------------------

## The MIME headers and body for [param text] with [param files]
## ([{name, data, type}]): plain text alone, or multipart/mixed with the
## files in base64. Returns {headers: "...\n" lines, body}.
static func build(text: String, files: Array, boundary: String = "") -> Dictionary:
	var plain := _text_part(text)
	if files.is_empty():
		return {"headers": "MIME-Version: 1.0\n" + plain.headers, "body": plain.body}
	if boundary.is_empty():
		boundary = "----=_NextPart_000_%04X_01C3959A.%08X" % [randi() % 0x10000, randi()]
	var body := "This is a multi-part message in MIME format.\n\n"
	body += "--%s\n%s\n%s" % [boundary, plain.headers, plain.body]
	if not body.ends_with("\n"):
		body += "\n"
	for f: Dictionary in files:
		var name := str(f.name)
		var type: String = f.get("type", "application/octet-stream")
		body += "\n--%s\nContent-Type: %s;\n\tname=\"%s\"\nContent-Transfer-Encoding: base64\nContent-Disposition: attachment;\n\tfilename=\"%s\"\n\n" % [boundary, type, name, name]
		body += base64_lines(f.data)
	body += "\n--%s--\n" % boundary
	return {"headers": "MIME-Version: 1.0\nContent-Type: multipart/mixed;\n\tboundary=\"%s\"\n" % boundary, "body": body}


static func _text_part(text: String) -> Dictionary:
	var ascii := true
	for ch in text:
		if ch.unicode_at(0) > 126:
			ascii = false
			break
	var long_lines := false
	for line in text.split("\n"):
		if line.length() > 76:
			long_lines = true
	if ascii and not long_lines:
		return {"headers": "Content-Type: text/plain;\n\tcharset=\"us-ascii\"\nContent-Transfer-Encoding: 7bit\n", "body": text}
	var charset := "us-ascii" if ascii else "utf-8"
	return {"headers": "Content-Type: text/plain;\n\tcharset=\"%s\"\nContent-Transfer-Encoding: quoted-printable\n" % charset, "body": qp_encode(text.to_utf8_buffer())}
