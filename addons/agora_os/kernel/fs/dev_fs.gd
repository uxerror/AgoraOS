class_name AgoraDevFs
extends AgoraFs
## Flat file system of character devices, mounted at /dev. Each device is a
## pair of callables, so the game can add its own hardware (a modem, a dialer,
## a sensor) with [method add_device] without touching the kernel.

const CHUNK := 512

## Timestamp reported for /dev and its devices, set when the machine boots.
var mtime := 0

var _devices := {} # name -> {read: Callable, write: Callable, mode: int}
var _rng := RandomNumberGenerator.new()


func _init() -> void:
	add_device("null", _empty_bytes, _discard)
	add_device("zero", _zero_bytes, _discard)
	add_device("random", _random_bytes, _discard)
	add_device("urandom", _random_bytes, _discard)


## [param reader] returns bytes for one read. [param writer] receives bytes.
## [param mode] defaults to 0o666.
func add_device(name: String, reader: Callable, writer: Callable, mode: int = 438) -> void:
	_devices[name] = {"read": reader, "write": writer, "mode": mode}


func remove_device(name: String) -> void:
	_devices.erase(name)


func fs_type() -> String:
	return "devfs"


func _discard(_data: PackedByteArray) -> void:
	pass


func _empty_bytes() -> PackedByteArray:
	return PackedByteArray()


func _zero_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(CHUNK)
	return b


func _random_bytes() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(CHUNK)
	for i in CHUNK:
		b[i] = _rng.randi() & 255
	return b


func lstat(rel: String) -> AgoraStat:
	var s := AgoraStat.new()
	s.mtime = mtime
	if rel.is_empty():
		s.type = AgoraStat.Type.DIR
		s.mode = AgoraStat.MODE_DIR
		return s
	if not _devices.has(rel):
		return null
	s.type = AgoraStat.Type.DEVICE
	s.mode = _devices[rel]["mode"]
	return s


func list_dir(rel: String) -> PackedStringArray:
	return PackedStringArray(_devices.keys()) if rel.is_empty() else PackedStringArray()


func read_file(rel: String) -> PackedByteArray:
	if not _devices.has(rel):
		return PackedByteArray()
	var reader: Callable = _devices[rel]["read"]
	if not reader.is_valid():
		_devices.erase(rel) # its driver is gone
		return PackedByteArray()
	return reader.call()


func write_file(rel: String, data: PackedByteArray, _append: bool, _mtime: int) -> int:
	if not _devices.has(rel):
		return AgoraErrno.ENOENT
	var writer: Callable = _devices[rel]["write"]
	if not writer.is_valid():
		_devices.erase(rel)
		return AgoraErrno.EIO
	writer.call(data)
	return AgoraErrno.OK
