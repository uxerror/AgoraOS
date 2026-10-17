class_name AgoraCapture
extends RefCounted
## A packet socket (AF_PACKET) for capturing, as tcpdump opens one: it gets
## a copy of every frame an interface receives or sends ("any" for all of
## them). A promiscuous capture makes the card accept frames for other
## addresses too.

## Interface name, or "any".
var device := ""
var promisc := true
## "in", "out" or "inout" (tcpdump -Q).
var direction := "inout"
## {time, iface, dir ("in"/"out"), otherhost, frame}, oldest first.
var inbox: Array[Dictionary] = []
var pid := 0
var _stack: WeakRef


func close() -> void:
	var net := _stack.get_ref() as AgoraNetStack if _stack else null
	if net:
		net.close_capture(self)
