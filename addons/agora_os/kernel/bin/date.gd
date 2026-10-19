extends AgoraProgram

const DAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


func summary() -> String:
	return "print the date and time"


func usage() -> String:
	return """usage: date [-u] [-d STRING] [+FORMAT]
       date -s STRING          set the system clock (root)
       date MMDDhhmm[[CC]YY][.ss]
STRING: "2003-10-17 15:04[:05]", "10/17/2003 15:04", "15:04[:05]" or @SECONDS
format codes: %Y %m %d %e %H %I %M %S %p %a %b %s %F %T %%"""


func main(p: AgoraProcess) -> int:
	var clock := p.machine.clock
	var a := AgoraArgs.parse(p.argv, "sd", PackedStringArray(["set", "date"]))
	if not a.error.is_empty():
		return p.fail(a.error)
	var shown := clock.now()
	var utc := a.has("u") or a.has("utc")
	var to_set := ""
	if a.has("s") or a.has("set"):
		to_set = str(a.value("s", a.value("set")))
	var fmt := ""
	for op in a.operands:
		if op.begins_with("+"):
			fmt = op.substr(1)
		elif to_set.is_empty() and op.is_valid_int() and op.length() >= 8:
			to_set = _from_digits(op, clock)
		else:
			return p.fail("invalid date '%s'" % op)
	if a.has("d") or a.has("date"):
		shown = parse_date(str(a.value("d", a.value("date"))), clock)
		if shown < 0.0:
			return p.fail("invalid date '%s'" % a.value("d", a.value("date")))
	var status := 0
	if not to_set.is_empty():
		var t := parse_date(to_set, clock)
		if t < 0.0:
			return p.fail("invalid date '%s'" % to_set)
		if not p.cred.is_root():
			p.errln("date: cannot set date: Operation not permitted")
			status = 1
		else:
			clock.set_time(t)
		shown = clock.now() if status == 0 else t
	var view := clock
	if utc:
		view = AgoraClock.new()
		view.tz_offset_minutes = 0
	var text := format(view, fmt, shown) if not fmt.is_empty() else view.format_long(shown)
	if utc and fmt.is_empty():
		text = text.insert(19, " UTC")
	p.outln(text)
	return status


## "MMDDhhmm[[CC]YY][.ss]" as "YYYY-MM-DD hh:mm:ss".
func _from_digits(text: String, clock: AgoraClock) -> String:
	var secs := "00"
	var digits := text
	var d := clock.local_datetime()
	var year := str(d.year)
	if digits.length() == 12:
		year = digits.substr(8, 4)
	elif digits.length() == 10:
		year = "20" + digits.substr(8, 2) if int(digits.substr(8, 2)) < 70 else "19" + digits.substr(8, 2)
	return "%s-%s-%s %s:%s:%s" % [year, digits.substr(0, 2), digits.substr(2, 2), digits.substr(4, 2), digits.substr(6, 2), secs]


## A date as people type it, in local time, to Unix time; -1 if it isn't
## one. Without a date part it is today; without seconds :00.
static func parse_date(text: String, clock: AgoraClock) -> float:
	text = text.strip_edges()
	if text.begins_with("@"):
		return float(text.substr(1)) if text.substr(1).is_valid_float() else -1.0
	var d := clock.local_datetime()
	var date_part := ""
	var time_part := ""
	for word in text.split(" ", false):
		if word.contains("-") or word.contains("/"):
			date_part = word
		elif word.contains(":"):
			time_part = word
		else:
			return -1.0
	if not date_part.is_empty():
		var f := date_part.split("-" if date_part.contains("-") else "/")
		if f.size() != 3 or not (f[0].is_valid_int() and f[1].is_valid_int() and f[2].is_valid_int()):
			return -1.0
		var ymd := [int(f[0]), int(f[1]), int(f[2])] if date_part.contains("-") else [int(f[2]), int(f[0]), int(f[1])]
		if ymd[1] < 1 or ymd[1] > 12 or ymd[2] < 1 or ymd[2] > 31 or ymd[0] < 1970:
			return -1.0
		d.year = ymd[0]
		d.month = ymd[1]
		d.day = ymd[2]
		d.hour = 0
		d.minute = 0
		d.second = 0
	if not time_part.is_empty():
		var t := time_part.split(":")
		if t.size() < 2 or t.size() > 3:
			return -1.0
		for x in t:
			if not x.is_valid_int():
				return -1.0
		if int(t[0]) > 23 or int(t[1]) > 59 or (t.size() == 3 and int(t[2]) > 59):
			return -1.0
		d.hour = int(t[0])
		d.minute = int(t[1])
		d.second = int(t[2]) if t.size() == 3 else 0
	if date_part.is_empty() and time_part.is_empty():
		return -1.0
	return float(Time.get_unix_time_from_datetime_dict(d) - clock.tz_offset_minutes * 60)


static func format(clock: AgoraClock, fmt: String, unix: float = -1.0) -> String:
	var d := clock.local_datetime(unix)
	var hour12: int = d.hour % 12 if d.hour % 12 != 0 else 12
	var codes := {
		"Y": str(d.year), "m": "%02d" % d.month, "d": "%02d" % d.day, "e": "%2d" % d.day,
		"H": "%02d" % d.hour, "I": "%02d" % hour12, "M": "%02d" % d.minute, "S": "%02d" % d.second,
		"p": "AM" if d.hour < 12 else "PM", "a": DAYS[d.weekday], "b": MONTHS[d.month - 1],
		"s": str(int(unix) if unix >= 0.0 else clock.now_int()), "F": "%d-%02d-%02d" % [d.year, d.month, d.day],
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
