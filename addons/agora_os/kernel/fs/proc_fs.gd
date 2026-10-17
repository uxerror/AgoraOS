class_name AgoraProcFs
extends AgoraFs
## Read-only view of kernel state, mounted at /proc. Tools like ps read these
## files instead of calling into the kernel, as on Linux.

const PID_FILES: PackedStringArray = ["cmdline", "cwd", "environ", "status"]
const TOP_FILES: PackedStringArray = ["kmsg", "mounts", "uptime", "version"]

var _machine: WeakRef


func _init(machine: Object) -> void:
	_machine = weakref(machine)
	read_only = true


func fs_type() -> String:
	return "proc"


func _m() -> AgoraMachine:
	return _machine.get_ref() as AgoraMachine


func _proc(name: String) -> AgoraProcess:
	if not name.is_valid_int():
		return null
	return _m().get_process(int(name))


func lstat(rel: String) -> AgoraStat:
	var parts := rel.split("/", false)
	var s := AgoraStat.new()
	s.mode = 292 # 0o444
	s.mtime = int(_m().clock.now())
	if parts.is_empty():
		s.type = AgoraStat.Type.DIR
		s.mode = 365 # 0o555
		return s
	if parts.size() == 1 and TOP_FILES.has(parts[0]):
		s.size = read_file(rel).size()
		return s
	var p := _proc(parts[0])
	if p == null:
		return null
	s.uid = p.cred.uid
	s.gid = p.cred.gid
	if parts.size() == 1:
		s.type = AgoraStat.Type.DIR
		s.mode = 365
		return s
	if parts.size() == 2 and PID_FILES.has(parts[1]):
		if parts[1] == "cwd":
			s.type = AgoraStat.Type.SYMLINK
			s.mode = AgoraStat.MODE_SYMLINK
		elif parts[1] == "environ":
			s.mode = 256 # 0o400
		s.size = read_file(rel).size()
		return s
	return null


func list_dir(rel: String) -> PackedStringArray:
	if rel.is_empty():
		var out := TOP_FILES.duplicate()
		for pid in _m().list_pids():
			out.append(str(pid))
		return out
	if _proc(rel) != null:
		return PID_FILES
	return []


func read_file(rel: String) -> PackedByteArray:
	var parts := rel.split("/", false)
	var m := _m()
	var text := ""
	if parts.size() == 1:
		match parts[0]:
			"uptime":
				text = "%.2f\n" % (m.clock.now() - m.boot_time)
			"kmsg":
				text = "\n".join(m.kmsg) + "\n"
			"version":
				text = "%s version %s\n" % [AgoraMachine.KERNEL_NAME, AgoraMachine.KERNEL_VERSION]
			"mounts":
				for point in m.vfs.mount_points():
					text += "%s %s %s\n" % [m.vfs.get_mount(point).fs_type(), point, "ro" if m.vfs.get_mount(point).read_only else "rw"]
	elif parts.size() == 2:
		var p := _proc(parts[0])
		if p == null:
			return PackedByteArray()
		match parts[1]:
			"cmdline":
				text = " ".join(p.argv) + "\n"
			"environ":
				for k in p.env:
					text += "%s=%s\n" % [k, p.env[k]]
			"status":
				text = "Name:\t%s\nState:\t%s\nPid:\t%d\nPPid:\t%d\nUid:\t%d\t%d\nGid:\t%d\nTty:\t%s\nStarted:\t%d\n" % [
					p.name, p.state_letter(), p.pid, p.ppid, p.cred.ruid, p.cred.uid, p.cred.gid,
					p.tty.name if p.tty else "?", int(p.start_time)]
	return text.to_utf8_buffer()


func read_link(rel: String) -> String:
	var parts := rel.split("/", false)
	if parts.size() == 2 and parts[1] == "cwd":
		var p := _proc(parts[0])
		if p:
			return p.cwd
	return ""
