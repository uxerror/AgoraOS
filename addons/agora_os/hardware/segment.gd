class_name AgoraSegment
extends RefCounted
## A shared Ethernet medium: one collision domain at 10 Mbit/s, as behind a
## hub (10BASE-T) or along a thin coax bus (10BASE2). Every station hears
## every other one.
##
## A station waits while it hears another (carrier sense); two that start
## within the time the signal takes to cross the segment collide, jam and
## back off (CSMA/CD with binary exponential backoff, 16 tries). A frame
## that gets through reaches every other station at once; a collision
## leaves them a fragment, a runt or, after the slot time, a frame with a
## bad FCS. A station forced to full duplex (a duplex mismatch with a hub)
## neither listens nor notices collisions: its frames are simply lost when
## they meet others.
##
## Subclasses say who the stations are ([method stations]), how far the
## signal goes ([method propagation]) and how clean it is
## ([method frame_error_chance], [method reflects]).

const SPEED := 10
## The segment's frames are handed over at the end of the engine frame when
## due this soon.
const EAGER := 0.002


## A station's state on the segment.
class Station:
	var nic: AgoraNic
	## Frames waiting: {frame, sent, extra, ready, tries, deferred}.
	var queue: Array[Dictionary] = []
	## The frame on the wire: {start, done, item, entry}, or {}.
	var tx := {}
	var free_at := 0.0


## The stations by NIC, kept while they are attached.
var _stations := {}
## Started frames on their way: {at, final, frame, from, sent, lost,
## fragment}, in start order.
var _in_flight: Array[Dictionary] = []
var _timer_at := INF
var rng := RandomNumberGenerator.new()


func _init() -> void:
	rng.randomize()


# --- what subclasses say -------------------------------------------------------

## The NICs on the segment now.
func stations() -> Array[AgoraNic]:
	return []


## Whether [param nic] runs full duplex here (it then neither listens nor
## backs off).
func full_duplex(_nic: AgoraNic) -> bool:
	return false


## Seconds the signal takes across the segment, end to end.
func propagation() -> float:
	return 0.0


## The chance that a frame of [param frame_len] bytes from [param from]
## arrives damaged.
func frame_error_chance(_from: AgoraNic, _frame_len: int) -> float:
	return 0.0


## True when every transmission comes back as a reflection (an open end):
## it collides with itself.
func reflects() -> bool:
	return false


## False while the segment can't carry anything (a hub without power).
func working() -> bool:
	return true


# --- sending -------------------------------------------------------------------

static func now() -> float:
	return Time.get_ticks_usec() / 1000000.0


static func wire_time(frame_len: int) -> float:
	return (AgoraCable.PREAMBLE + maxi(AgoraCable.MIN_FRAME, frame_len) + AgoraCable.FCS) * 8.0 / (SPEED * 1000000.0)


static func bit_time() -> float:
	return 1.0 / (SPEED * 1000000.0)


func _station(nic: AgoraNic) -> Station:
	if not _stations.has(nic):
		var s := Station.new()
		s.nic = nic
		_stations[nic] = s
	return _stations[nic]


## Frames [param from] has waiting or on the wire.
func queued(from: AgoraNic) -> int:
	if not _stations.has(from):
		return 0
	var s: Station = _stations[from]
	return s.queue.size() + (1 if not s.tx.is_empty() and s.tx.done > now() else 0)


## Queues [param frame] from [param from], with the card's own delay
## [param extra] on top.
func send(from: AgoraNic, frame: Dictionary, extra: float = 0.0) -> void:
	if not working():
		return
	var t := now()
	_advance(t)
	var s := _station(from)
	s.queue.append({"frame": frame, "sent": t, "extra": extra, "ready": t, "tries": 0})
	_advance(t)
	_schedule()


## Forgets a station that left (its cable was pulled): its frames are lost.
func detach(nic: AgoraNic) -> void:
	_stations.erase(nic)
	_in_flight = _in_flight.filter(func(e: Dictionary) -> bool: return e.from != nic)


func _advance(t: float) -> void:
	while true:
		var best: Station = null
		var best_at := INF
		for s: Station in _stations.values():
			if s.queue.is_empty():
				continue
			var at := maxf(s.free_at, s.queue[0].ready)
			if at < best_at:
				best_at = at
				best = s
		if best == null or best_at > t:
			return
		_start(best, best_at)


