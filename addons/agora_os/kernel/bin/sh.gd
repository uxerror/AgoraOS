extends AgoraProgram
## The shell. A small POSIX-flavored sh: pipes, redirections, ; && || &,
## variables, $(...), globs, ~, aliases, history and the usual builtins.
##
## Usage: sh [-l] [-c command [name [args...]]] | sh script [args...]
## A login shell (argv[0] starting with "-") reads /etc/profile and
## ~/.profile and prints /etc/motd.

const HISTORY_FILE := ".sh_history"
const HISTORY_MAX := 500
const DEFAULT_PS1 := "\\u@\\h:\\w\\$ "

const BUILTINS: PackedStringArray = [
	":", ".", "[", "alias", "break", "cd", "continue", "eval", "exit", "export",
	"false", "history", "jobs", "local", "logout", "pwd", "read", "return",
	"set", "shift", "source", "test", "true", "type", "umask", "unalias",
	"unset", "wait",
]
const MAX_FUNCTION_DEPTH := 100
const DEFAULT_PS2 := "> "


## Keeps a file redirection alive and appends whatever arrives to the file.
class FileSink:
	var stream := AgoraStream.new()
	var path: String
	var process: AgoraProcess

	func _init(p_process: AgoraProcess, p_path: String) -> void:
		process = p_process
		path = p_path
		stream.add_reader()
		stream.changed.connect(_drain)

	func _drain() -> void:
		var text := stream.read_available()
		if not text.is_empty():
			var e := process.machine.vfs.write_text(process.cred, path, text, "/", true)
			if e != AgoraErrno.OK:
				process.errln("sh: write error: " + AgoraErrno.describe(e))


var p: AgoraProcess
var last_status := 0
var history: PackedStringArray = []
var positional: PackedStringArray = []
var aliases := {}
var interactive := false
var login := false

var functions := {} # name -> command node

var _exit_requested := false
var _exit_code := 0
var _returning := false
var _return_code := 0
var _break_levels := 0
var _continue_levels := 0
var _loop_depth := 0
var _function_depth := 0
var _local_frames: Array[Dictionary] = []
var _jobs := {} # id -> {text: String}
var _next_job := 1
var _done_jobs: PackedStringArray = []
var _last_spawned := 0
var _spawn_status := 0

signal job_finished


func summary() -> String:
	return "command interpreter"


func usage() -> String:
	return "usage: sh [-l] [-c command [name [args...]]] | sh script [args...]"


func main(proc: AgoraProcess) -> int:
	p = proc
	p.signal_handler = _on_signal
	login = p.argv[0].begins_with("-")
	var command := ""
	var has_command := false
	var script := ""
	var i := 1
	while i < p.argv.size():
		var a := p.argv[i]
		if a == "-c" and not has_command:
			if i + 1 >= p.argv.size():
				return p.fail("-c: option requires an argument", 2)
			command = p.argv[i + 1]
			has_command = true
			i += 2
			break
		elif a == "-l" or a == "--login":
			login = true
			i += 1
		else:
			break
	var rest := p.argv.slice(i)

	if login:
		var motd := p.read_text("/etc/motd")
		if not motd.is_empty():
			p.out(motd)
		await _source_quiet("/etc/profile")
		await _source_quiet(p.home() + "/.profile")

	if has_command:
		positional = rest if not rest.is_empty() else PackedStringArray(["sh"])
		await run_source(command)
		return _exit_code if _exit_requested else last_status

	if not rest.is_empty():
		script = rest[0]
		var text := p.read_text(script)
		if p.errno != AgoraErrno.OK:
			return p.fail_path(script, 127)
		positional = rest
		await run_source(text)
		return _exit_code if _exit_requested else last_status

	positional = PackedStringArray([p.argv[0]])
	interactive = p.tty != null and p.stdin == p.tty.input
	if interactive:
		p.tty.history_provider = _get_history
		_load_history()
	var pending := ""
	while not _exit_requested and p.is_running():
		if interactive:
			p.tty.history_provider = _get_history
			if pending.is_empty():
				_report_done_jobs()
				p.out(prompt())
			else:
				p.out(p.getenv("PS2", DEFAULT_PS2))
		var line: Variant = await p.read_line()
		if line == null:
			if interactive:
				p.outln("logout" if login else "exit")
			break
		var text := pending + (line as String)
		# An unfinished construct ("if true; then") continues on the next line.
		if _parse(text).get("incomplete", false):
			pending = text + "\n"
			continue
		pending = ""
		if interactive and not text.strip_edges().is_empty():
			_add_history(_one_line(text))
		await run_source(text)
		_returning = false
		_break_levels = 0
		_continue_levels = 0
	if interactive and p.tty.history_provider == Callable(self, "_get_history"):
		p.tty.history_provider = Callable()
	return _exit_code if _exit_requested else last_status


