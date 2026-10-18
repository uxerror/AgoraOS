class_name AgoraCable
extends RefCounted
## A cable between two network ports. Each direction is a lane with its
## own transmit queue: a frame holds the lane for its time on the wire
## (preamble and SFD, the frame padded to 60 bytes, FCS) at the link
## speed, and the next one may start after the interframe gap. Then the
## signal travels the length of the cable. So a 10 Mbit/s link really
## carries about 10 Mbit/s, bursts wait their turn, and frames arrive in
## the order they were sent.
##
## A cable also has a bit error rate, from its length beyond what the
## standard allows and from defects. Each frame is checked against it on
## the way: a frame hit by an error arrives with a bad FCS and the
## receiving card throws it away.
##
## Times are real seconds, like the stack's other network timers.

## Preamble (7 bytes) and start frame delimiter (1).
const PREAMBLE := 8
const FCS := 4
## Shortest frame without its FCS; shorter ones are padded.
const MIN_FRAME := 60
## Interframe gap: 96 bit times between the end of one frame and the start
## of the next. It delays the next frame, not this one.
const IFG_BITS := 96
## Signal speed in copper: about 5 ns per metre.
const NS_PER_METRE := 5.0
## Frames due within this many seconds are handed over at the end of the
## engine frame rather than on a timer.
const EAGER := 0.002
## Bit error rate of a sound cable within its reach.
const BER_SOUND := 1e-12
## How far each speed goes before the signal fades: twisted pair is rated
## for 100 m, and 10BASE-T's slower signal carries on further in practice.
const REACH_M := {10: 150.0, 100: 100.0, 1000: 100.0}
## Beyond its reach, a link's error rate grows tenfold every this many
## metres: 100BASE-TX still mostly works at 150 m and is dead by 190 m.
const DECADE_M := 10.0
## Defects and the bit error rate each adds at 100 Mbit/s.
const DEFECTS := {
	"untwisted": 1e-7, # pairs untwisted too far at the plug: crosstalk
	"bad_crimp": 1e-6, # a contact in the plug barely touches
	"crushed": 2e-5, # flattened under a door or a chair leg
}
## At 10 Mbit/s the signal is slow enough that defects hurt this much less.
const DEFECT_FACTOR_10 := 0.01


## One direction of the cable.
class Lane:
	## When the next frame may start: the end of the last one plus the gap.
	var free_at := 0.0
	## When each frame still on the transmitter finishes going out.
	var sending: PackedFloat64Array = []
	## {at, frame} on their way to the other end, in order.
	var in_flight: Array[Dictionary] = []
	var last_at := 0.0
	var scheduled := false


var length_m := 2.0
## Names from [constant DEFECTS], as many as the cable has.
var defects: PackedStringArray = []
## Decides which frames get hit; seed it for repeatable runs.
var rng := RandomNumberGenerator.new()
var _ends: Array[WeakRef] = []
var _lanes: Array[Lane] = [Lane.new(), Lane.new()]
var _cut := false


func _init(a: AgoraNic, b: AgoraNic, length: float = 2.0) -> void:
	_ends = [weakref(a), weakref(b)]
	length_m = length
	rng.randomize()


static func now() -> float:
	return Time.get_ticks_usec() / 1000000.0


func end(k: int) -> AgoraNic:
	return _ends[k].get_ref() as AgoraNic


## The port at the other end from [param nic].
func other(nic: AgoraNic) -> AgoraNic:
	return end(1) if end(0) == nic else end(0)


## The speed both ends agree on: the slower card's.
var speed_mbps: int:
	get:
		var a := end(0)
		var b := end(1)
		if a == null or b == null:
			return 0
		return mini(a.speed_mbps, b.speed_mbps)


## Seconds [param frame_len] bytes (without FCS) hold the lane.
func wire_time(frame_len: int) -> float:
	return (PREAMBLE + maxi(MIN_FRAME, frame_len) + FCS) * 8.0 / (speed_mbps * 1000000.0)


## The chance that any one bit arrives wrong at [param speed] Mbit/s
## (the link's speed by default).
func bit_error_rate(speed: int = -1) -> float:
	if speed < 0:
		speed = speed_mbps
	var reach: float = REACH_M.get(speed, 100.0)
	var ber := BER_SOUND
	if length_m > reach:
		ber = minf(0.5, ber * pow(10.0, (length_m - reach) / DECADE_M))
	var factor := DEFECT_FACTOR_10 if speed <= 10 else 1.0
	for d in defects:
		ber += float(DEFECTS.get(d, 0.0)) * factor
	return minf(ber, 0.5)


## The chance that a frame of [param frame_len] bytes (without FCS) has at
## least one bit wrong, padding and FCS included.
func frame_error_chance(frame_len: int, speed: int = -1) -> float:
	var bits := (maxi(MIN_FRAME, frame_len) + FCS) * 8
	return 1.0 - exp(bits * log(1.0 - bit_error_rate(speed)))


func propagation() -> float:
	return length_m * NS_PER_METRE / 1000000000.0


## Frames [param from] has queued that haven't finished going out.
func queued(from: AgoraNic) -> int:
	var lane := _lanes[_lane_of(from)]
	var t := now()
	while not lane.sending.is_empty() and lane.sending[0] <= t:
		lane.sending.remove_at(0)
	return lane.sending.size()


func _lane_of(from: AgoraNic) -> int:
	return 0 if end(0) == from else 1


## Queues [param frame] from [param from]. [param extra] is the delay the
## cards add on top (seconds). The frame's "lat" grows by the time it takes
## to arrive, waiting in the queue included.
func send(from: AgoraNic, frame: Dictionary, extra: float = 0.0) -> void:
	if _cut or speed_mbps <= 0:
		return
	var k := _lane_of(from)
	var lane := _lanes[k]
	var t := now()
	var start := maxf(t, lane.free_at)
	var done := start + wire_time(AgoraNetStack.ETH_HLEN + int(frame.get("len", 0)))
	lane.free_at = done + IFG_BITS / (speed_mbps * 1000000.0)
	lane.sending.append(done)
	var at := maxf(done + propagation() + extra, lane.last_at)
	lane.last_at = at
	frame.lat = float(frame.get("lat", 0.0)) + (at - t) * 1000.0
	if rng.randf() < frame_error_chance(AgoraNetStack.ETH_HLEN + int(frame.get("len", 0))):
		frame.bad_fcs = true
	lane.in_flight.append({"at": at, "frame": frame})
	_schedule(k)


func _schedule(k: int) -> void:
	var lane := _lanes[k]
	if lane.scheduled or lane.in_flight.is_empty():
		return
	lane.scheduled = true
	var wait: float = lane.in_flight[0].at - now()
	var tree := Engine.get_main_loop() as SceneTree
	if wait <= EAGER or tree == null:
		_deliver.call_deferred(k)
	else:
		tree.create_timer(wait).timeout.connect(_deliver.bind(k))


func _deliver(k: int) -> void:
	var lane := _lanes[k]
	lane.scheduled = false
	var to := end(1 - k)
	var t := now()
	while not _cut and not lane.in_flight.is_empty() and lane.in_flight[0].at <= t + EAGER:
		var item: Dictionary = lane.in_flight.pop_front()
		if to:
			to._arrive(item.frame)
	_schedule(k)


## The cable is pulled out: what was on it is lost.
func cut() -> void:
	_cut = true
	for lane in _lanes:
		lane.in_flight.clear()
		lane.sending.clear()
