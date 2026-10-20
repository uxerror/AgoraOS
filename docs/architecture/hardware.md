# Hardware

`AgoraHardware` (`hardware/hardware.gd`) is the box the system runs on: CPU,
memory, disks, network ports, an optional monitor, a serial console, its CMOS
and power. It outlives the kernels that run on it.

## Templates

| Template | What | Disk | Ports | Screen |
|---|---|---|---|---|
| `pc` | AgoraTech Desktop PC 2400, P4-class 2.4 GHz, 512 MB | ATA 40 GB, CD-ROM | `eth0` (e100, 100 Mbit/s) | monitor and `ttyS0` |
| `server` | AgoraTech Rack Server R1, 2 x 2.8 GHz, 2 GB | SCSI 73 GB, CD-ROM | `eth0`, `eth1` (e1000) | monitor and `ttyS0` |
| `router` | Agora Networks WR-54, MIPS 200 MHz, 16 MB | 4 MB flash | WAN, LAN1-4 (b44) | `ttyS0` only |
| `switch` | FS-108, unmanaged, no CPU or OS | none | `port1`-`port8` | none |
| `hub` | HB-108, a 10BASE-T repeater, no CPU or OS | none | `port1`-`port8` | none |
| `virtual` | headless PC for tests and `AgoraMachine.create` | 8 GB | `eth0` (e1000) | `ttyS0` |

