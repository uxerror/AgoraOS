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
| `virtual` | headless PC for tests and `AgoraMachine.create` | 8 GB | `eth0` (e1000) | `ttyS0` |

Names and figures are fictional but true to the era. A switch learns which
address is behind which port and forwards frames in the hardware itself.

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

## Power and consoles

`power_on()` runs the firmware (see [boot](boot.md)); `power_off()` cuts the
power with no clean shutdown. The kernel calls back on reboot (through the
firmware again) and poweroff. `mains` is the power cord: out, nothing starts,
and with the battery out too the CMOS is lost (`set_mains`,
`set_cmos_battery`, `set_cmos_jumper`).

The monitor's text console is `tty1`, drawn under all windows by
`AgoraDisplayView`; the serial port `ttyS0` is reached by a terminal view, like
a console cable. Firmware and kernel messages go to the console
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
- Picking is by rays against part boxes, with the bodies as blockers (no
  physics, so it works headless).
- Lights are polled every 50 ms: power, link, speed, activity (`AgoraNic.frames`),
  disk (`AgoraMemFs.io`), PSU by the cord, NumLock (`hardware.numlock`).
- The monitor shows the box's `AgoraDisplayView` in a nested SubViewport;
  clicking the screen sits down (keys and mouse go to the screen; right click
  or "Stand up" gets up). Labels are textures drawn from the box.
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
