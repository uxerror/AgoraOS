extends AgoraProgram
## The Ferret search engine's CGI programs, installed as
## /usr/lib/cgi-bin/search and /usr/lib/cgi-bin/addurl.
##
## search?q=WORDS&start=N finds the pages in /var/lib/ferret/index that
## have every word, best first (words in the title count more), ten to a
## page. addurl?url=URL queues a site for the crawler's next run.

const INDEX := "/var/lib/ferret/index"
const SUBMITTED := "/var/lib/ferret/submitted"
const PER_PAGE := 10

const HEAD := """<html>
<head><title>%s</title></head>
<body bgcolor="#ffffff" text="#000000" link="#0000cc" vlink="#551a8b">
<center>
<a href="/"><img src="/ferret.gif" alt="Ferret" width="220" height="60" border="0"></a>
<form action="/cgi-bin/search" method="get">
<input type="text" name="q" size="40" value="%s"> <input type="submit" value="Fetch!">
</form>
</center>
<hr noshade size="1">
"""
const FOOT := """<hr noshade size="1">
<center><font size="-1"><a href="/">Ferret Home</a> - <a href="/addurl.html">Add URL</a> - <a href="/about.html">About Ferret</a><br>
&copy;2003 Ferret Search. All rights reserved.</font></center>
</body></html>
"""


func summary() -> String:
	return "Ferret search CGI"


func main(p: AgoraProcess) -> int:
	var fields := AgoraHttp.form_fields(str(p.env.get("QUERY_STRING", "")))
	if p.env.get("REQUEST_METHOD", "GET") == "POST":
		fields.merge(AgoraHttp.form_fields(await p.read_all()), true)
	if AgoraPath.basename(p.argv[0]) == "addurl":
		return _add(p, str(fields.get("url", "")).strip_edges())
	return _search(p, str(fields.get("q", "")).strip_edges(), str(fields.get("start", "0")).to_int())


static func _html(text: String) -> String:
	return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")


func _search(p: AgoraProcess, query: String, start: int) -> int:
	p.out("Content-Type: text/html\n\n")
	var title := "Ferret Search: " + query if not query.is_empty() else "Ferret Search"
	p.out(HEAD % [_html(title), _html(query)])
	var terms: PackedStringArray = []
	for t in query.to_lower().split(" ", false):
		terms.append(t)
	if terms.is_empty():
		p.out("<p>Type some words and press <b>Fetch!</b>.</p>\n" + FOOT)
		return 0
	var hits: Array = []
	for line in p.read_text(INDEX).split("\n", false):
		var parts := line.split("\t")
		if parts.size() < 3:
			continue
		var t := parts[1].to_lower()
		var body := parts[2].to_lower()
		var score := 0
		var all := true
		for term in terms:
			var in_title := t.count(term)
			var in_body := body.count(term)
			if in_title + in_body == 0 and not parts[0].to_lower().contains(term):
				all = false
				break
			score += in_title * 10 + in_body + (5 if parts[0].to_lower().contains(term) else 0)
		if all:
			hits.append([score, parts[0], parts[1], parts[2]])
	hits.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0] if a[0] != b[0] else a[1] < b[1])
	if hits.is_empty():
		p.out("<p>Your search - <b>%s</b> - did not match any documents.</p>\n<p>Suggestions:</p>\n<ul><li>Make sure all words are spelled correctly.<li>Try different keywords.<li>Try fewer keywords.</ul>\n" % _html(query))
		p.out(FOOT)
		return 0
	start = clampi(start, 0, maxi(0, hits.size() - 1))
	var last := mini(start + PER_PAGE, hits.size())
	p.out("<p>Results <b>%d</b> - <b>%d</b> of about <b>%d</b> for <b>%s</b>.</p>\n<dl>\n" % [start + 1, last, hits.size(), _html(query)])
	for k in range(start, last):
		var h: Array = hits[k]
		p.out("<dt><a href=\"%s\">%s</a>\n<dd>%s<br>\n<font color=\"#008000\">%s</font><br><br>\n" % [h[1], _html(h[2]), _html(_snippet(h[3], terms)), _html(h[1])])
	p.out("</dl>\n")
	if hits.size() > PER_PAGE:
		var nav := "<p><center>Result Page: "
		var q := AgoraHttp.form_encode([["q", query]])
		if start > 0:
			nav += "<a href=\"/cgi-bin/search?%s&amp;start=%d\">Previous</a> " % [q, start - PER_PAGE]
		for page in ceili(float(hits.size()) / PER_PAGE):
			var at := page * PER_PAGE
			nav += ("<b>%d</b> " % (page + 1)) if at == start else ("<a href=\"/cgi-bin/search?%s&amp;start=%d\">%d</a> " % [q, at, page + 1])
		if last < hits.size():
			nav += "<a href=\"/cgi-bin/search?%s&amp;start=%d\">Next</a>" % [q, last]
		p.out(nav + "</center></p>\n")
	p.out(FOOT)
	return 0


## About 160 characters of [param text] around the first term found.
static func _snippet(text: String, terms: PackedStringArray) -> String:
	var lower := text.to_lower()
	var at := -1
	for t in terms:
		at = lower.find(t)
		if at >= 0:
			break
	var from := maxi(0, at - 60)
	var piece := text.substr(from, 160).strip_edges()
	return ("..." if from > 0 else "") + piece + ("..." if from + 160 < text.length() else "")


func _add(p: AgoraProcess, url: String) -> int:
	p.out("Content-Type: text/html\n\n")
	p.out(HEAD % ["Ferret: Add URL", ""])
	if not url.begins_with("http://") or AgoraHttp.parse_url(url).is_empty():
		p.out("<p>Sorry, that doesn't look like a web address. It should start with <b>http://</b>.</p>\n<p><a href=\"/addurl.html\">Try again</a></p>\n")
	elif p.machine.vfs.write_text(p.cred, SUBMITTED, url + "\n", "/", true) != AgoraErrno.OK:
		p.out("<p>Sorry, we can't take new sites right now. Please try again later.</p>\n")
	else:
		p.out("<p>Thank you! <b>%s</b> will be visited by the Ferret on its next trip around the web.</p>\n" % _html(url))
	p.out(FOOT)
	return 0