func _on_signal(sig: int) -> bool:
	if sig == AgoraProcess.SIGINT and interactive:
		if p.stdin.has_waiting_reader():
			p.out("\n" + prompt())
		return true
	return false


# --- prompt and history -----------------------------------------------------

func prompt() -> String:
	var ps1 := p.getenv("PS1", DEFAULT_PS1)
	var home := p.home()
	var cwd := p.cwd
	var short_cwd := "~" + cwd.substr(home.length()) if home != "/" and AgoraPath.is_inside(cwd, home) else cwd
	var out := ""
	var i := 0
	while i < ps1.length():
		var c := ps1[i]
		if c == "\\" and i + 1 < ps1.length():
			var e := ps1[i + 1]
			i += 2
			match e:
				"u": out += p.user_name()
				"h": out += p.machine.hostname.get_slice(".", 0)
				"H": out += p.machine.hostname
				"w": out += short_cwd
				"W": out += AgoraPath.basename(cwd) if cwd != home else "~"
				"$": out += "#" if p.cred.uid == 0 else "$"
				"n": out += "\n"
				"\\": out += "\\"
				_: out += "\\" + e
			continue
		out += c
		i += 1
	return out


func _get_history() -> PackedStringArray:
	return history


func _load_history() -> void:
	var text := p.machine.vfs.read_text(p.cred, p.home() + "/" + HISTORY_FILE)
	history = text.split("\n", false)
	if history.size() > HISTORY_MAX:
		history = history.slice(history.size() - HISTORY_MAX)


## Joins a multi-line command into one history line, keeping it valid:
## lines are joined with "; " except after words that expect more input.
static func _one_line(text: String) -> String:
	var out := ""
	for line in text.split("\n", false):
		var l := line.strip_edges()
		if l.is_empty():
			continue
		if out.is_empty():
			out = l
			continue
		var last := out.get_slice(" ", out.get_slice_count(" ") - 1)
		var glue := " " if last in ["then", "do", "else", "{", "|", "&&", "||", "in"] or out.ends_with(";") else "; "
		out += glue + l
	return out


func _add_history(line: String) -> void:
	history.append(line)
	if history.size() > HISTORY_MAX:
		history.remove_at(0)
	# The history file is a trail an investigator (or intruder) can read.
	p.machine.vfs.write_text(p.cred, p.home() + "/" + HISTORY_FILE, line + "\n", "/", true, AgoraStat.MODE_PRIVATE_FILE)


# --- running source text ----------------------------------------------------

func _source_quiet(path: String) -> void:
	var st := p.stat(path)
	if st == null or not st.is_file():
		return
	await run_source(p.read_text(path))


func _parse(text: String) -> Dictionary:
	var lexed := AgoraShLexer.tokenize(text)
	if not lexed.error.is_empty():
		return {"error": lexed.error, "incomplete": lexed.error.contains("unexpected EOF")}
	return AgoraShParser.parse(lexed.tokens)


func run_source(text: String, io: Dictionary = {}) -> int:
	var parsed := _parse(text)
	if not parsed.error.is_empty():
		p.errln("sh: " + parsed.error)
		last_status = 2
		return last_status
	return await run_list(parsed.items, io)


func _default_io() -> Dictionary:
	return {"stdin": p.stdin, "stdout": p.stdout, "stderr": p.stderr, "bg": false}


## True while execution should unwind: exit, return, break or continue.
func _unwinding() -> bool:
	return _exit_requested or _returning or _break_levels > 0 or _continue_levels > 0 or p.is_dead()


func run_list(items: Array, io: Dictionary = {}) -> int:
	if io.is_empty():
		io = _default_io()
	var skip := false
	for item: Dictionary in items:
		if _unwinding():
			break
		if not skip:
			if item.op == "&":
				_start_background(item.pipeline, io)
				last_status = 0
			else:
				last_status = await _run_pipeline(item.pipeline, io)
		match item.op:
			"&&": skip = last_status != 0
			"||": skip = last_status == 0
			_: skip = false
	return last_status


func _run_pipeline(pl: Dictionary, io: Dictionary) -> int:
	var status: int
	if pl.cmds.size() == 1:
		status = await _exec_node(pl.cmds[0], io)
	else:
		status = await _exec_pipeline(pl.cmds, io)
	if pl.negate:
		status = 1 if status == 0 else 0
	return status


# --- jobs -------------------------------------------------------------------

func _start_background(pl: Dictionary, io: Dictionary) -> void:
	var id := _next_job
	_next_job += 1
	_jobs[id] = {"text": pl.text}
	var bg_io := io.duplicate()
	bg_io.bg = true
	if interactive:
		bg_io.stdin = AgoraStream.empty()
	_last_spawned = 0
	_run_job(id, pl, bg_io) # runs until its first await, then continues on its own
	if _jobs.has(id) or _last_spawned:
		p.errln("[%d] %d" % [id, _last_spawned] if _last_spawned else "[%d]" % id)


