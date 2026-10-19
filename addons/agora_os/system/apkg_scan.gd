extends AgoraProgram
## apkg-scanpackages [-s SUITE] [-c COMPONENT] BASE: makes an archive of
## the .pkg files put under BASE/pool/COMPONENT/ (anywhere below it), as
## dpkg-scanpackages does: writes BASE/dists/SUITE/COMPONENT/Packages and
## BASE/dists/SUITE/Release. Serve BASE from a disk, a web server or an FTP
## server and name it in /etc/apkg/sources.list:
##   apkg http://www.example.org/repo stable main


func summary() -> String:
	return "make the index of a package archive"


func usage() -> String:
	return "usage: apkg-scanpackages [-s SUITE] [-c COMPONENT] [-o ORIGIN] BASE"


func main(p: AgoraProcess) -> int:
	var a := AgoraArgs.parse(p.argv, "sco")
	if a.operands.is_empty():
		return p.fail(usage(), 2)
	var base := p.abspath(a.operands[0]).trim_suffix("/")
	var suite := a.value("s", AgoraArchive.SUITE)
	var component := a.value("c", AgoraArchive.COMPONENT)
	if not p.is_dir("%s/pool/%s" % [base, component]):
		return p.fail("%s/pool/%s: %s" % [base, component, AgoraErrno.describe(AgoraErrno.ENOENT)], 2)
	var d := p.machine.clock.local_datetime()
	var date := "%s, %02d %s %d %02d:%02d:%02d UTC" % [["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.weekday], d.day,
		["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.month - 1], d.year, d.hour, d.minute, d.second]
	var n := AgoraArchive.scan(p.machine.vfs, base, suite, component, a.value("o", "AgoraOS"), date, p.cred)
	if n < 0:
		return p.fail("%s/dists/%s: %s" % [base, suite, AgoraErrno.describe(p.machine.vfs.errno)], 2)
	p.errln(" Wrote %d entries to output Packages file." % n)
	return 0
