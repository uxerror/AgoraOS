@tool
class_name AgoraBoxSpec
extends Resource
## One box of an [AgoraWorldSpec]: which hardware, what is installed on its
## first disk and what media are inserted.

enum Media {
	INSTALL_CD, ## the AgoraOS install CD
	INSTALL_USB, ## the same on a USB stick
	USB_STICK, ## an empty USB stick
}

## The box's name in the world, used in cable ports ("pc:eth0").
@export var name := "pc"
@export_enum("pc", "server", "router", "virtual") var template := "pc"
## Switched on when the world starts.
@export var power := true
@export var media: Array[Media] = []

@export_group("Installed system")
## Put a system on the first disk; otherwise the disk is empty.
@export var install := false
@export_enum("desktop", "server", "router") var profile := "desktop"
## Empty: the box's name.
@export var hostname := ""
@export var root_password := ""
## More installer options: "users" ([{name, password, groups}]),
## "network" ({eth0: {method, address, netmask, gateway}}), "nameservers",
## "init" ("systemd" or "sysvinit"), "packages", "motd".
@export var options := {}


## The installer's options for this box.
func install_options() -> Dictionary:
	var opts := options.duplicate(true)
	opts.profile = profile
	if not root_password.is_empty():
		opts.root_password = root_password
	return opts
