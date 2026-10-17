class_name AgoraSshChannel
extends RefCounted
## The session channel ssh and sshd speak after authentication, one
## message per line inside the TCP stream:
##
##   D <base64>   data (the terminal, or a command's stdout and stdin)
##   E <base64>   a command's stderr
##   C <json>     requests: {"echo": bool}, {"signal": n}, {"eof": true},
##                {"exit-status": n}
##
## Like SSH's channel messages, so terminal modes, Ctrl+C and exit status
## travel with the data and share its fate.


static func data(conn: AgoraTcp.Conn, text: String, stderr: bool = false) -> void:
	if not text.is_empty():
		conn.output.write("%s %s\n" % ["E" if stderr else "D", Marshalls.utf8_to_base64(text)])


static func request(conn: AgoraTcp.Conn, message: Dictionary) -> void:
	conn.output.write("C %s\n" % JSON.stringify(message))


## The next message as [kind, value] ("D"/"E" with text, "C" with a
## Dictionary), or [] when the connection ends.
static func receive(conn: AgoraTcp.Conn, abort: Callable) -> Array:
	while true:
		var line: Variant = await conn.input.read_line(abort)
		if line == null:
			return []
		var text := str(line)
		var kind := text.left(1)
		var body := text.substr(2)
		match kind:
			"D", "E":
				return [kind, Marshalls.base64_to_utf8(body)]
			"C":
				var parsed: Variant = JSON.parse_string(body)
				if parsed is Dictionary:
					return [kind, parsed]
	return []
