extends SceneTree
## Interactive console for the kernel, without any GUI:
##   godot --headless --path . -s tools/repl.gd            (resume saved machine)
##   godot --headless --path . -s tools/repl.gd -- --fresh (start over)
##
## Logs in as "user" (password "user", member of sudo; root password "root").
## A second machine "server" (admin / admin) is on the network for ssh.
## The local machine is saved to user://machines/local.agx on exit.

const IMAGE := "user://machines/local.agx"

var _machine: AgoraMachine
var _server: AgoraMachine
var _network := AgoraNetwork.new()
var _tty := AgoraTty.new()
var _shell: AgoraProcess


func _initialize() -> void:
	var fresh := OS.get_cmdline_user_args().has("--fresh")
	if not fresh and FileAccess.file_exists(IMAGE):
		_machine = AgoraMachine.load_image(IMAGE)
	if _machine == null:
		_machine = AgoraMachine.create("agora", {
			"root_password": "root",
			"users": [{"name": "user", "password": "user", "groups": ["sudo"]}],
			"motd": "AgoraOS console. Type 'help' for commands, Ctrl+D to quit.\n",
		})
	_server = AgoraMachine.create("server", {
		"users": [{"name": "admin", "password": "admin"}],
		"motd": "Authorized access only.\n",
	})
	_network.attach(_machine, "10.0.0.2")
	_network.attach(_server, "10.0.0.7", "server.lan")
	_tty.printed.connect(func(text: String) -> void: printraw(text.replace("\u001b[2J\u001b[H", "\n\n")))
	_shell = _machine.login("user", _tty)
	_shell.exited.connect(func(_c: int) -> void: _finish())


func _process(_delta: float) -> bool:
	if _shell == null or not _shell.is_running():
		return false
	if _tty.is_waiting_for_input():
		var line := OS.read_string_from_stdin(4096)
		if line.is_empty():
			_tty.send_eof()
		else:
			_tty.type_line(line.trim_suffix("\n").trim_suffix("\r"))
	return false


func _finish() -> void:
	DirAccess.make_dir_recursive_absolute(IMAGE.get_base_dir())
	_machine.save_image(IMAGE)
	print("Saved machine to ", ProjectSettings.globalize_path(IMAGE))
	_machine.shutdown()
	_server.shutdown()
	quit()
