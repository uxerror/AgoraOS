@tool
class_name AgoraCableSpec
extends Resource
## A cable of an [AgoraWorldSpec] between two ports, named "box:port".

@export var a := ""
@export var b := ""
@export_range(0.1, 300.0, 0.1, "or_greater", "suffix:m") var length_m := 2.0
## See [constant AgoraCable.DEFECTS].
@export_enum("untwisted", "bad_crimp", "crushed") var defects: Array[String] = []
