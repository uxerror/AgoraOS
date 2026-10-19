# Firmware, boot and init

From the power button to a login prompt: the BIOS finds a boot device, GRUB
loads the kernel with a command line, the kernel runs init, init starts the
services.

## Two ways to boot

- **At once** (the default: tests, `AgoraMachine.create`, embedding). The
  firmware prints its summary, takes the defaults (GRUB's default entry, no
  waiting) and `power_on()` returns the running machine.
- **Interactive** (`hardware.interactive`, which `main.gd` sets for every box
  in its world). The full BIOS and GRUB screens, with real-time pauses and
  keys. `power_on()` returns at once; `machine_started` says when a kernel
  runs. Cutting the power abandons whatever the firmware was doing.

The firmware owns the console in raw mode while it runs (`AgoraFwScreen`:
80x25 with colours, keys as names such as `delete`, `f12`, `up`) and gives it
back in canonical mode before the kernel starts.

## BIOS

`AgoraBios` (`hardware/bios.gd`) is an Award-style BIOS of 2003.

- **POST**: the banner, the CPU, a counting memory test (shorter with Quick
  POST), the IDE channels, USB sticks, "Press DEL to enter SETUP, F12 for BOOT
  MENU". After a CMOS clear: "CMOS checksum error - Defaults loaded", "Press F1
  to continue, DEL to enter SETUP".
- **Setup** (`AgoraBiosSetup`, DEL): the blue screens. Standard CMOS Features
  (date and time, drives, memory), Advanced BIOS Features (Quick POST, first to
  third boot device, NumLock, Security Option), Integrated Peripherals (the
  onboard LAN), PC Health Status, Load Fail-Safe / Optimized Defaults, Set
  Supervisor / User Password, Save & Exit Setup (also F10), Exit Without
  Saving. Arrows, Enter, Esc, PgUp/PgDn and +/-; pop-up lists and Y/N
  questions. Changes are made on a copy and written by Save & Exit; either way
  out restarts the machine.
- **Boot menu** (F12): the devices present, to boot one of them once.
- **Passwords**: the supervisor's guards Setup; with Security "System" a
  password is asked at every boot. Three wrong ones: "SYSTEM HALTED".
- **Boot devices** in `boot_order` (`cdrom`, `usb`, `hdd`, `flash`). A hard
  disk or stick needs something in its boot sector; a CD or the flash a kernel
  at `/boot/vmlinuz`. Nothing bootable: "DISK BOOT FAILURE, INSERT SYSTEM DISK
  AND PRESS ENTER", and Enter tries again.
- **The router** has no BIOS: it prints a CFE loader on its serial port and
  starts the kernel from flash with `console=ttyS0,115200`.

## CMOS