func _run_job(id: int, pl: Dictionary, io: Dictionary) -> void:
	await _run_pipeline(pl, io)
	if interactive:
		_done_jobs.append("[%d]+  Done                    %s" % [id, _jobs[id].text])
	_jobs.erase(id)
	job_finished.emit()


func _report_done_jobs() -> void:
	for line in _done_jobs:
		p.errln(line)
	_done_jobs.clear()


# --- commands ---------------------------------------------------------------

func _exec_node(node: Dictionary, io: Dictionary) -> int:
	if _unwinding():
		return last_status
	match node.t:
		"simple":
			return await _exec_simple(node, io)
		"funcdef":
			functions[node.name] = node.body
			return 0
	var cio := io.duplicate()
	var sinks: Array = []
	if not node.get("redirs", []).is_empty():
		var redirs: Variant = await _expand_redirs(node.redirs)
		if redirs == null or not _open_redirs(redirs, cio, sinks):
			return 1
	match node.t:
		"group":
			return await run_list(node.body, cio)
		"subshell":
			return await _subshell(node.body, cio)
		"if":
			for branch: Array in node.branches:
				var cond := await run_list(branch[0], cio)
				if _unwinding():
					return cond
				if cond == 0:
					return await run_list(branch[1], cio)
			if node.else_body != null:
				return await run_list(node.else_body, cio)
			return 0
		"while":
			return await _exec_while(node, cio)
		"for":
			return await _exec_for(node, cio)
		"case":
			var subject := " ".join(await _expand_word(node.word, false))
			for arm: Dictionary in node.arms:
				for pattern_parts: Array in arm.patterns:
					var pattern := await _expand_pattern(pattern_parts)
					if _glob_regex(pattern).search(subject) != null:
						return await run_list(arm.body, cio)
			return 0
	return 0


func _exec_while(node: Dictionary, io: Dictionary) -> int:
	var status := 0
	_loop_depth += 1
	while not p.is_dead():
		var cond := await run_list(node.cond, io)
		if _exit_requested or _returning or p.is_dead():
			break
		if (cond == 0) == node.until:
			break
		status = await run_list(node.body, io)
		if _loop_control_says_stop():
			break
		await p.tick()
	_loop_depth -= 1
	return status


func _exec_for(node: Dictionary, io: Dictionary) -> int:
	var words: PackedStringArray = []
	if node.words == null:
		words = positional.slice(1)
	else:
		for w: Array in node.words:
			words.append_array(await _expand_word(w))
	var status := 0
	_loop_depth += 1
	for w in words:
		p.env[node.var] = w
		status = await run_list(node.body, io)
		if _loop_control_says_stop():
			break
		await p.tick()
	_loop_depth -= 1
	return status


## Called after each loop iteration. Consumes one level of break/continue
## and returns true when this loop must stop.
func _loop_control_says_stop() -> bool:
	if _break_levels > 0:
		_break_levels -= 1
		return true
	if _continue_levels > 0:
		_continue_levels -= 1
		return _continue_levels > 0 # "continue 2" continues the outer loop
	return _exit_requested or _returning or p.is_dead()


## Runs a list with the shell state saved and restored afterwards, which is
## what a forked subshell would give.
func _subshell(body: Array, io: Dictionary) -> int:
	var saved_env := p.env.duplicate()
	var saved_cwd := p.cwd
	var saved_positional := positional
	var saved_functions := functions.duplicate()
	var status := await run_list(body, io)
	if _exit_requested:
		_exit_requested = false
		status = _exit_code
	_returning = false
	p.env = saved_env
	p.cwd = saved_cwd
	positional = saved_positional
	functions = saved_functions
	return status


func _exec_simple(cmd: Dictionary, io: Dictionary) -> int:
	var e := await _expand_cmd(cmd)
	if e.is_empty():
		return 1
	return await _exec_expanded(e, io)


func _exec_expanded(e: Dictionary, io: Dictionary) -> int:
	var cio := io.duplicate()
	var sinks: Array = []
	if not _open_redirs(e.redirs, cio, sinks):
		return 1
	if e.argv.is_empty():
		for key in e.assigns:
			p.env[key] = e.assigns[key]
		return 0
	var name: String = e.argv[0]
	if functions.has(name):
		return await _call_function(e.argv, cio)
	if BUILTINS.has(name):
		return await _builtin(e.argv, cio)
	var child := _spawn_external(e, cio, true)
	if child == null:
		return _spawn_status
	var foreground: bool = interactive and p.tty != null and not io.get("bg", false)
	if foreground:
		p.tty.foreground.assign([child])
	var code := await child.wait()
	if foreground:
		p.tty.foreground.assign([p])
		if code == 128 + AgoraProcess.SIGINT:
			p.out("\n")
	return code


