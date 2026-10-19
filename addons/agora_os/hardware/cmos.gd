class_name AgoraCmos
extends RefCounted
## The BIOS settings of a PC, kept in its battery-backed CMOS memory and
## changed in Setup (see [AgoraBios]). The boot order itself is
## [member AgoraHardware.boot_order].
##
## Clearing the CMOS (the jumper on the board, a flat battery) brings back
## the defaults, passwords included, and the next POST reports "CMOS
## checksum error - Defaults loaded".

const DEFAULT_BOOT_ORDER: PackedStringArray = ["cdrom", "usb", "hdd"]

## A shorter memory test, and no pause for "Press DEL".
var quick_post := true
## NumLock is switched on at boot.
var numlock := true
## The network chips on the board. Off, the kernel finds no network card.
var onboard_lan := true
## "Setup": the passwords guard Setup only. "System": they are asked at
## every boot too.
var security := "Setup"
var supervisor_password := ""
var user_password := ""
## How far the CMOS clock is ahead of the world's clock, in seconds. Setup
## changes it by setting the date and time; the kernel starts from it.
var rtc_offset := 0.0
## False after the CMOS lost its contents: the next POST says so.
var valid := true


## Factory settings. [param failsafe] slows POST down, as "Load Fail-Safe
## Defaults" does.
func load_defaults(failsafe: bool = false) -> void:
	quick_post = not failsafe
	numlock = true
	onboard_lan = true
	security = "Setup"


## What the clear-CMOS jumper does: everything back to the defaults,
## passwords and the clock too.
func clear(hw: AgoraHardware = null) -> void:
	load_defaults()
	supervisor_password = ""
	user_password = ""
	rtc_offset = 0.0
	valid = false
	if hw:
		hw.boot_order = DEFAULT_BOOT_ORDER.duplicate()


func copy() -> AgoraCmos:
	var c := AgoraCmos.new()
	c.deserialize(serialize())
	return c


func serialize() -> Dictionary:
	return {
		"quick_post": quick_post, "numlock": numlock, "onboard_lan": onboard_lan, "security": security,
		"supervisor": supervisor_password, "user": user_password, "rtc_offset": rtc_offset, "valid": valid,
	}


func deserialize(data: Dictionary) -> void:
	quick_post = data.get("quick_post", true)
	numlock = data.get("numlock", true)
	onboard_lan = data.get("onboard_lan", true)
	security = data.get("security", "Setup")
	supervisor_password = data.get("supervisor", "")
	user_password = data.get("user", "")
	rtc_offset = data.get("rtc_offset", 0.0)
	valid = data.get("valid", true)
