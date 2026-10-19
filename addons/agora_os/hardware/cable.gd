class_name AgoraCable
extends RefCounted
## A twisted-pair cable between two network ports.
##
## When it is plugged in, or a card's settings or the cable change, the
## PHYs negotiate the link as IEEE 802.3 clause 28 does: two cards with
## autonegotiation take the best mode both advertise; a card facing one
## with fixed settings detects the speed and assumes half duplex. A speed
## the cable can't carry cleanly enough is skipped for the next lower one
## (a long cable comes up at 10 Mbit/s), and if the autonegotiation pages
## themselves get garbled both ends fall back to 10 Mbit/s, half duplex.
##
## Each direction is a lane with its own transmit queue: a frame holds the
## lane for its time on the wire (preamble and SFD, the frame padded to 60
## bytes, FCS) at the link speed, and the next one may start after the
## interframe gap. Then the signal travels the length of the cable. So a
## 10 Mbit/s link really carries about 10 Mbit/s, bursts wait their turn,
## and frames arrive in the order they were sent.
##
## A half-duplex end shares the wire: it waits while the other end sends
## (carrier sense), and if both start at once they collide, jam and back
## off (CSMA/CD with binary exponential backoff). Against a full-duplex end
## (a duplex mismatch) the other side sends whenever it likes, so the
## half-duplex end sees collisions, late ones too, that throw its frames
## away, and the full-duplex end receives the fragments as runts and CRC
## errors.
##
## A cable also has a bit error rate, from its length beyond what the
## link speed allows and from defects. Each frame is checked against it on
## the way: a frame hit by an error arrives with a bad FCS and the
## receiving card throws it away.
##
## Transmissions run in virtual time: a frame starts when its lane is free,
## whatever the engine's frame rate. Times are real seconds, like the
## stack's other network timers.

## Preamble (7 bytes) and start frame delimiter (1).
const PREAMBLE := 8
const FCS := 4
## Shortest frame without its FCS; shorter ones are padded.
const MIN_FRAME := 60
## Interframe gap: 96 bit times between the end of one frame and the start
## of the next. It delays the next frame, not this one.
const IFG_BITS := 96
## Collision window and backoff unit: 512 bit times. A collision after it
## is a late one.
const SLOT_BITS := 512
## A station that detects a collision sends a 32-bit jam signal.
const JAM_BITS := 32
## Tries before a frame is given up for excessive collisions.
const MAX_ATTEMPTS := 16
## Backoff stops doubling after this many collisions.
const BACKOFF_LIMIT := 10
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
## A receiver can't hold the link at a speed with this bit error rate.
const LINK_BER := 1e-3
## The autonegotiation pages (sent as 10 Mbit/s link pulses) get garbled at
## this error rate, and the cards fall back to parallel detection.
const PAGE_BER := 1e-4


## One direction of the cable.
class Lane:
	var full_duplex := true
	## Frames waiting to start: {frame, sent, extra, ready, tries}.
	var queue: Array[Dictionary] = []
	## The frame on the wire or the last one: {start, done, item, entry}.
	var tx := {}
	## When the next frame may start: the end of the last one plus the gap.
	var free_at := 0.0
	## Started frames on their way, in order:
	## {at, frame, done, final, lost}. "final" is when nothing can change it.
	var in_flight: Array[Dictionary] = []
	var last_at := 0.0
	## When the pending timer fires, INF without one.
	var timer_at := INF


var length_m := 2.0:
	set(v):
		length_m = v
		negotiate()
## Names from [constant DEFECTS], as many as the cable has.
var defects: PackedStringArray = []:
	set(v):
		defects = v
		negotiate()
## Decides which frames get hit and the backoff; seed it for repeatable runs.
var rng := RandomNumberGenerator.new()

## The negotiated link: is it up, at what speed, each end's duplex and
## whether each end used autonegotiation for it.
var link_up := false
var speed_mbps := 0
var _duplex := ["", ""]
var _autoneg_done := [false, false]

