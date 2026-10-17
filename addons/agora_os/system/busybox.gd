extends AgoraProgram
## Many small tools in one binary, as on routers and rescue disks. Every
## applet is a symlink to /bin/busybox; the name it was started under picks
## the applet. "busybox ls" works too.
##
## The binary is setuid root (for passwd and su), so every other applet
## drops the privilege right away.

const VERSION := "1.1.3"
const SUID_APPLETS: PackedStringArray = ["crontab", "passwd", "su"]


func summary() -> String:
	return "multi-call binary with tiny versions of common UNIX tools"


func main(p: AgoraProcess) -> int:
	var applet := AgoraPath.basename(p.argv[0]).trim_prefix("-")
	if applet == "busybox":
		if p.argv.size() < 2 or p.argv[1] in ["--help", "-h"]:
			p.outln("BusyBox v%s (AgoraOS) multi-call binary\n" % VERSION)
			p.outln("Usage: busybox [function] [arguments]...\n   or: function [arguments]...\n")
			p.outln("Currently defined functions:")
			p.outln("\t" + ", ".join(_applets()))
			return 0
		if p.argv[1] == "--list":
			for a in _applets():
				p.outln(a)
			return 0
		applet = p.argv[1]
		p.argv = p.argv.slice(1)
	if not AgoraDistro.BUSYBOX_APPLETS.has(applet):
		return p.fail("%s: applet not found" % applet, 127)
	if not SUID_APPLETS.has(applet) and p.cred.uid != p.cred.ruid:
		p.cred.uid = p.cred.ruid
	p.name = applet
	var impl := AgoraPrograms.lookup(AgoraDistro.BUSYBOX_APPLETS[applet])
	var program: AgoraProgram = impl.new()
	return await program.main(p)


static func _applets() -> PackedStringArray:
	var names := PackedStringArray(AgoraDistro.BUSYBOX_APPLETS.keys())
	names.sort()
	return names