Names and figures are fictional but true to the era. A switch learns which
address is behind which port and forwards frames in the hardware itself; a
hub repeats everything to everyone (see [shared media](#shared-media-hubs-and-thin-coax)).

More cards go into free PCI slots with `add_card(driver)` (`AgoraBoxSpec.cards`
in a spec): `e100`, `e1000`, or `ne2k-pci`, an NE2000 clone with a BNC socket
for thin coax.

## Disks and media

An `AgoraDisk` is a hard disk, CD-ROM, USB stick or flash. It holds one
`AgoraMemFs` (none until `mkfs`) and a boot sector (`boot_sector`: `grub`,
`syslinux` on the install stick, or empty). Device names follow Linux: `sda`
with `sda1`, `sdb1` for a USB stick, `sr0`, `mtdblock0`. `insert` and `eject`
handle removable media (`AgoraMedia.installer()` is the install CD or stick).
Capacity is shown (`lsblk`), not enforced.

## Network cards and cables

`AgoraNic` has a MAC address, a chip (`driver`: `e100`, `e1000`, `b44`), PHY
settings (autoneg, advertised modes, forced speed and duplex, reset when the
kernel's driver loads) and frame counters. `AgoraCable` joins two cards; a
world plugs cables by port name (`world.plug("pc:eth0", "gw:eth1", length)`).

- **Timing.** One transmit queue per direction. A frame holds the line for
  (8 preamble+SFD + frame padded to 60 + 4 FCS) x 8 / speed; the 96-bit
  interframe gap delays the next one; the signal travels about 5 ns per metre.
  Frames arrive in order, carrying the delay they picked up, which `ping`
  reports. `txqueuelen` bounds the queue; what doesn't fit is dropped.
- **Bit errors.** A sound cable has a BER of 1e-12; beyond its reach (100 m at
  100 Mbit/s, 150 m at 10) it grows tenfold every 10 m. Defects add to it
  (`untwisted` 1e-7, `bad_crimp` 1e-6, `crushed` 2e-5 at 100 Mbit/s, a
  hundredth at 10). A hit frame fails its FCS: the receiver counts it in
  `rx_errors`/`rx_crc_errors` and drops it before the capture tap.
- **Negotiation.** Like clause 28: two autoneg ends take the best common mode,
  skipping speeds whose BER is at or above 1e-3 (a 200 m cable comes up at
  10 Mbit/s); an autoneg end facing a forced one detects the speed and takes
  half duplex (a duplex mismatch); garbled pages make both fall back to
  10/half. Any change renegotiates, with link down and up.
- **Half duplex.** Transmission is a small discrete-event simulation: carrier
  sense defers, simultaneous starts collide with jam and binary exponential
  backoff (16 tries, then aborted), and in a mismatch the full-duplex end's
  frames cause late collisions, runts and CRC errors; TCP then crawls on
  retransmissions, as on a real mismatch.
- All `rtnl_link_stats64` counters are kept and shown by `ip -s -s link`,
  `ifconfig`, `netstat -i`, `/proc/net/dev`, `/sys/class/net/*` and `ethtool -S`.

## Shared media: hubs and thin coax

`AgoraSegment` (`hardware/segment.gd`) is one collision domain at 10 Mbit/s
for many stations. A station defers while it hears another; two that start
before hearing each other collide, jam and back off (16 tries); a frame that
gets through reaches every other station at once, and a collision leaves them
a runt or, after the slot time, a frame with a bad FCS. A full-duplex station
neither listens nor notices collisions. Waiting stations collide with one
sending frames back to back, as on a real busy segment.

- **Hub** (`AgoraHub`, template `hub`). Its ports send 10 Mbit/s link pulses
  and don't negotiate: a card that autonegotiates takes 10/half by parallel
  detection; one forced to full duplex gets a link and a duplex mismatch. The
  stations are the cards cabled to its ports (a switch port too); the cable's
  length counts in the propagation, its bit errors in the frames. Everyone
  hears everything, so `tcpdump` on one station sees the others' traffic.
  Without power it repeats nothing. Hubs can't be cascaded yet (a cable
  between two hubs gives no link).
- **Thin coax** (`AgoraCoax`, 10BASE2). One bus with T-connectors at positions
  along it (`attach(nic, at_m)`, `remove`), a 50 ohm terminator at each end
  (`set_terminator`). An NE2000 card has no link detection and always reports
  carrier. Without both terminators every frame collides with its own echo
  (excessive collisions, nothing gets through); an open BNC socket does the
  same; beyond 185 m the error rate grows tenfold every 10 m. A world keeps its
  buses (`world.add_coax`, `AgoraCoaxSpec` in a spec).

## Sound

A PC has a sound card (`hardware.sound`). The kernel gives it `/dev/dsp`
(OSS, mode 0666 as for the console's user): a WAV file written there plays as
it says (`AgoraWav.parse`), anything else as 8 kHz 8-bit mono, as OSS starts.
The card emits `hardware.audio(pcm, rate, channels, bits)`; the demo plays
it (`AgoraWav.to_stream`) for the box in front of the player and the others
of its place. `play` (package `sox`, desktop profile) plays files.
`AgoraWav.make` and `chime` make sounds for programs that bring their own.

## Power and consoles

`power_on()` runs the firmware (see [boot](boot.md)); `power_off()` cuts the
power with no clean shutdown. The kernel calls back on reboot (through the
firmware again) and poweroff. `mains` is the power cord: out, nothing starts,
and with the battery out too the CMOS is lost (`set_mains`,
`set_cmos_battery`, `set_cmos_jumper`).

The monitor's text console is `tty1`, drawn under all windows by
`AgoraDisplayView`; the serial port `ttyS0` is reached by a terminal view, like
a console cable from nowhere, or by a real one: `connect_serial(other)`
(`world.plug_serial`, saved) puts a null-modem cable between two boxes'
serial ports, and `minicom` on one is then the other's console terminal (see
[services](services.md#serial-consoles)). A serial line has a speed
(`AgoraTty.baud`, from `console=ttyS0,115200`; the router's is 115200).
`/dev/ttyS0` is `root:dialout 0660`. Firmware and kernel messages go to the console
(`firmware_tty()`: the monitor, or the serial port of a box without one).

## The 3D view

`AgoraHardwareView3D` (`gui/view3d/hardware_view_3d.gd`) shows a box in 3D,
live, and lets the player handle it. The models are in `assets/*.glb` (by the
user): pc_2400, crt_17, keyboard, mouse, server_r1, router_wr54, switch_fs108,
RJ-45 plug variants, cable_console, power_cord, power_adapter, cd_agoraos,
cd_sleeve, usb_flash, and parts (mb_atx, cpu_cooler, ram_dimm, psu_atx,
hdd_ide, hdd_scsi, fdd_drive, card_e100, card_e1000, card_modem, card_sound,
card_agp_video). Metres, Y up, the front faces -Z. Named nodes drive the view:
ports as the NICs (eth0, WAN/LAN1-4, port1-8), `led_*`, `btn_power`,
`btn_reset`, `btn_eject`, `cd_tray` with `cd_disc`, `screen`, `side_panel`,
`power_in`, `label`, `view_point` (monitor), `mount_*`, `pci1-5`, `ram0-3`,
`jumper_clear_cmos`, `cmos_battery`.

- A Control with a SubViewport of its own world. `LAYOUTS` place the models per
  template (the PC on a desk with monitor, keyboard and mouse; server; router
  and switch with the power brick). Orbit camera with Front/Back/Left/Right/Top.
- **Places.** Boxes with the same `place` in their world are shown together
  (`_compose_place`): computers on a desk with the small boxes (router,
  switch, hub) beside them; with servers among them, a 19-inch rack (built from
  plain boxes) with the servers stacked two units apart from the bottom and the
  small boxes on a shelf at the top. The box shown is fully usable; the others
  have live lights and say what they are, and a click on one emits
  `box_chosen` (the demo then shows that box). Cables between boxes of the
  place run from plug to plug, along the back of the rack between units;
  cables to boxes elsewhere hang off the desk.
- **The cable box** (on the desk's corner, or on the floor by the rack): take a
  ready-made patch cable (1-20 m), or cut one from the reel (1-100 m) and crimp
  the plugs yourself, which may leave an untwisted pair or a bad crimp
  (`CRIMP_FAULTS`, per end) that only the link or the tester shows. The cable in
  hand goes into two free ports, on the box shown or another of the place
  (`take_cable`, `crimp_cable`, `plug_held`); right click puts it back. The
  crimp tool cuts a cable's plugs off and crimps new ones (`mend_cable`: gone
  are the old plugs' faults, a crushed cable stays crushed); the continuity
  tester (`test_cable`) shows a broken pair or a flickering pin, not crosstalk.
- **Thin coax from the box**: a piece (2-25 m) with its T-connectors joins two
  BNC cards (`take_coax`, `plug_coax_held`): a new bus terminated at both ends,
  or the bus one of them ends, made longer. Clicking a T-connector takes it
  off its card; the bus goes on without it.
- **Sounds** (`AgoraRoomSounds`, made in code, the box shown only): the fans
  and the disk's spindle while it's on, the heads seeking when the disk is used,
  the CRT's 15.7 kHz whine and its degauss thump when it comes on.
- **Console cables**: a light blue cable with DB9 plugs between serial ports
  (the router's is its UART header), taken from the cable box and plugged into
  two serial ports; clicking the shown box's port pulls it out.
- **Made from plain shapes** (`_procedural`, until there is a .glb of the same
  name): the hub `hub_hb108` (a light per port, POWER and COL, which blinks on
  the segment's collisions), the BNC T-connector `bnc_t` and terminator
  `bnc_terminator`, and the NE2000 card (the e100 model with a BNC barrel
  instead of its RJ-45 and lights). Thin coax runs black from T to T; the ends
  of a bus have a terminator or an open outlet, clicked to take it off or put it
  on; a bus that goes on to cards elsewhere leaves the scene.
- Picking is by rays against part boxes, with the bodies as blockers (no
  physics, so it works headless).
- Lights are polled every 50 ms: power, link, speed, activity (`AgoraNic.frames`),
  disk (`AgoraMemFs.io`), PSU by the cord, NumLock (`hardware.numlock`).
- The monitor shows the box's `AgoraDisplayView` in a nested SubViewport;
  clicking the screen sits down (keys and mouse go to the screen; right click
  or "Stand up" gets up). Labels are textures drawn from the box.
- The inside follows the machine's data: network cards by driver in the PCI
  slots, a memory module per 256 MB, a disk model per hard disk (IDE or SCSI
  by the disk's model) with its label printed, the CPU cooler. The server's
  case is built from parts: the mainboard lying flat, two power supplies, the
  disks in the front bays; its lid slides back. Every part says what it is
  under the mouse (disk with device and channel, card with MAC and PCI
  address, memory slot, CPU, power supply, mainboard and CMOS state).
- Clicks: power (held 1.5 s cuts it; with a kernel, an ACPI power-button event
  runs `/sbin/poweroff`), reset, eject and the tray, CDs between drive, tray
  and sleeve on the desk (the `shelf`), USB sticks, cables out and back in
  (through the world, so saves see it), the power cord, the side panel, and
  inside it the clear-CMOS jumper (pins 1-2 / 2-3) and the CMOS battery.

Model notes: the CRT's `screen` mesh faces +Z (its normals point into the
monitor), so the view draws it two-sided and unshaded. `end_dc_mesh`
(power_adapter) and `end_wall_mesh` (power_cord) carry their end's X offset
twice; the view puts them back.

## Persistence

`serialize()`/`save()` keep the template, every disk, MACs, the boot order, the
CMOS, battery, jumper and cord, and the clock. Images saved before hardware
existed load as a `pc`; disks saved before boot sectors get `grub` when they
have a kernel.
