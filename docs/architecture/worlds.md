# Worlds

## AgoraWorld

`AgoraWorld` (`hardware/world.gd`) is a set of named boxes, the cables between
their ports (length, defects) and one clock.

- `create(name, template)`, `add(name, hw)`, `replace(name, hw)` (keeps the
  box's cables), `remove(name)`, `box(name)`, `names()`.
- `plug("pc:eth0", "gw:eth1", length, defects)`, `unplug("pc:eth0")`,
  `port(spec)`, `port_name(nic)`, `cables()`.
- `places`: box name -> the place it stands (`place_of`, `boxes_in`); boxes of
  one place are seen together in 3D. Saved with the world.
- `coax`: thin coax buses (`add_coax`), saved with their taps and terminators.
- `shelf(name)`: the media lying on a box's desk (CDs out of the drive, USB
  sticks), saved with the world.
- `start()` powers on the boxes that should be on; `stop()` cuts the power to
  all of them and remembers which were on.
- `save(path)` / `load_from(path)` keep everything in one file, disks
  included, with the power state of each box. On load the cables are plugged
  back and the boxes that were on boot again; nothing running survives, as
  after a power cut.

## World specs

A world is described by an `AgoraWorldSpec` resource (`hardware/world_spec.gd`,
a `.tres` edited in the inspector):

- `AgoraBoxSpec` boxes: name, template, place, extra cards, power, media, and the installed system
  (install, profile, hostname, root password, more installer options in
  `options`), plus `files`: a folder copied onto the box's disk (a `.modes`
  file in it gives special modes).
- `AgoraCableSpec` cables: `a` and `b` as `box:port`, length, defects.
- `AgoraCoaxSpec` thin coax buses: length, taps with their positions,
  terminators.
- The start time and the clock speed.

`build()` makes the world, or returns null with `error` set.

## The home world

`worlds/home.tres` is the demo's world, an evening in October 2003
(2003-10-18 21:30). Site files are under `worlds/home/<box>/`.

The PC and the router stand in the place `home` (a desk), the rest in
`lanlink` (the provider's rack).

| Box | Template | What |
|---|---|---|
| `pc` | pc | the player's PC: empty, with the install CD in the drive (`--preinstalled` gives a ready desktop) |
| `gw` | router | the home router, cabled to `pc:eth0` on LAN1 and to the provider on WAN |
| `isp` | server | LanLink's border box (ns1): 203.0.113.1 for customers with udhcpd, 198.51.100.1 on the backbone, ip_forward, dnsmasq as the net's DNS |
| `sw` | switch | the backbone switch |
| `www1` | server | www.lanlink.net, members.lanlink.net (~kevin and ~jenna with a counter CGI) |
| `www2` | server | www.penguinpit.org, www.byteslash.org (with a robots.txt-hidden /admin/) |
| `www3` | server | www.staticnoise.org, www.demozone.net, anonymous FTP |
| `search` | server | www.ferret.org, the Ferret search engine |
| `ping` | server | login.pingmsg.com and www.pingmsg.com (accounts 100001 Ping! Team, 100007 kevin, 100012 jenna; players get 100013 on) |
| `mirror` | server | ftp.agoraos.org, www.agoraos.org, mirror.lanlink.net: the package archive by FTP and HTTP |
| `mail` | server | mail.lanlink.net (198.51.100.25, the MX of lanlink.net): exim4 "internet", relaying for the DSL customers (203.0.113.0/24) only, popa3d; mailboxes kevin, jenna and user (password user) |

The site files are not Godot resources; an export preset needs `worlds/home/*`
in its non-resource filter.

## The demo front end

`main.gd` loads `user://worlds/home.agw`, or builds the world from the spec the
first time, brings disks saved by older versions up to date
(`AgoraInstaller.upgrade_vfs`), marks every box `interactive` and starts the
world. Each box has a screen: its monitor (`AgoraDisplayView`), or a terminal on
its serial port. The bar on top switches between them (Scroll Lock too), has
their power buttons and a "3D" button for the [3D view](hardware.md#the-3d-view).
The world is saved when the window closes; a PC saved by an older version
(`user://machines/local.agx`) is moved into the world on first start.
