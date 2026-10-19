extends AgoraProgram
## hwclock: reads and sets the hardware clock (the CMOS clock of the box,
## see [member AgoraCmos.rtc_offset]). The kernel starts from it at boot;
## "date -s" changes the system clock only, until hwclock -w writes it
## back (Debian's hwclock.sh does that at shutdown).


func summary() -> String:
	return "query and set the hardware clock (RTC)"


func usage() -> String:
	return """usage: hwclock [function] [--utc|--localtime]
  -r, --show         read the hardware clock and print the time (default)
  -s, --hctosys      set the system time from the hardware clock
  -w, --systohc      set the hardware clock to the current system time
      --set --date=STRING   set the hardware clock to STRING"""


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "", PackedStringArray(["date"]))
	if a.has("h") or a.has("help"):
		p.outln(usage())
		return 0
	if not p.cred.is_root():
		return p.fail("hwclock: Sorry, only the superuser can use the Hardware Clock.", 1)
	var m := p.machine
	var hw := m.hardware
	if hw == null:
		return p.fail("hwclock: Cannot access the Hardware Clock via any known method.", 1)
	var rtc := hw.clock.now() + hw.cmos.rtc_offset
	if a.has("s") or a.has("hctosys"):
		m.clock.set_time(rtc)
		return 0
	if a.has("w") or a.has("systohc"):
		hw.cmos.rtc_offset = m.clock.now() - hw.clock.now()
		return 0
	if a.has("set"):
		if not a.has("date"):
			return p.fail("hwclock: No --date option specified.", 1)
		var t := preload("../kernel/bin/date.gd").parse_date(str(a.value("date")), m.clock)
		if t < 0.0:
			return p.fail("hwclock: invalid date '%s'" % a.value("date"), 1)
		hw.cmos.rtc_offset = t - hw.clock.now()
		return 0
	p.outln("%s  %.6f seconds" % [m.clock.format_long(rtc), -fmod(rtc, 1.0)])
	return 0
