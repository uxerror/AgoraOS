class_name AgoraMbox
extends RefCounted
## Mailboxes in mbox format, as Exim writes /var/mail/USER: each message
## starts with a "From sender date" line after a blank line, header lines,
## a blank line, the body, and a blank line before the next one. Shared by
## mail, popa3d and Pigeon Mail.
##
## A message is {from_line, headers (Array of "Name: value\n" lines with
## their continuations), body, lines, size (bytes, as stored), status}.


## The messages of an mbox file.
static func parse(text: String) -> Array:
	var msgs: Array = []
	var cur: Array = []
	var prev_blank := true
	var lines := text.split("\n")
	if text.ends_with("\n"):
		lines.resize(lines.size() - 1)
	for line in lines:
		if line.begins_with("From ") and prev_blank:
			cur = [line]
			msgs.append(cur)
		elif not msgs.is_empty():
			cur.append(line)
		prev_blank = line.is_empty()
	var out: Array = []
	for m: Array in msgs:
		var size := 0
		for line: String in m:
			size += line.to_utf8_buffer().size() + 1
		var raw: Array = m.slice(1)
		var headers: Array = []
		var k := 0
		while k < raw.size() and not str(raw[k]).is_empty():
			var line: String = raw[k]
			if (line.begins_with(" ") or line.begins_with("\t")) and not headers.is_empty():
				headers[-1] = str(headers[-1]) + line + "\n"
			else:
				headers.append(line + "\n")
			k += 1
		var body_lines: Array = raw.slice(k + 1)
		if not body_lines.is_empty() and str(body_lines[-1]).is_empty():
			body_lines.resize(body_lines.size() - 1) # the blank line between messages
		var body := "\n".join(PackedStringArray(body_lines)) + ("\n" if not body_lines.is_empty() else "")
		out.append({"from_line": m[0], "headers": headers, "body": body, "lines": m.size(), "size": size,
			"status": field(headers, "status")})
	return out


## A message as text (RFC 822: headers, a blank line, the body), without
## the From line.
static func parse_message(text: String) -> Dictionary:
	text = text.replace("\r\n", "\n")
	var headers: Array = []
	var lines := text.split("\n")
	var k := 0
	while k < lines.size() and not lines[k].is_empty():
		var line := lines[k]
		if (line.begins_with(" ") or line.begins_with("\t")) and not headers.is_empty():
			headers[-1] = str(headers[-1]) + line + "\n"
		elif line.contains(":"):
			headers.append(line + "\n")
		k += 1
	var body := "\n".join(lines.slice(k + 1)) if k < lines.size() else ""
	return {"headers": headers, "body": body, "status": field(headers, "status")}


## The value of the first [param name] header (lower case), unfolded.
static func field(headers: Array, name: String) -> String:
	for h: String in headers:
		if h.get_slice(":", 0).to_lower() == name:
			return h.substr(h.find(":") + 1).replace("\n\t", " ").replace("\n ", " ").strip_edges()
	return ""


## "Bob <bob@x>" -> "bob@x", as mail's skin() does.
static func skin(text: String) -> String:
	if text.contains("<") and text.contains(">"):
		return text.substr(text.find("<") + 1, text.find(">") - text.find("<") - 1)
	if text.contains("("):
		text = text.substr(0, text.find("(")) + text.substr(text.find(")") + 1)
	return text.strip_edges()


## "Bob Smith <bob@x>" -> "Bob Smith"; a bare address stays as it is.
static func display_name(text: String) -> String:
	if text.contains("<"):
		var name := text.substr(0, text.find("<")).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if not name.is_empty():
			return name
	if text.contains("(") and text.contains(")"):
		return text.substr(text.find("(") + 1, text.find(")") - text.find("(") - 1)
	return skin(text)


## The message's header and body as text, without the From line.
static func message_text(m: Dictionary) -> String:
	return "".join(m.headers) + "\n" + str(m.body)


## Writes a message back in mbox form, with its Status line ("" keeps
## whatever it had).
static func to_text(m: Dictionary, status: String = "") -> String:
	var out := str(m.from_line) + "\n"
	var placed := status.is_empty()
	for h: String in m.headers:
		if h.get_slice(":", 0).to_lower() == "status" and not status.is_empty():
			if not placed:
				out += "Status: %s\n" % status
				placed = true
			continue
		out += h
	if not placed:
		out += "Status: %s\n" % status
	var body := str(m.body)
	return out + "\n" + body + ("" if body.is_empty() or body.ends_with("\n") else "\n") + "\n"


## A From line for a message from [param sender] at [param unix] (local
## time on [param clock]).
static func from_line(sender: String, clock: AgoraClock, unix: float = -1.0) -> String:
	return "From %s %s" % [sender if not sender.is_empty() else "MAILER-DAEMON", clock.format_long(unix)]