func _spawn_external(e: Dictionary, io: Dictionary, start: bool) -> AgoraProcess:
	var env := p.env.duplicate()
	env.merge(e.assigns, true)
	var child := p.spawn(e.argv, {
		"stdin": io.stdin, "stdout": io.stdout, "stderr": io.stderr, "env": env, "start": start,
	})
	if child == null:
		_report_spawn_error(e.argv[0], io.stderr)
		_spawn_status = 126 if p.errno in [AgoraErrno.EACCES, AgoraErrno.ENOEXEC, AgoraErrno.EISDIR] else 127
	else:
		_last_spawned = child.pid
	return child


## A pipeline of several commands. External programs run as processes, all
## started before anything else. Builtins, functions and compound commands
## then run inside the shell one after another, reading and writing their
## pipes; pipe buffers grow as needed, so nothing deadlocks.
func _exec_pipeline(cmds: Array, io: Dictionary) -> int:
	var stages: Array[Dictionary] = []
	var prev_in: AgoraStream = io.stdin
	for i in cmds.size():
		var node: Dictionary = cmds[i]
		var is_last := i == cmds.size() - 1
		var out_stream: AgoraStream = io.stdout if is_last else AgoraStream.new()
		var sio := io.duplicate()
		sio.stdin = prev_in
		sio.stdout = out_stream
		prev_in = out_stream
		var st := {"node": node, "io": sio, "proc": null, "status": 0, "in_shell": true, "skip": false, "e": {}, "sinks": []}
		if node.t == "simple":
			var e := await _expand_cmd(node)
			st.e = e
			if e.is_empty():
				st.status = 1
				st.skip = true
			elif not e.argv.is_empty() and not functions.has(e.argv[0]) and not BUILTINS.has(e.argv[0]):
				st.in_shell = false
				var rio := sio.duplicate()
				if _open_redirs(e.redirs, rio, st.sinks):
					st.proc = _spawn_external(e, rio, false)
					if st.proc == null:
						st.status = _spawn_status
				else:
					st.status = 1
		if (st.skip or (not st.in_shell and st.proc == null)) and not is_last:
			# Nobody will write this pipe, so the next stage must see EOF.
			out_stream.add_writer()
			out_stream.release_writer()
		stages.append(st)

	var procs: Array[AgoraProcess] = []
	for i in range(stages.size() - 1, -1, -1):
		if stages[i].proc:
			procs.append(stages[i].proc)
			(stages[i].proc as AgoraProcess).start()
	var foreground: bool = interactive and p.tty != null and not io.get("bg", false)
	if foreground:
		p.tty.foreground.assign(procs)
	for st in stages:
		if not st.in_shell or st.skip:
			continue
		var sio: Dictionary = st.io
		sio.stdin.add_reader()
		sio.stdout.add_writer()
		if st.node.t == "simple":
			st.status = await _exec_expanded(st.e, sio)
		else:
			st.status = await _exec_node(st.node, sio)
		sio.stdout.release_writer()
		sio.stdin.release_reader()
	for st in stages:
		if st.proc:
			st.status = await (st.proc as AgoraProcess).wait()
	if foreground:
		p.tty.foreground.assign([p])
		if stages[-1].status == 128 + AgoraProcess.SIGINT:
			p.out("\n")
	return stages[-1].status


func _call_function(argv: PackedStringArray, io: Dictionary) -> int:
	if _function_depth >= MAX_FUNCTION_DEPTH:
		io.stderr.write("sh: %s: maximum function nesting level exceeded\n" % argv[0])
		return 1
	var saved := positional
	positional = PackedStringArray([positional[0] if not positional.is_empty() else "sh"])
	positional.append_array(argv.slice(1))
	_local_frames.append({})
	_function_depth += 1
	var status := await _exec_node(functions[argv[0]], io)
	_function_depth -= 1
	if _returning:
		_returning = false
		status = _return_code
	var frame: Dictionary = _local_frames.pop_back()
	for key in frame:
		if frame[key] == null:
			p.env.erase(key)
		else:
			p.env[key] = frame[key]
	positional = saved
	return status


func _report_spawn_error(command: String, err_stream: AgoraStream) -> void:
	var msg: String
	match p.errno:
		AgoraErrno.ENOENT:
			msg = "command not found" if not command.contains("/") else AgoraErrno.describe(p.errno)
		AgoraErrno.ENOEXEC:
			msg = "cannot execute binary file: Exec format error"
		_:
			msg = AgoraErrno.describe(p.errno)
	err_stream.write("sh: %s: %s\n" % [command, msg])


# --- redirections -----------------------------------------------------------

