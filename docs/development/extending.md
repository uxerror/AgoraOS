# Extending AgoraOS (for a game)

## Machines and worlds

```gdscript
# A ready machine on a headless virtual box (booted at once).
var m := AgoraMachine.create("server", {
	"profile": "server", "root_password": "toor",
	"users": [{"name": "neo", "password": "matrix", "groups": ["sudo"]}],
	"network": {"eth0": {"method": "static", "address": "10.0.0.7", "netmask": "255.255.255.0"}},
})

# Or real boxes in a world, cabled by port name.
var w := AgoraWorld.new()
var pc := w.create("pc", "pc")
pc.insert(AgoraMedia.installer(false, w.clock))
var gw := w.create("gw", "router")
AgoraInstaller.install_disk(gw.disks[0], "gw", {"profile": "router", "root_password": "admin"}, w.clock)
w.plug("pc:eth0", "gw:eth1", 3.0)
w.start()
```

Players' homes on the provider of the home world:

```gdscript
var home := world.add_home("neo", {"password": "matrix"})
# {pc: "home-neo-pc", gw: "home-neo-gw", port: "dsl:port3"}; mail is neo@lanlink.net
world.remove_home("neo")
```

Prefer a world spec (`AgoraWorldSpec`, a `.tres`) for authored worlds; see
[worlds](../architecture/worlds.md). Set `hardware.interactive = true` on boxes
a player sits at, so the BIOS and GRUB wait for keys.

To show a box: `AgoraDisplayView.attach(hw.display, hw.console)` for a monitor,
`AgoraTermView.attach(hw.serial)` for a serial console,
`AgoraHardwareView3D.show_box(hw, {...})` for the box in 3D.

## Programs

```gdscript
extends AgoraProgram

func summary() -> String:
	return "say hello"

func main(p: AgoraProcess) -> int:
	p.outln("hello, %s" % p.user_name())
	return 0
```

Register it and put its binary on a machine:

```gdscript
AgoraPrograms.register("hello", preload("res://game/hello.gd"), "/usr/bin/hello")
AgoraPackages.write_binary(m.vfs, "hello", "/usr/bin/hello")
```

For programs that ship with the distribution, add them to
`kernel/programs.gd` and a package in `system/distro.gd` instead.

Windowed programs extend `AgoraGuiProgram`, call `open_window(p, control,
opts)` and then `await win.closed`.

## Devices, time, files

- A device: `m.dev.add_device("modem", reader, writer)` (reader returns
  `PackedByteArray`, writer takes one).
- Game time: `clock.set_time(unix)`, `clock.set_speed(x)` on the world's clock;
  every box follows it.
- A real directory inside a machine: `m.mount_host("user://share", "/mnt/share",
  "neo")`. Not saved with the image; mount it again after loading.
- Files onto a box's disk before it boots: `AgoraBoxSpec.files` in a spec, or
  `AgoraInstaller.target_vfs(disk, clock)` and write.
