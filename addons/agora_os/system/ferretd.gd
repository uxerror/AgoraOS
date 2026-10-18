extends AgoraProgram
## ferretd: the Ferret search engine's crawler. It starts from the seed
## URLs in /etc/ferret/ferret.conf and the ones people submitted
## (/var/lib/ferret/submitted), fetches pages over HTTP, follows their
## links, and writes what it read to /var/lib/ferret/index, one page per
## line: URL, title and text separated by tabs. It honours robots.txt
## (User-agent: * and Ferret) and crawls again every "interval" seconds.
##
## ferret.conf: "seed URL", "interval SECONDS", "max_pages N", "agent TEXT".

const CONF := "/etc/ferret/ferret.conf"
const INDEX := "/var/lib/ferret/index"
const SUBMITTED := "/var/lib/ferret/submitted"
const MAX_TEXT := 4000

var p: AgoraProcess
var _robots := {}


func summary() -> String:
	return "the Ferret web crawler"


func usage() -> String:
	return "usage: ferretd [-1] (-1: crawl once and exit)"


func main(proc: AgoraProcess) -> int:
	p = proc
	var once := p.argv.has("-1")
	while p.is_running():
		var conf := _config()
		var n := await crawl(conf)
		if once:
			return 0
		# Nothing reachable yet (the network may still be coming up).
		await p.sleep(30.0 if n == 0 else float(conf.interval))
	return 0


func _config() -> Dictionary:
	var conf := {"seeds": PackedStringArray(), "interval": 1800, "max_pages": 300,
		"agent": "Ferret/0.9 (+http://www.ferret.org/bot.html)"}
	for line in p.read_text(CONF).split("\n", false):
		line = line.get_slice("#", 0).strip_edges()
		var key := line.get_slice(" ", 0)
		var value := line.substr(key.length()).strip_edges()
		match key:
			"seed":
				conf.seeds = (conf.seeds as PackedStringArray) + PackedStringArray([value])
			"interval":
				conf.interval = maxi(60, value.to_int())
			"max_pages":
				conf.max_pages = maxi(1, value.to_int())
			"agent":
				conf.agent = value
	return conf


func _log(message: String) -> void:
	p.machine.log_event("daemon", "ferretd[%d]" % p.pid, message)


## Crawls once and rewrites the index. Returns how many pages it read.
func crawl(conf: Dictionary) -> int:
	_robots.clear()
	var queue: PackedStringArray = conf.seeds.duplicate()
	for line in p.read_text(SUBMITTED).split("\n", false):
		if line.strip_edges().begins_with("http://"):
			queue.append(line.strip_edges())
	var seen := {}
	var records: PackedStringArray = []
	var k := 0
	while k < queue.size() and records.size() < conf.max_pages and p.is_running():
		var url := AgoraHttp.parse_url(queue[k]).get("url", "")
		k += 1
		if url.is_empty() or seen.has(url):
			continue
		seen[url] = true
		if not await _allowed(url, conf.agent):
			continue
		var r: Dictionary = await AgoraHttp.fetch(p, url, {"agent": conf.agent, "timeout": 10.0})
		if r.has("error") or r.code != 200:
			continue
		url = r.url
		seen[url] = true
		var type := str(r.headers.get("content-type", "text/html")).to_lower()
		var body := AgoraWire.encode(r.body).get_string_from_utf8()
		var title := AgoraPath.basename(AgoraHttp.parse_url(url).get("path", url))
		var text := body
		if type.begins_with("text/html"):
			var page := AgoraHtml.render(body, 1000)
			if not str(page.title).is_empty():
				title = page.title
			var words: PackedStringArray = []
			for l: String in page.lines:
				if not l.strip_edges().is_empty():
					words.append(l.strip_edges())
			text = " ".join(words)
			var base: String = page.base if not str(page.base).is_empty() else url
			for e: Dictionary in page.links:
				if e.kind == "link":
					var next := AgoraHttp.resolve(base, str(e.url))
					if next.begins_with("http://") and not seen.has(next):
						queue.append(next)
		elif not type.begins_with("text/"):
			continue
		text = text.replace("\t", " ").replace("\n", " ").replace("\r", " ").left(MAX_TEXT)
		records.append("%s\t%s\t%s" % [url, title.replace("\t", " "), text])
		await p.tick()
	if records.is_empty():
		return 0
	p.machine.vfs.write_text(p.cred, INDEX + ".new", "\n".join(records) + "\n")
	p.machine.vfs.rename(p.cred, INDEX + ".new", INDEX)
	_log("crawl finished: %d pages indexed" % records.size())
	return records.size()


## robots.txt: may [param agent] fetch [param url]?
func _allowed(url: String, agent: String) -> bool:
	var u := AgoraHttp.parse_url(url)
	var site := "http://%s%s" % [u.host, ":%d" % u.port if u.port != 80 else ""]
	if not _robots.has(site):
		var rules: PackedStringArray = []
		var r: Dictionary = await AgoraHttp.fetch(p, site + "/robots.txt", {"agent": agent, "timeout": 10.0, "redirects": 0})
		if not r.has("error") and r.code == 200:
			var applies := false
			for line in AgoraWire.encode(r.body).get_string_from_utf8().split("\n"):
				line = line.get_slice("#", 0).strip_edges()
				var key := line.get_slice(":", 0).strip_edges().to_lower()
				var value := line.substr(line.find(":") + 1).strip_edges() if line.contains(":") else ""
				if key == "user-agent":
					applies = value == "*" or value.to_lower().begins_with("ferret")
				elif key == "disallow" and applies and not value.is_empty():
					rules.append(value)
		_robots[site] = rules
	for prefix: String in _robots[site]:
		if str(u.path).begins_with(prefix):
			return false
	return true