## Applies redirections to [param io]. Returns false (after printing an
## error) if a file can't be opened.
func _open_redirs(redirs: Array, io: Dictionary, sinks: Array) -> bool:
	for r: Dictionary in redirs:
		var op: String = r.op
		if op == "2>&1":
			io.stderr = io.stdout
			continue
		if op == ">&2":
			io.stdout = io.stderr
			continue
		var target: String = r.target_text
		if op == "<":
			var text := p.read_text(target)
			if p.errno != AgoraErrno.OK:
				p.errln("sh: %s: %s" % [target, AgoraErrno.describe(p.errno)])
				return false
			io.stdin = AgoraStream.from_text(text)
			continue
		var path := p.abspath(target)
		var st := p.stat(path)
		var is_device := st != null and st.is_device()
		var append := op == ">>" or op == "2>>"
		if not is_device:
			# Create or truncate now, so errors show before the command runs.
			var e := p.write_text(path, "", append)
			if e != AgoraErrno.OK:
				p.errln("sh: %s: %s" % [target, AgoraErrno.describe(e)])
				return false
		var sink := FileSink.new(p, path)
		sinks.append(sink)
		match op:
			">", ">>":
				io.stdout = sink.stream
			"2>", "2>>":
				io.stderr = sink.stream
			"&>":
				io.stdout = sink.stream
				io.stderr = sink.stream
	return true


# --- expansion --------------------------------------------------------------

## Returns {argv, assigns, redirs} or {} after printing an error.
func _expand_cmd(cmd: Dictionary) -> Dictionary:
	var argv: PackedStringArray = []
	for parts: Array in cmd.words:
		argv.append_array(await _expand_word(parts))
	if not argv.is_empty() and aliases.has(argv[0]):
		var replacement: PackedStringArray = (aliases[argv[0]] as String).split(" ", false)
		replacement.append_array(argv.slice(1))
		argv = replacement
	var assigns := {}
	for a: Array in cmd.assigns:
		assigns[a[0]] = " ".join(await _expand_word(a[1], false))
	var redirs: Variant = await _expand_redirs(cmd.redirs)
	if redirs == null:
		return {}
	return {"argv": argv, "assigns": assigns, "redirs": redirs}


## Expands redirection targets. Returns null after an error.
func _expand_redirs(redirs: Array) -> Variant:
	var out: Array = []
	for r: Dictionary in redirs:
		var copy := r.duplicate()
		if r.target != null:
			var fields := await _expand_word(r.target)
			if fields.size() != 1:
				p.errln("sh: %s: ambiguous redirect" % AgoraShParser.word_text(r.target))
				return null
			copy.target_text = fields[0]
		out.append(copy)
	return out


## Expands a case pattern: quoted parts match literally, the rest keeps its
## glob characters.
func _expand_pattern(parts: Array) -> String:
	var pat := ""
	for part: Dictionary in parts:
		if part.has("sub"):
			pat += _escape_glob(await _command_subst(part.sub))
		elif part.has("arith"):
			pat += await _arith(part.arith)
		elif part.q == 1:
			pat += _escape_glob(part.s)
		elif part.q == 2:
			pat += _escape_glob(await _expand_dollars(part.s, true))
		else:
			for seg: Array in await _expand_raw(part.s):
				pat += seg[0] if seg.size() > 2 else _escape_glob(seg[0])
	return pat


## Evaluates $(( expr )): integers, + - * / %, comparisons, && || !,
## parentheses. Variables may be written with or without "$".
func _arith(expr: String) -> String:
	var text := await _expand_dollars(expr, true)
	var names := RegEx.create_from_string("[A-Za-z_][A-Za-z0-9_]*")
	var out := ""
	var last := 0
	for m in names.search_all(text):
		out += text.substr(last, m.get_start() - last)
		var v := p.getenv(m.get_string()).strip_edges()
		out += v if v.is_valid_int() else "0"
		last = m.get_end()
	out += text.substr(last)
	var ex := Expression.new()
	if out.strip_edges().is_empty():
		return "0"
	if ex.parse(out) != OK:
		p.errln("sh: %s: syntax error in expression" % expr.strip_edges())
		return "0"
	var r: Variant = ex.execute()
	if ex.has_execute_failed() or r == null:
		p.errln("sh: %s: arithmetic error" % expr.strip_edges())
		return "0"
	if r is bool:
		return "1" if r else "0"
	return str(int(r))


