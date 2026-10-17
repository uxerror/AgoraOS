class_name AgoraArgs
extends RefCounted
## Minimal getopt-style parser.
##
## Short flags can be grouped ("-la"). Flags listed in [code]with_value[/code]
## take a value, either attached ("-n5") or as the next argument ("-n 5").
## Long options are "--name" or "--name=value". "--" ends option parsing.
## Everything else is an operand.

var flags := {} # flag -> true or value string
var operands: PackedStringArray = []
var error := ""


static func parse(argv: PackedStringArray, with_value: String = "", long_with_value: PackedStringArray = []) -> AgoraArgs:
	var a := AgoraArgs.new()
	var i := 1
	var options_done := false
	while i < argv.size():
		var arg := argv[i]
		i += 1
		if options_done or arg == "-" or not arg.begins_with("-"):
			a.operands.append(arg)
			continue
		if arg == "--":
			options_done = true
			continue
		if arg.begins_with("--"):
			var body := arg.substr(2)
			var eq := body.find("=")
			if eq >= 0:
				a.flags[body.substr(0, eq)] = body.substr(eq + 1)
			elif long_with_value.has(body):
				if i >= argv.size():
					a.error = "option '--%s' requires an argument" % body
					return a
				a.flags[body] = argv[i]
				i += 1
			else:
				a.flags[body] = true
			continue
		var j := 1
		while j < arg.length():
			var c := arg[j]
			if with_value.contains(c):
				var value := arg.substr(j + 1)
				if value.is_empty():
					if i >= argv.size():
						a.error = "option requires an argument -- '%s'" % c
						return a
					value = argv[i]
					i += 1
				a.flags[c] = value
				break
			a.flags[c] = true
			j += 1
	return a


func has(flag: String) -> bool:
	return flags.has(flag)


func value(flag: String, default: String = "") -> String:
	var v: Variant = flags.get(flag, default)
	return v if v is String else default