var _ends: Array[WeakRef] = []
var _lanes: Array[Lane] = [Lane.new(), Lane.new()]
var _cut := false


func _init(a: AgoraNic, b: AgoraNic, length: float = 2.0) -> void:
	_ends = [weakref(a), weakref(b)]
	rng.randomize()
	length_m = length


static func now() -> float:
	return Time.get_ticks_usec() / 1000000.0


func end(k: int) -> AgoraNic:
	return _ends[k].get_ref() as AgoraNic if k < _ends.size() else null


## The port at the other end from [param nic].
func other(nic: AgoraNic) -> AgoraNic:
	return end(1) if end(0) == nic else end(0)


func _end_of(nic: AgoraNic) -> int:
	return 0 if end(0) == nic else 1


## "full" or "half" for [param nic]'s end of the link.
func duplex_of(nic: AgoraNic) -> String:
	return _duplex[_end_of(nic)]


## True if [param nic] got its mode from autonegotiation with the other
## end, so it knows what that end advertised.
func negotiated(nic: AgoraNic) -> bool:
	return _autoneg_done[_end_of(nic)]


# --- negotiation --------------------------------------------------------------

## Works out the link again; the cards see it go down and come back up if
## anything changed, or always with [param restart] (ethtool -r).
func negotiate(restart: bool = false) -> void:
	var a := end(0)
	var b := end(1)
	if a == null or b == null or a.cable != self or b.cable != self:
		return # still being plugged in
	var result := _negotiate(a, b) if not _cut else {"up": false}
	var was := [link_up, speed_mbps, _duplex.duplicate()]
	link_up = result.up
	speed_mbps = result.get("speed", 0)
	_duplex = result.get("duplex", ["", ""])
	_autoneg_done = result.get("autoneg", [false, false])
	for k in 2:
		_lanes[k].full_duplex = _duplex[k] != "half"
	if was == [link_up, speed_mbps, _duplex] and not (restart and link_up):
		return
	if was[0]:
		for lane in _lanes:
			lane.queue.clear()
			lane.in_flight.clear()
			lane.tx = {}
		a.link_changed.emit(false)
		b.link_changed.emit(false)
	if link_up:
		a.link_changed.emit(true)
		b.link_changed.emit(true)


func _negotiate(a: AgoraNic, b: AgoraNic) -> Dictionary:
	if a.segment and b.segment:
		return {"up": false} # hubs aren't cascaded in this simulation
	var pages_ok := bit_error_rate(10) < PAGE_BER
	if a.autoneg and b.autoneg and pages_ok:
		# Both advertise; the best common mode wins, falling back while the
		# cable can't carry it.
		var common := a.advertising & b.advertising
		for k in range(AgoraNic.MODES.size() - 1, -1, -1):
			var mode: Array = AgoraNic.MODES[k]
			if common & mode[3] and _carries(mode[1]):
				return {"up": true, "speed": mode[1], "duplex": [mode[2], mode[2]], "autoneg": [true, true]}
		return {"up": false}
	# Parallel detection: an autonegotiating end recognises the other's
	# speed from its signal but can't learn its duplex, so it takes half.
	var speed_a := _sensed_speed(a, b, pages_ok)
	var speed_b := _sensed_speed(b, a, pages_ok)
	if speed_a == 0 or speed_a != speed_b or not _carries(speed_a):
		return {"up": false}
	var dup_a := a.forced_duplex if not a.autoneg else "half"
	var dup_b := b.forced_duplex if not b.autoneg else "half"
	return {"up": true, "speed": speed_a, "duplex": [dup_a, dup_b], "autoneg": [false, false]}