## Expands one word into zero or more fields: ~, $vars, $(...), field
## splitting of unquoted expansions, then globbing.
func _expand_word(parts: Array, split_and_glob: bool = true) -> PackedStringArray:
	var fields: PackedStringArray = []
	var cur := ""
	var pat := ""
	var started := false
	var magic := false
	for idx in parts.size():
		var part: Dictionary = parts[idx]
		var segments: Array = [] # [text, splittable]
		if part.has("sub"):
			segments.append([await _command_subst(part.sub), true])
		elif part.has("arith"):
			segments.append([await _arith(part.arith), true])
		elif part.q == 1:
			cur += part.s
			pat += _escape_glob(part.s)
			started = true
			continue
		elif part.q == 2:
			var t := await _expand_dollars(part.s, true)
			cur += t
			pat += _escape_glob(t)
			started = true
			continue
		else:
			var s: String = part.s
			if idx == 0 and s.begins_with("~"):
				s = _expand_tilde(s)
			segments = await _expand_raw(s)
		for seg: Array in segments:
			var text: String = seg[0]
			if not seg[1] or not split_and_glob:
				cur += text
				pat += text if seg.size() > 2 else _escape_glob(text)
				if seg.size() > 2 and (text.contains("*") or text.contains("?") or text.contains("[")):
					magic = true
				if not text.is_empty():
					started = true
				continue
			# Unquoted expansion result: split on whitespace.
			var pieces := text.split(" ", false) if not text.contains("\n") and not text.contains("\t") \
				else text.replace("\t", " ").replace("\n", " ").split(" ", false)
			if pieces.is_empty():
				continue
			if text[0] in [" ", "\t", "\n"] and started:
				_push_field(fields, cur, pat, magic)
				cur = ""
				pat = ""
				magic = false
			for k in pieces.size():
				if k > 0:
					_push_field(fields, cur, pat, magic)
					cur = ""
					pat = ""
					magic = false
				cur += pieces[k]
				pat += _escape_glob(pieces[k])
				started = true
			if text[-1] in [" ", "\t", "\n"]:
				_push_field(fields, cur, pat, magic)
				cur = ""
				pat = ""
				magic = false
				started = false
	if started or not cur.is_empty():
		_push_field(fields, cur, pat, magic and split_and_glob)
	return fields


func _push_field(fields: PackedStringArray, text: String, pattern: String, magic: bool) -> void:
	if magic:
		var matches := _glob(pattern)
		if not matches.is_empty():
			fields.append_array(matches)
			return
	fields.append(text)


## Splits an unquoted raw string into segments. Literal text becomes
## [text, false, true] (the third element marks glob characters as active);
## expansions become [value, true].
func _expand_raw(s: String) -> Array:
	var out: Array = []
	var lit := ""
	var i := 0
	while i < s.length():
		if s[i] == "$":
			var r := await _dollar_at(s, i)
			if r.is_empty():
				lit += "$"
				i += 1
				continue
			if not lit.is_empty():
				out.append([lit, false, true])
				lit = ""
			out.append([r.value, true])
			i = r.end
			continue
		lit += s[i]
		i += 1
	if not lit.is_empty():
		out.append([lit, false, true])
	return out


## Expands $ forms (and, inside double quotes, backslash escapes) in [param s].
func _expand_dollars(s: String, in_dquote: bool) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if in_dquote and c == "\\" and i + 1 < s.length():
			var nxt := s[i + 1]
			if nxt in ["$", "`", "\"", "\\", "\n"]:
				out += nxt if nxt != "\n" else ""
				i += 2
				continue
		if c == "$":
			var r := await _dollar_at(s, i)
			if not r.is_empty():
				out += r.value
				i = r.end
				continue
		out += c
		i += 1
	return out


## Parses the $-expansion starting at [param i]. Returns {value, end} or {}.
func _dollar_at(s: String, i: int) -> Dictionary:
	if i + 1 >= s.length():
		return {}
	var c := s[i + 1]
	if c == "(":
		var close := AgoraShLexer.find_paren_end(s, i + 1)
		if close < 0:
			return {}
		if s.substr(i + 1, 2) == "((" and s[close - 1] == ")":
			return {"value": await _arith(s.substr(i + 3, close - i - 4)), "end": close + 1}
		return {"value": await _command_subst(s.substr(i + 2, close - i - 2)), "end": close + 1}
	if c == "{":
		var close := s.find("}", i + 2)
		if close < 0:
			return {}
		var body := s.substr(i + 2, close - i - 2)
		var dash := body.find(":-")
		if dash > 0:
			var v := _var(body.substr(0, dash))
			return {"value": v if not v.is_empty() else body.substr(dash + 2), "end": close + 1}
		return {"value": _var(body), "end": close + 1}
	if c in ["?", "$", "#", "@", "*"] or (c >= "0" and c <= "9"):
		return {"value": _var(c), "end": i + 2}
	var j := i + 1
	while j < s.length() and (s[j] == "_" or (s[j] >= "A" and s[j] <= "Z") or (s[j] >= "a" and s[j] <= "z") or (j > i + 1 and s[j] >= "0" and s[j] <= "9")):
		j += 1
	if j == i + 1:
		return {}
	return {"value": _var(s.substr(i + 1, j - i - 1)), "end": j}


func _var(name: String) -> String:
	match name:
		"?": return str(last_status)
		"$": return str(p.pid)
		"#": return str(maxi(0, positional.size() - 1))
		"@", "*": return " ".join(positional.slice(1))
	if name.is_valid_int():
		var n := int(name)
		return positional[n] if n < positional.size() else ""
	return p.getenv(name)


func _expand_tilde(s: String) -> String:
	var slash := s.find("/")
	var who := s.substr(1, slash - 1) if slash >= 0 else s.substr(1)
	var rest := s.substr(slash) if slash >= 0 else ""
	if who.is_empty():
		return p.home() + rest
	var u := p.machine.users.find(who)
	return (u.home + rest) if not u.is_empty() else s


