class_name AgoraHub
extends AgoraSegment
## The inside of a 10BASE-T hub: a repeater that makes the stations on its
## ports one collision domain. Its ports don't negotiate; they send 10 Mbit/s
## link pulses, so a card that autonegotiates detects 10 Mbit/s and takes
## half duplex. A card forced to full duplex gets a link too, and a duplex
## mismatch.

## A repeater's own delay, in seconds (a few bit times).
const REPEATER_DELAY := 0.0000005

var _hw: WeakRef


func _init(hw: AgoraHardware) -> void:
	super()
	_hw = weakref(hw)


func hardware() -> AgoraHardware:
	return _hw.get_ref() as AgoraHardware


## The cards at the other end of the ports' cables.
func stations() -> Array[AgoraNic]:
	var out: Array[AgoraNic] = []
	var hw := hardware()
	if hw == null:
		return out
	for port in hw.nics:
		if port.cable and port.cable.link_up and port.peer:
			out.append(port.peer)
	return out


func full_duplex(nic: AgoraNic) -> bool:
	return nic.duplex == "full"


func propagation() -> float:
	# The two longest drops, through the repeater.
	var lengths: Array[float] = []
	var hw := hardware()
	if hw:
		for port in hw.nics:
			if port.cable:
				lengths.append(port.cable.length_m)
	lengths.sort()
	var path := 0.0
	for k in mini(2, lengths.size()):
		path += lengths[lengths.size() - 1 - k]
	return path * AgoraCable.NS_PER_METRE / 1000000000.0 + REPEATER_DELAY


func frame_error_chance(from: AgoraNic, frame_len: int) -> float:
	return from.cable.frame_error_chance(frame_len, SPEED) if from.cable else 0.0


func _repeated(_from: AgoraNic) -> void:
	var hw := hardware()
	if hw:
		for port in hw.nics:
			if port.cable and port.cable.link_up:
				port.frames += 1


func working() -> bool:
	var hw := hardware()
	return hw != null and hw.power == AgoraHardware.Power.ON
