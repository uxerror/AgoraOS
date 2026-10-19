class_name AgoraClock
extends RefCounted
## In-game time source. Starts at the real time by default, but the game can
## set any date (say, 2003) and speed it up, slow it down or freeze it.
## Several machines can share one clock.

var speed := 1.0:
	get:
		return _parent.speed if _parent else speed
## Local time zone offset from UTC in minutes. Defaults to the player's.
var tz_offset_minutes := 0:
	get:
		return _parent.tz_offset_minutes if _parent else tz_offset_minutes

var _base_game := 0.0
var _base_real := 0.0
## A clock made by [method follow] runs as its parent does, this many
## seconds ahead.
var follow_offset := 0.0
var _parent: AgoraClock


func _init(start_unix: float = -1.0) -> void:
	_base_game = Time.get_unix_time_from_system() if start_unix < 0.0 else start_unix
	_base_real = _real()
	tz_offset_minutes = int(Time.get_time_zone_from_system().get("bias", 0))


## A clock that keeps [param parent]'s time and speed, moved by
## [member follow_offset]: a box's own clock in a shared world. Setting
## its time moves only the offset.
static func follow(parent: AgoraClock) -> AgoraClock:
	var c := AgoraClock.new()
	c._parent = parent
	return c


func _real() -> float:
	return Time.get_ticks_usec() / 1000000.0


## Current Unix time (UTC) in seconds.
func now() -> float:
	if _parent:
		return _parent.now() + follow_offset
	return _base_game + (_real() - _base_real) * speed


func now_int() -> int:
	return int(now())


func set_time(unix: float) -> void:
	if _parent:
		follow_offset = unix - _parent.now()
		return
	_base_game = unix
	_base_real = _real()


func set_speed(value: float) -> void:
	if _parent:
		_parent.set_speed(value)
		return
	_base_game = now()
	_base_real = _real()
	speed = value


## Datetime dictionary in local time, as Time.get_datetime_dict_from_unix_time.
func local_datetime(unix: float = -1.0) -> Dictionary:
	var t := now() if unix < 0.0 else unix
	return Time.get_datetime_dict_from_unix_time(int(t) + tz_offset_minutes * 60)


const _DAYS: PackedStringArray = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
const _MONTHS: PackedStringArray = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]


## Classic "Sat Oct 17 15:04:05 2026" format used by date and logs.
func format_long(unix: float = -1.0) -> String:
	var d := local_datetime(unix)
	return "%s %s %2d %02d:%02d:%02d %d" % [_DAYS[d.weekday], _MONTHS[d.month - 1], d.day, d.hour, d.minute, d.second, d.year]


## Syslog style "Oct 17 15:04:05".
func format_log(unix: float = -1.0) -> String:
	var d := local_datetime(unix)
	return "%s %2d %02d:%02d:%02d" % [_MONTHS[d.month - 1], d.day, d.hour, d.minute, d.second]


## "ls -l" style "Oct 17 15:04".
func format_short(unix: float) -> String:
	var d := local_datetime(unix)
	return "%s %2d %02d:%02d" % [_MONTHS[d.month - 1], d.day, d.hour, d.minute]


func serialize() -> Dictionary:
	return {"now": now(), "speed": speed, "tz": tz_offset_minutes}


func deserialize(data: Dictionary) -> void:
	set_time(data.get("now", now()))
	speed = data.get("speed", 1.0)
	tz_offset_minutes = data.get("tz", tz_offset_minutes)