## $(...): runs [param src] in a subshell (functions and variables visible,
## changes discarded) and returns its output without trailing newlines.
func _command_subst(src: String) -> String:
	var parsed := _parse(src)
	if not parsed.error.is_empty():
		p.errln("sh: " + parsed.error)
		last_status = 2
		return ""
	var capture := AgoraStream.new()
	capture.add_reader()
	capture.add_writer()
	var io := {"stdin": p.stdin, "stdout": capture, "stderr": p.stderr, "bg": false}
	last_status = await _subshell(parsed.items, io)
	capture.release_writer()
	var text := capture.read_available()
	capture.release_reader()
	return text.rstrip("\n")


# --- globbing ---------------------------------------------------------------

func _escape_glob(s: String) -> String:
	return s.replace("\\", "\\\\").replace("*", "\\*").replace("?", "\\?").replace("[", "\\[")


func _unescape_glob(s: String) -> String:
	var out := ""
	var i := 0
	while i < s.length():
		if s[i] == "\\" and i + 1 < s.length():
			out += s[i + 1]
			i += 2
			continue
		out += s[i]
		i += 1
	return out


func _has_magic(comp: String) -> bool:
	var i := 0
	while i < comp.length():
		if comp[i] == "\\":
			i += 2
			continue
		if comp[i] in ["*", "?", "["]:
			return true
		i += 1
	return false


func _glob_regex(comp: String) -> RegEx:
	var rx := "^"
	var i := 0
	while i < comp.length():
		var c := comp[i]
		if c == "\\" and i + 1 < comp.length():
			rx += _rx_escape(comp[i + 1])
			i += 2
			continue
		match c:
			"*":
				rx += ".*"
			"?":
				rx += "."
			"[":
				var close := comp.find("]", i + 2)
				if close < 0:
					rx += "\\["
				else:
					var body := comp.substr(i + 1, close - i - 1)
					if body.begins_with("!"):
						body = "^" + body.substr(1)
					rx += "[" + body.replace("\\", "\\\\") + "]"
					i = close
			_:
				rx += _rx_escape(c)
		i += 1
	var re := RegEx.new()
	re.compile(rx + "$")
	return re


static func _rx_escape(c: String) -> String:
	return "\\" + c if ".^$+(){}|[]\\/*?".contains(c) else c


## Expands a glob pattern (with "\" escaping quoted characters) to the
## sorted list of matching paths, or [] if nothing matches.
func _glob(pattern: String) -> PackedStringArray:
	var absolute := pattern.begins_with("/")
	var bases: PackedStringArray = ["/" if absolute else ""]
	for comp in pattern.split("/", false):
		var next: PackedStringArray = []
		if not _has_magic(comp):
			var lit := _unescape_glob(comp)
			for b in bases:
				next.append(lit if b.is_empty() else AgoraPath.join(b, lit))
		else:
			var re := _glob_regex(comp)
			var dot_ok := comp.begins_with(".") or comp.begins_with("\\.")
			for b in bases:
				for name in p.list_dir(b if not b.is_empty() else "."):
					if name.begins_with(".") and not dot_ok:
						continue
					if re.search(name) != null:
						next.append(name if b.is_empty() else AgoraPath.join(b, name))
		bases = next
		if bases.is_empty():
			return []
	var out: PackedStringArray = []
	for b in bases:
		if p.stat(b, false) != null:
			out.append(b)
	out.sort()
	return out


# --- builtins ---------------------------------------------------------------

