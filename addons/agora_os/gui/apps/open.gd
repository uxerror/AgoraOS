extends AgoraGuiProgram
## Opens files with their default application, like xdg-open.
## Executables are run in a terminal window rather than silently.


func summary() -> String:
	return "open a file with its default application"


func usage() -> String:
	return "usage: open file...\nThe application is picked from /etc/mime.types, the MimeType= lines of\n/usr/share/applications/*.desktop and ~/.config/mimeapps.list."


func main(p: AgoraProcess) -> int:
	if p.argv.size() < 2:
		return p.fail(usage(), 2)
	var status := 0
	for target in p.argv.slice(1):
		if not p.exists(target):
			status = p.fail_path(target)
			continue
		var path := p.abspath(target)
		var mime := AgoraMime.type_of(p, path)
		var argv: PackedStringArray
		if mime == AgoraMime.EXECUTABLE:
			argv = PackedStringArray(["terminal", "-e", path])
		else:
			var app := AgoraMime.app_for(p, mime)
			if app.is_empty():
				status = p.fail("%s: no application for %s" % [target, mime])
				continue
			argv = AgoraMime.command_for(app, path)
		# Detached: the app keeps running after open exits.
		if p.spawn(argv, {"stdin": AgoraStream.empty()}) == null:
			status = p.fail("%s: %s" % [argv[0], AgoraErrno.describe(p.errno)])
	return status
