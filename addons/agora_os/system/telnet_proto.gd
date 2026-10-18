class_name AgoraTelnet
extends RefCounted
## The TELNET protocol (RFC 854) as both ends speak it: data with commands
## mixed in, each starting with IAC (byte 255), option negotiation (RFC
## 855: WILL, WONT, DO, DONT) and subnegotiation (SB ... IAC SE). Bytes
## travel as data characters (see [method AgoraWire.raw]).

const IAC := 255
const DONT := 254
const DO := 253
const WONT := 252
const WILL := 251
const SB := 250
const GA := 249
const EL := 248
const EC := 247
const AYT := 246
const AO := 245
const INTERRUPT := 244 # IP, Interrupt Process
const BRK := 243
const NOP := 241
const SE := 240

const ECHO := 1
const SGA := 3
const STATUS := 5
const TTYPE := 24
const NAWS := 31
const TSPEED := 32
const LFLOW := 33
const LINEMODE := 34
const XDISPLOC := 35
const NEW_ENVIRON := 39

## Subnegotiation codes for TTYPE and TSPEED.
const IS := 0
const SEND := 1

const OPTION_NAMES := {
	ECHO: "ECHO", SGA: "SUPPRESS GO AHEAD", STATUS: "STATUS", TTYPE: "TERMINAL TYPE",
	NAWS: "NAWS", TSPEED: "TERMINAL SPEED", LFLOW: "TOGGLE-FLOW-CONTROL",
	LINEMODE: "LINEMODE", XDISPLOC: "X DISPLAY LOCATION", NEW_ENVIRON: "NEW-ENVIRON",
}


## A three-byte negotiation: [param verb] (WILL, WONT, DO, DONT) and option.
static func command(verb: int, option: int) -> String:
	return AgoraWire.raw(PackedByteArray([IAC, verb, option]))


## A two-byte command such as INTERRUPT or AYT.
static func control(code: int) -> String:
	return AgoraWire.raw(PackedByteArray([IAC, code]))


## IAC SB option bytes... IAC SE, with IAC in the payload doubled.
static func subneg(option: int, payload: PackedByteArray) -> String:
	var out := PackedByteArray([IAC, SB, option])
	for b in payload:
		out.append(b)
		if b == IAC:
			out.append(IAC)
	out.append_array([IAC, SE])
	return AgoraWire.raw(out)


## Data to send: an IAC byte in it is doubled.
static func escape(text: String) -> String:
	return text.replace(AgoraWire.raw_byte(IAC), AgoraWire.raw_byte(IAC) + AgoraWire.raw_byte(IAC))


## Splits what arrives into data and commands. Feed it chunks as they come;
## a command cut between two chunks is completed by the next.
class Parser:
	## Commands seen: [verb, option] for negotiation, [SB, option, bytes]
	## for subnegotiation, [code] for the rest.
	var commands: Array = []
	var _state := 0
	var _verb := 0
	var _sb: PackedByteArray = []

	## Returns the data in [param text]; commands go to [member commands].
	func feed(text: String) -> String:
		var data := ""
		for k in text.length():
			var c := text.unicode_at(k)
			var b := AgoraWire.byte_of(c)
			match _state:
				0:
					if b == IAC:
						_state = 1
					else:
						data += text.substr(k, 1)
				1: # after IAC
					match b:
						IAC:
							data += AgoraWire.raw_byte(IAC)
							_state = 0
						WILL, WONT, DO, DONT:
							_verb = b
							_state = 2
						SB:
							_sb = PackedByteArray()
							_state = 3
						_:
							commands.append([b])
							_state = 0
				2: # option of WILL/WONT/DO/DONT
					commands.append([_verb, b])
					_state = 0
				3: # inside SB
					if b == IAC:
						_state = 4
					else:
						_sb.append(maxi(b, 0))
				4: # IAC inside SB
					if b == SE:
						var option := _sb[0] if not _sb.is_empty() else 0
						commands.append([SB, option, _sb.slice(1)])
						_state = 0
					else:
						_sb.append(maxi(b, 0))
						_state = 3
		return data

	## Takes the commands seen so far.
	func take() -> Array:
		var out := commands
		commands = []
		return out