## [param s] wants to start its next frame at [param at].
func _start(s: Station, at: float) -> void:
	var prop := propagation()
	var bit := bit_time()
	var full := full_duplex(s.nic)
	var others: Array[Station] = []
	for o: Station in _stations.values():
		if o != s and not o.tx.is_empty() and o.tx.start < at + prop and at < o.tx.done + prop:
			others.append(o)
	if not full:
		# Carrier sense: another's signal has reached us and isn't over.
		var heard := 0.0
		for o in others:
			# A signal arriving just as we start is not heard in time.
			if o.tx.start + prop < at:
				heard = maxf(heard, o.tx.done + prop)
		if heard > 0.0:
			s.free_at = heard + AgoraCable.IFG_BITS * bit
			if not s.queue[0].get("deferred", false):
				s.queue[0].deferred = true
				s.nic.counters.tx_deferred += 1
			return
	var item: Dictionary = s.queue.pop_front()
	var frame: Dictionary = item.frame
	var len := AgoraNetStack.ETH_HLEN + int(frame.get("len", 0))
	var done := at + wire_time(len)
	if rng.randf() < frame_error_chance(s.nic, len):
		frame.bad_fcs = true
	var entry := {"at": done + prop + float(item.extra), "final": done + prop, "frame": frame, "from": s.nic, "sent": item.sent, "lost": false}
	s.tx = {"start": at, "done": done, "item": item, "entry": entry}
	s.free_at = done + AgoraCable.IFG_BITS * bit
	_in_flight.append(entry)
	if item.tries > 0:
		if item.tries == 1:
			s.nic.counters.tx_single_collisions += 1
		else:
			s.nic.counters.tx_multi_collisions += 1
	# Whoever is still on the wire meets this frame: a collision for all.
	var hit: Array[Station] = []
	for o in others:
		if o.tx.done > at:
			hit.append(o)
	if reflects():
		# The open end sends the frame back: it collides with itself
		# after the round trip.
		_collide(s, 2.0 * prop + AgoraCable.JAM_BITS * bit)
		return
	if hit.is_empty():
		return
	_collide(s, 0.0)
	for o in hit:
		_collide(o, at + prop - o.tx.start)


## [param s]'s frame meets a collision [param offset] seconds into it. A
## half-duplex station jams and backs off (a late collision loses the
## frame); a full-duplex one goes on, not knowing, and the frame is lost.
func _collide(s: Station, offset: float) -> void:
	var tx := s.tx
	if tx.is_empty() or tx.entry.get("fragment", false):
		return
	var bit := bit_time()
	var late := offset > AgoraCable.SLOT_BITS * bit
	var entry: Dictionary = tx.entry
	entry.fragment = true
	entry.frame = {"runt": not late, "bad_fcs": late, "len": 0}
	var item: Dictionary = tx.item
	if full_duplex(s.nic):
		return
	var stop: float = tx.start + offset + AgoraCable.JAM_BITS * bit
	tx.done = stop
	entry.at = stop + propagation()
	entry.final = entry.at
	s.free_at = stop + AgoraCable.IFG_BITS * bit
	item.tries += 1
	if late:
		s.nic.counters.tx_late_collisions += 1
		s.nic._tx_event("late_collision")
		return
	s.nic._tx_event("collision")
	if item.tries >= AgoraCable.MAX_ATTEMPTS:
		s.nic.counters.tx_excessive_collisions += 1
		s.nic._tx_event("excessive_collisions")
		return
	var slots := rng.randi_range(0, (1 << mini(item.tries, AgoraCable.BACKOFF_LIMIT)) - 1)
	item.ready = s.free_at + slots * AgoraCable.SLOT_BITS * bit
	s.queue.push_front(item)


func _schedule() -> void:
	var due := INF
	for e in _in_flight:
		due = minf(due, maxf(e.at, e.final))
	for s: Station in _stations.values():
		if not s.queue.is_empty():
			due = minf(due, maxf(s.free_at, s.queue[0].ready))
	if due >= _timer_at:
		return
	_timer_at = due
	var wait := due - now()
	var tree := Engine.get_main_loop() as SceneTree
	if wait <= EAGER or tree == null:
		_deliver.call_deferred()
	else:
		tree.create_timer(wait).timeout.connect(_deliver)


func _deliver() -> void:
	_timer_at = INF
	var t := now()
	_advance(t)
	var present := stations()
	while not _in_flight.is_empty():
		var head := _in_flight[0]
		if head.at > t + EAGER or head.final > t:
			break
		_in_flight.pop_front()
		if head.lost or not working():
			continue
		var frame: Dictionary = head.frame
		if not head.get("fragment", false):
			frame.lat = float(frame.get("lat", 0.0)) + (head.at - head.sent) * 1000.0
		for nic in present:
			if nic != head.from:
				nic._arrive(frame.duplicate(true))
	_schedule()
