@tool
class_name AgoraCoaxSpec
extends Resource
## A thin coax bus (10BASE2) of an [AgoraWorldSpec]: its length, the cards
## on it with where their T-connectors are, and its terminators.

@export_range(0.5, 400.0, 0.5, "or_greater", "suffix:m") var length_m := 10.0
## The BNC cards on the bus, "box:port" ("pc:eth1").
@export var taps: Array[String] = []
## Where each tap's T-connector is, metres from end A (same order as taps).
@export var positions: Array[float] = []
@export var terminated_a := true
@export var terminated_b := true
