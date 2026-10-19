class_name AgoraCoax
extends AgoraSegment
## A thin coax bus (10BASE2): one cable running from card to card, each on a
## T-connector, with a 50 ohm terminator at both ends. The cards have no
## link detection: they always report carrier. Without both terminators the
## signal reflects off the open end and every frame collides with its own
## echo (excessive collisions, nothing gets through). Beyond 185 m the
## signal fades and frames arrive damaged.

## Longest segment the standard allows.
const MAX_LENGTH_M := 185.0
## Beyond it the error rate grows tenfold every this many metres.
const DECADE_M := 10.0
## Signal speed in coax: about 0.66 c.
const NS_PER_METRE := 5.0

## The T-connectors along the bus, in order: {nic, at_m} (metres from
## end A).
var taps: Array[Dictionary] = []
## The bus from end A to end B, in metres.
var length_m := 10.0
## A terminator on end A, on end B.
var terminators := [true, true]


func _init(p_length_m: float = 10.0) -> void:
	super()
	length_m = p_length_m


## Puts [param nic]'s T-connector on the bus [param at_m] metres from end A.
func attach(nic: AgoraNic, at_m: float) -> void:
	remove(nic)
	if nic.coax and nic.coax != self:
		nic.coax.remove(nic)
	nic.coax = self
	taps.append({"nic": nic, "at_m": clampf(at_m, 0.0, length_m)})
	taps.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.at_m < b.at_m)


## Takes [param nic]'s T-connector off the bus.
func remove(nic: AgoraNic) -> void:
	for k in range(taps.size() - 1, -1, -1):
		if taps[k].nic == nic:
			taps.remove_at(k)
	if nic.coax == self:
		nic.coax = null
	detach(nic)


func set_terminator(end: int, present: bool) -> void:
	terminators[end] = present


func stations() -> Array[AgoraNic]:
	var out: Array[AgoraNic] = []
	for t in taps:
		out.append(t.nic)
	return out


func propagation() -> float:
	return length_m * NS_PER_METRE / 1000000000.0


func bit_error_rate() -> float:
	var ber := AgoraCable.BER_SOUND
	if length_m > MAX_LENGTH_M:
		ber = minf(0.5, ber * pow(10.0, (length_m - MAX_LENGTH_M) / DECADE_M))
	return ber


func frame_error_chance(_from: AgoraNic, frame_len: int) -> float:
	var bits := (maxi(AgoraCable.MIN_FRAME, frame_len) + AgoraCable.FCS) * 8
	return 1.0 - exp(bits * log(1.0 - bit_error_rate()))


func reflects() -> bool:
	return not (terminators[0] and terminators[1])