func _builtin(argv: PackedStringArray, io: Dictionary) -> int:
	var out: AgoraStream = io.stdout
	var errs: AgoraStream = io.stderr
	var name := argv[0]
	match name:
		":", "true":
			return 0
		"false":
			return 1
		"test", "[":
			var tester: AgoraProgram = AgoraPrograms.lookup("test").new()
			return tester.evaluate(p, argv.slice(1), name == "[")
		"break", "continue":
			if _loop_depth == 0:
				errs.write("sh: %s: only meaningful in a loop\n" % name)
				return 0
			var levels := clampi(int(argv[1]) if argv.size() > 1 and argv[1].is_valid_int() else 1, 1, _loop_depth)
			if name == "break":
				_break_levels = levels
			else:
				_continue_levels = levels
			return 0
		"return":
			_returning = true
			_return_code = int(argv[1]) if argv.size() > 1 and argv[1].is_valid_int() else last_status
			return _return_code
		"local":
			if _local_frames.is_empty():
				errs.write("sh: local: can only be used in a function\n")
				return 1
			var frame: Dictionary = _local_frames[-1]
			for a in argv.slice(1):
				var key := a.get_slice("=", 0)
				if not frame.has(key):
					frame[key] = p.env.get(key)
				p.env[key] = a.substr(key.length() + 1) if a.contains("=") else ""
			return 0
		"eval":
			return await run_source(" ".join(argv.slice(1)), io)
		"cd":
			var target := p.home()
			if argv.size() > 1:
				target = argv[1]
				if target == "-":
					target = p.getenv("OLDPWD", p.cwd)
					out.write(target + "\n")
			var old := p.cwd
			if p.chdir(target) != AgoraErrno.OK:
				errs.write("sh: cd: %s: %s\n" % [target, AgoraErrno.describe(p.errno)])
				return 1
			p.env["OLDPWD"] = old
			return 0
		"pwd":
			out.write(p.cwd + "\n")
			return 0
		"exit", "logout":
			_exit_requested = true
			_exit_code = int(argv[1]) if argv.size() > 1 and argv[1].is_valid_int() else last_status
			return _exit_code
		"export":
			if argv.size() == 1:
				return _print_vars(out, "export ")
			for a in argv.slice(1):
				var eq := a.find("=")
				if eq > 0:
					p.env[a.substr(0, eq)] = a.substr(eq + 1)
				elif not p.env.has(a):
					p.env[a] = ""
			return 0
		"set":
			return _print_vars(out, "")
		"unset":
			for a in argv.slice(1):
				p.env.erase(a)
			return 0
		"history":
			var start := 0
			if argv.size() > 1 and argv[1].is_valid_int():
				start = maxi(0, history.size() - int(argv[1]))
			if argv.size() > 1 and argv[1] == "-c":
				history.clear()
				return 0
			for k in range(start, history.size()):
				out.write("%5d  %s\n" % [k + 1, history[k]])
			return 0
		"source", ".":
			if argv.size() < 2:
				errs.write("sh: %s: filename argument required\n" % name)
				return 2
			var text := p.read_text(argv[1])
			if p.errno != AgoraErrno.OK:
				errs.write("sh: %s: %s\n" % [argv[1], AgoraErrno.describe(p.errno)])
				return 1
			var status := await run_source(text, io)
			if _returning:
				_returning = false
				status = _return_code
			return status
		"alias":
			if argv.size() == 1:
				var keys := aliases.keys()
				keys.sort()
				for k in keys:
					out.write("alias %s='%s'\n" % [k, aliases[k]])
				return 0
			for a in argv.slice(1):
				var eq := a.find("=")
				if eq > 0:
					aliases[a.substr(0, eq)] = a.substr(eq + 1)
				elif aliases.has(a):
					out.write("alias %s='%s'\n" % [a, aliases[a]])
				else:
					errs.write("sh: alias: %s: not found\n" % a)
			return 0
		"unalias":
			for a in argv.slice(1):
				aliases.erase(a)
			return 0
		"type":
			var status := 0
			for a in argv.slice(1):
				if aliases.has(a):
					out.write("%s is aliased to `%s'\n" % [a, aliases[a]])
				elif BUILTINS.has(a):
					out.write("%s is a shell builtin\n" % a)
				else:
					var found := p.machine.find_executable(a, p.getenv("PATH", AgoraMachine.DEFAULT_PATH), p.cred, p.cwd)
					if found.is_empty():
						errs.write("sh: type: %s: not found\n" % a)
						status = 1
					else:
						out.write("%s is %s\n" % [a, found])
			return status
		"umask":
			if argv.size() == 1:
				out.write("%04d\n" % int(AgoraStat.to_octal(p.cred.umask)))
				return 0
			var m := AgoraStat.parse_octal(argv[1])
			if m < 0:
				errs.write("sh: umask: %s: invalid octal number\n" % argv[1])
				return 1
			p.cred.umask = m
			return 0
		"read":
			var names: PackedStringArray = []
			var k := 1
			while k < argv.size():
				if argv[k] == "-p" and k + 1 < argv.size():
					errs.write(argv[k + 1])
					k += 2
					continue
				names.append(argv[k])
				k += 1
			if names.is_empty():
				names.append("REPLY")
			var line: Variant = await (io.stdin as AgoraStream).read_line(p.is_dead)
			if line == null:
				return 1
			var words := (line as String).split(" ", false)
			for n in names.size():
				if n == names.size() - 1:
					p.env[names[n]] = " ".join(words.slice(n))
				else:
					p.env[names[n]] = words[n] if n < words.size() else ""
			return 0
		"shift":
			var count := int(argv[1]) if argv.size() > 1 else 1
			if count > positional.size() - 1:
				return 1
			var first := positional[0]
			positional = positional.slice(count + 1)
			positional.insert(0, first)
			return 0
		"jobs":
			var ids := _jobs.keys()
			ids.sort()
			for id in ids:
				out.write("[%d]   Running                 %s &\n" % [id, _jobs[id].text])
			return 0
		"wait":
			while not _jobs.is_empty() and p.is_running():
				await job_finished
			return 0
	return 1


func _print_vars(out: AgoraStream, prefix: String) -> int:
	var keys := p.env.keys()
	keys.sort()
	for k in keys:
		out.write("%s%s='%s'\n" % [prefix, k, p.env[k]])
	return 0