## The speed [param nic] runs at against [param other] without a common
## autonegotiation.
func _sensed_speed(nic: AgoraNic, other_nic: AgoraNic, pages_ok: bool) -> int:
	if not nic.autoneg:
		return nic.forced_speed
	if other_nic.autoneg:
		# Garbled pages on both sides: what gets through looks like 10BASE-T
		# link pulses.
		return 10 if not pages_ok and nic.supported_mask() & 0x003 else 0
	# It detects the other's fixed speed if it can run at it at all;
	# gigabit can't be detected this way.
	var s := other_nic.forced_speed
	if s >= 1000:
		return 0
	for mode: Array in AgoraNic.MODES:
		if mode[1] == s and nic.supported_mask() & mode[3]:
			return s
	return 0


func _carries(speed: int) -> bool:
	return bit_error_rate(speed) < LINK_BER


# --- the signal ----------------------------------------------------------------

## Seconds [param frame_len] bytes (without FCS) hold the lane.
func wire_time(frame_len: int) -> float:
	return (PREAMBLE + maxi(MIN_FRAME, frame_len) + FCS) * 8.0 / (speed_mbps * 1000000.0)


func _bit_time() -> float:
	return 1.0 / (speed_mbps * 1000000.0)


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


# --- sending -------------------------------------------------------------------

## Frames [param from] has queued that haven't finished going out.
func queued(from: AgoraNic) -> int:
	var hub := other(from).segment if other(from) else null
	if hub:
		return hub.queued(from)
	var lane := _lanes[_end_of(from)]
	var t := now()
	var n := lane.queue.size()
	for e in lane.in_flight:
		if e.done > t and not e.get("fragment", false):
			n += 1
	return n


## Queues [param frame] from [param from]. [param extra] is the delay the
## cards add on top (seconds). The frame's "lat" grows by the time it takes
## to arrive, waiting in the queue included.
func send(from: AgoraNic, frame: Dictionary, extra: float = 0.0) -> void:
	if _cut or not link_up:
		return
	var hub := other(from).segment
	if hub:
		# Into a hub port: the hub's collision domain carries it.
		hub.send(from, frame, extra)
		return
	var k := _end_of(from)
	var t := now()
	_advance(t)
	_lanes[k].queue.append({"frame": frame, "sent": t, "extra": extra, "ready": t, "tries": 0})
	_advance(t)
	_schedule(k)
	_schedule(1 - k)


## Two full-duplex ends never meet on the wire, so their frames can be
## laid out ahead. Otherwise starts are only decided once their time comes.
func _independent() -> bool:
	return _lanes[0].full_duplex and _lanes[1].full_duplex


## Starts the frames whose turn has come by [param t].
func _advance(t: float) -> void:
	while true:
		var best := -1
		var best_at := INF
		for k in 2:
			var lane := _lanes[k]
			if lane.queue.is_empty():
				continue
			var s := maxf(lane.free_at, lane.queue[0].ready)
			if s < best_at:
				best_at = s
				best = k
		if best < 0 or (best_at > t and not _independent()):
			return
		_start(best, best_at)


## Lane [param k] wants to start its next frame at [param s].
func _start(k: int, s: float) -> void:
	var lane := _lanes[k]
	var o := _lanes[1 - k]
	var prop := propagation()
	var otx := o.tx
	var o_sending: bool = not otx.is_empty() and otx.start <= s and s < otx.done
	if not lane.full_duplex and o_sending and otx.start + prop <= s:
		# Carrier sense: the other end is sending, wait for it to finish.
		lane.free_at = otx.done + prop + IFG_BITS * _bit_time()
		if lane.queue[0].get("deferred", false) == false:
			lane.queue[0].deferred = true
			end(k).counters.tx_deferred += 1
		return
	var item: Dictionary = lane.queue.pop_front()
	var frame: Dictionary = item.frame
	var len := AgoraNetStack.ETH_HLEN + int(frame.get("len", 0))
	var done := s + wire_time(len)
	var entry := {
		"at": maxf(done + prop + float(item.extra), lane.last_at), "frame": frame,
		"sent": item.sent, "done": done, "final": s if lane.full_duplex else done, "lost": false,
	}
	if rng.randf() < frame_error_chance(len):
		frame.bad_fcs = true
	lane.last_at = entry.at
	lane.tx = {"start": s, "done": done, "item": item, "entry": entry}
	lane.free_at = done + IFG_BITS * _bit_time()
	lane.in_flight.append(entry)
	if o_sending:
		if not o.full_duplex:
			# The other end is half duplex and hears us while it sends: a
			# collision for it, and it drops what it receives meanwhile.
			entry.lost = true
			_collide(1 - k, s + prop - otx.start)
		if not lane.full_duplex:
			# We started before its signal reached us: we collide too.
			otx.entry.lost = true
			_collide(k, 0.0)
	if item.tries > 0:
		var c := end(k).counters
		if item.tries == 1:
			c.tx_single_collisions += 1
		else:
			c.tx_multi_collisions += 1