`AgoraCmos` (`hardware/cmos.gd`), saved with the box: Quick POST, NumLock, the
onboard LAN (off: the kernel finds no network card), Security Setup/System,
the supervisor and user passwords, the CMOS clock (`rtc_offset`, seconds ahead
of the world's clock) and `valid`.

`clear()` is what the clear-CMOS jumper does: defaults back, passwords and
clock reset, the boot order back to `cdrom, usb, hdd`, and the next POST
reports the checksum error. On the board (the 3D view, with the side panel
off): the jumper on pins 2-3 clears it and the board won't start until it is
back on 1-2; the battery can be taken out, and without battery and power cord
the CMOS is lost (the PSU's standby power keeps it otherwise).

## GRUB

`AgoraGrub` (`hardware/grub.gd`) is GRUB legacy 0.97 as Debian shipped it.

- **Stages.** Stage 1 is the boot sector (`boot_sector == "grub"`); stage 2 and
  `/boot/grub/menu.lst` are on the disk. `(hd0)` is the disk booted from, the
  other hard disks and sticks follow; one partition per disk, so `(hdN,0)`.
  No stage 2: "Error 15". No file system: "GRUB Hard Disk Error".
- **menu.lst.** `default`, `timeout`, `hiddenmenu`, `color`, `password`
  (plain or `--md5`), and `title` entries of `root`, `kernel` (the file and the
  kernel command line), `initrd`, `savedefault`, `makeactive`. Choosing an
  entry runs its commands and then `boot`, printing what GRUB prints
  (`Filesystem type is ...`, `[Linux-bzImage, setup=0x1e00, size=...]`).
- **Errors** as GRUB's: 1, 8, 11, 13 (not a kernel), 15 (file not found), 17,
  21 (no such disk), 22 (no such partition), 27 (unrecognized command).
- **Without a menu**: the `grub>` command line.
- **Screens** (`AgoraGrubMenu`, interactive): the menu box with the countdown
  and colours; `e` the entry editor (b, e, o, O, d, Esc); `c` the command line
  (root, rootnoverify, kernel, initrd, boot, find, cat, setup, displaymem,
  help, reboot, halt; TAB completes command names); `p` the password that
  unlocks the other two.
- **Tools** (package `grub`): `grub-install DEVICE` (stage files into
  `/boot/grub`, `device.map`, the boot sector), `update-grub` (rewrites the
  entries between the AUTOMAGIC markers from the kernels in `/boot`, keeping the
  options `kopt`, `groot`, `alternative`, `defoptions`, `altoptions` and the rest
  of the file; a menu.lst without markers keeps its entries and gets the list
  after them), `grub-md5-crypt` (real MD5-crypt, `$1$`). The GRUB command
  `setup (hd0)` writes the boot sector too.
- Both installers put GRUB on the disk; the kernel package's postinst and
  postrm run `update-grub -y`.

## The kernel command line

`machine.cmdline`, shown in `/proc/cmdline` and logged at boot.

| Parameter | Effect |
|---|---|
| `root=/dev/sda1` | the root file system; a device that isn't there panics ("VFS: Cannot open root device") |
| `ro` / `rw` | `/` starts read-only; init remounts it |
| `init=/bin/sh` | runs that as pid 1 instead of `/sbin/init`; a missing one falls back ("Attempting defaults...") |
| `quiet`, `loglevel=N` | which kernel messages reach the console |
| `console=tty1`, `console=ttyS0,115200` | where kernel messages go; the last is `/dev/console` |
| other words (`single`, `3`) | passed to init as arguments |
| `name=value` (`systemd.unit=...`) | put in init's environment |

`init=/bin/sh` gives a root shell on the console with `/` read-only (`mount -o
remount,rw /`); leaving it panics the kernel, as on Linux.

## Clocks

The kernel starts from the CMOS clock. `date -s` sets the system clock only;
`hwclock -w` writes it into the CMOS, `hwclock -s` reads it back, `hwclock
--set --date=...` sets the CMOS. sysvinit's `hwclock.sh` (K25 in rc0 and rc6)
saves the system time at shutdown, so a clean reboot keeps `date -s` and pulling
the plug loses it.

## Init

The kernel runs `/sbin/init`, a symlink: `ln -sf /lib/sysvinit/init /sbin/init;
reboot` switches init. Init creates `/dev/initctl` (mode 0600); `reboot`,
`halt`, `poweroff`, `shutdown`, `telinit` and `systemctl` write requests there
(`AgoraInitCtl`). Init stops its services and calls `machine.power()`.

### sysvinit

`/lib/sysvinit/init` reads `/etc/inittab`: initdefault, sysinit, wait, once,
respawn (with the "respawning too fast" limit). `/etc/init.d/rc N` runs the
`K*` and `S*` links of `/etc/rcN.d`; `rcS` runs `/etc/rcS.d` at boot
(`S10checkroot.sh` remounts `/` read-write after `ro`, `S40networking`). Init
scripts use `start-stop-daemon` with pid files in `/run`. Script output goes to
the console, which is the kernel log (`dmesg`). Tools: `telinit`, `runlevel`,
`service`.

A runlevel on the command line (`1`-`5`, `single`/`S`) overrides initdefault.
Runlevel S runs `~~:S:wait:/sbin/sulogin`; runlevel 1 ends in S, as Debian's
S90single does; leaving the maintenance shell goes on to the default runlevel.

### systemd

`/lib/systemd/systemd`, the default. Units in `/lib/systemd/system`, overridden
by `/etc/systemd/system`. Keys: Requires/Wants, `.wants/` links, After/Before,
ConditionPathExists, Type=simple|oneshot, Restart= with a start limit, User=,
Environment=. Each service runs in its own session and stopping it kills the
session. Output goes to the journal (`/var/log/journal`, `journalctl`); unit
state is in `/run/systemd/units`. Tools: `systemctl` (status, start, stop,
restart, enable, disable, is-active, list-units, list-unit-files, cat,
get-default, set-default, default, daemon-reload, poweroff, reboot, halt) and
`service`.

It remounts `/` read-write unless booting emergency.target. From the command
line: `single`, `s`, `S`, `1` give rescue.target, `emergency` emergency.target
(both run `sulogin`, then `systemctl default`), `2`-`5` a runlevel's target,
`systemd.unit=` any unit.

### Shared daemons

- `syslogd` serves `/dev/log` and routes by `/etc/syslog.conf`; without it
  messages only reach the kernel ring buffer.
- `crond` reads `/etc/crontab` and `crontab` spools, on game time.
- `sshd` on port 22; mail, web and the other services in [services](services.md).
- The login screen is a service (`display-manager.service` with
  `ConditionPathExists=/dev/fb0`, or an inittab line): a box with a monitor has
  `/dev/fb0`.
