extends AgoraProgram

const DAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


func summary() -> String:
	return "print the date and time"


func usage() -> String:
	return "usage: date [+format]\nformat codes: %Y %m %d %e %H %I %M %S %p %a %b %s %F %T %%"


func main(p: AgoraProcess) -> int:
	var clock := p.machine.clock
	if p.argv.size() < 2:
		p.outln(clock.format_long())
		return 0
	if not p.argv[1].begins_with("+"):
		return p.fail("invalid date format '%s'" % p.argv[1])
	p.outln(format(clock, p.argv[1].substr(1)))
	return 0


static func format(clock: AgoraClock, fmt: String) -> String:
	var d := clock.local_datetime()
	var hour12: int = d.hour % 12 if d.hour % 12 != 0 else 12
	var codes := {
		"Y": str(d.year), "m": "%02d" % d.month, "d": "%02d" % d.day, "e": "%2d" % d.day,
		"H": "%02d" % d.hour, "I": "%02d" % hour12, "M": "%02d" % d.minute, "S": "%02d" % d.second,
		"p": "AM" if d.hour < 12 else "PM", "a": DAYS[d.weekday], "b": MONTHS[d.month - 1],
		"s": str(clock.now_int()), "F": "%d-%02d-%02d" % [d.year, d.month, d.day],
		"T": "%02d:%02d:%02d" % [d.hour, d.minute, d.second], "%": "%",
	}
	var out := ""
	var i := 0
	while i < fmt.length():
		if fmt[i] == "%" and i + 1 < fmt.length() and codes.has(fmt[i + 1]):
			out += codes[fmt[i + 1]]
			i += 2
			continue
		out += fmt[i]
		i += 1
	return out