## Lane [param k]'s frame on the wire meets a collision [param offset]
## seconds after it started. The station jams, and retries after a backoff
## if the collision came in time; a late collision loses the frame.
func _collide(k: int, offset: float) -> void:
	var lane := _lanes[k]
	var tx := lane.tx
	var nic := end(k)
	var bit := _bit_time()
	var stop: float = tx.start + offset + JAM_BITS * bit
	var late := offset > SLOT_BITS * bit
	var entry: Dictionary = tx.entry
	# What the other end gets: a fragment, short (a runt) unless the
	# collision was late, with a bad FCS either way.
	entry.frame = {"runt": not late, "bad_fcs": late, "len": 0}
	entry.fragment = true
	entry.done = stop
	entry.final = stop
	entry.at = stop + propagation()
	tx.done = stop
	lane.free_at = stop + IFG_BITS * bit
	var item: Dictionary = tx.item
	item.tries += 1
	if late:
		nic.counters.tx_late_collisions += 1
		nic._tx_event("late_collision")
		return
	nic._tx_event("collision")
	if item.tries >= MAX_ATTEMPTS:
		nic.counters.tx_excessive_collisions += 1
		nic._tx_event("excessive_collisions")
		return
	var slots := rng.randi_range(0, (1 << mini(item.tries, BACKOFF_LIMIT)) - 1)
	item.ready = lane.free_at + slots * SLOT_BITS * bit
	lane.queue.push_front(item)


func _schedule(k: int) -> void:
	var lane := _lanes[k]
	var due := INF
	if not lane.in_flight.is_empty():
		var head := lane.in_flight[0]
		due = maxf(head.at, head.final)
	if not lane.queue.is_empty():
		due = minf(due, maxf(lane.free_at, lane.queue[0].ready))
	if due >= lane.timer_at:
		return # an earlier timer is already set, or nothing to do
	lane.timer_at = due
	var wait := due - now()
	var tree := Engine.get_main_loop() as SceneTree
	if wait <= EAGER or tree == null:
		_deliver.call_deferred(k)
	else:
		tree.create_timer(wait).timeout.connect(_deliver.bind(k))


func _deliver(k: int) -> void:
	var lane := _lanes[k]
	lane.timer_at = INF
	if _cut:
		return
	var t := now()
	_advance(t)
	var to := end(1 - k)
	while not lane.in_flight.is_empty():
		var head := lane.in_flight[0]
		if head.at > t + EAGER or head.final > t:
			break
		lane.in_flight.pop_front()
		if head.lost or to == null:
			continue
		var frame: Dictionary = head.frame
		if not head.get("fragment", false):
			frame.lat = float(frame.get("lat", 0.0)) + (head.at - head.sent) * 1000.0
		to._arrive(frame)
	_schedule(k)
	_schedule(1 - k)


## The cable is pulled out: what was on it is lost.
func cut() -> void:
	_cut = true
	link_up = false
	for lane in _lanes:
		lane.in_flight.clear()
		lane.queue.clear()
