class_name AgoraPing
extends RefCounted
## The Ping! network protocol (PingNet/1.0), shared by pingd and the
## clients. One command per line (CR LF), words separated by spaces; a last
## argument that starts with ":" runs to the end of the line, with "\n" and
## "\\" standing for a newline and a backslash.
##
##   S: HELLO PingNet/1.0 <server name>
##   C: REGISTER <password> :<nick>          S: REGISTERED <uin>
##   C: LOGIN <uin> <password> <status>      S: WELCOME <uin> <status> :<nick>
##        then CONTACT and OFFLINE lines, then READY
##   C: STATUS <status>                      S: STATUS <status>
##   C: ADD <uin>                            S: CONTACT <uin> <status> :<nick>
##   C: DEL <uin>                            S: REMOVED <uin>
##   C: MSG <uin> :<text>                    S: SENT <uin>  or  STORED <uin>
##   C: INFO <uin>                           S: INFO <uin> <status> :<nick>
##   C: SEARCH :<text>                       S: FOUND <uin> <status> :<nick> ... END
##   C: NICK :<nick>                         S: NICK <uin> :<nick>
##   C: NOP                                  S: NOP
##   C: BYE                                  S: BYE
##   S: MSG <from> <unix time> :<text>       a message
##   S: OFFLINE <from> <unix time> :<text>   one that waited on the server
##   S: PRESENCE <uin> <status>              a contact changed status
##   S: KICKED :<reason>                     the session is over
##   S: ERROR <code> [<uin>] :<text>         400 bad command, 401 wrong number
##        or password, 403 not logged in, 404 no such user, 409 already there,
##        410 not online, 413 too big
##
## Files go through the server, to someone online:
##   C: FILE <uin> <id> <size> :<name>       S: OFFERED <uin> <id>
##   S: FILE <from> <id> <size> :<name>      the offer, to the other one
##   C: ACCEPT <from> <id>  /  DECLINE <from> <id>
##   S: ACCEPTED <uin> <id>  /  DECLINED <uin> <id>   to the one offering
##   C: DATA <uin> <id> :<base64>  ...  DONE <uin> <id>
##   S: DATA <from> <id> :<base64>  ...  DONE <from> <id>
##
## Chat rooms, "#name", made by the first one in, gone with the last:
##   C: JOIN <#room>       S: JOINED <#room> <uin> :<nick> to everyone there,
##                         then MEMBER <#room> <uin> :<nick> for each, END
##   C: PART <#room>       S: PARTED <#room> <uin> to everyone there
##   C: SAY <#room> :<text>    S: SAID <#room> <uin> <unix time> :<text>
##   C: ROOMS              S: ROOM <#room> <people> ... END

const VERSION := "PingNet/1.0"
const PORT := 5190
## Every status, in the order clients offer them.
const STATUSES: PackedStringArray = ["online", "ffc", "away", "na", "occupied", "dnd", "invisible", "offline"]
const STATUS_NAMES := {
	"online": "Online", "ffc": "Free for chat", "away": "Away", "na": "N/A", "occupied": "Occupied",
	"dnd": "Do not disturb", "invisible": "Invisible", "offline": "Offline",
}
const MAX_NICK := 20
const MAX_TEXT := 4000
## The biggest file one may send, in bytes.
const MAX_FILE := 1048576
## Base64 characters in one DATA line.
const CHUNK := 3000


static func escape(text: String) -> String:
	return text.replace("\\", "\\\\").replace("\r", "").replace("\n", "\\n")


static func unescape(text: String) -> String:
	var out := ""
	var k := 0
	while k < text.length():
		var c := text[k]
		if c == "\\" and k + 1 < text.length():
			var e := text[k + 1]
			out += "\n" if e == "n" else e
			k += 2
		else:
			out += c
			k += 1
	return out


## A protocol line from words; the last one is a trailing ":" argument if
## [param trailing] is true.
static func line(words: Array, trailing: bool = false) -> String:
	var parts: PackedStringArray = []
	for k in words.size():
		var w := str(words[k])
		if trailing and k == words.size() - 1:
			parts.append(":" + escape(w))
		else:
			parts.append(w)
	return " ".join(parts) + "\r\n"


## {cmd, args (PackedStringArray, the trailing one unescaped)}.
static func parse(text: String) -> Dictionary:
	text = text.trim_suffix("\r")
	var args: PackedStringArray = []
	var rest := text
	while not rest.is_empty():
		if rest.begins_with(":"):
			args.append(unescape(rest.substr(1)))
			break
		var space := rest.find(" ")
		if space < 0:
			args.append(rest)
			break
		if space > 0:
			args.append(rest.substr(0, space))
		rest = rest.substr(space + 1)
	var cmd := args[0].to_upper() if not args.is_empty() else ""
	return {"cmd": cmd, "args": args.slice(1)}


## A room's name: "#" and letters, digits, - or _, at most 24 in all.
static func is_room(name: String) -> bool:
	if not name.begins_with("#") or name.length() < 2 or name.length() > 24:
		return false
	for ch in name.substr(1):
		if not (ch.is_valid_identifier() or ch == "-" or ch.is_valid_int()):
			return false
	return true


static func is_status(s: String) -> bool:
	return STATUSES.has(s)


## How [param status] looks to others: invisible people are offline.
static func seen_as(status: String) -> String:
	return "offline" if status == "invisible" else status
