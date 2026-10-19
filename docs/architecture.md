# AgoraOS architecture

AgoraOS is a Unix-like operating system simulated inside Godot. It is built as an
addon (`addons/agora_os/`) so a game can embed it. The main future user is a game
set in 2000s hacker culture.

## Principles

1. **Kernel first, GUI on top.** The kernel is plain GDScript with no nodes and no UI,
   and it runs headless. The desktop will be one front end among others, like X11 on
   Unix. Another front end is the console REPL in `tools/repl.gd`.
2. **Machines are objects, not globals.** An `AgoraMachine` is one computer with its
   own file system, accounts, processes and log files. A game can create any number of
   them and connect their network ports with cables.
3. **Everything is a file.**
   - Accounts live in `/etc/passwd`, `/etc/group` and `/etc/shadow`.
   - The host name lives in `/etc/hostname`.
   - Logs live in `/var/log`, shell history in `~/.sh_history`, process info in `/proc`
     and devices in `/dev`.
   - Programs in `/bin` are files too: they can be copied, renamed, deleted and chmod-ed.
4. **Realistic enough, room to grow.** We aim for plausible behavior: permissions,
   setuid, sticky `/tmp`, pipes and signals. Every simplification sits behind an
   interface that can be extended later.
5. **Sandboxed.** A machine's file system is virtual and saved as one image file. The
   player's real disk is reachable only through an explicit host mount
   (`AgoraMachine.mount_host`).

## Layout

```
addons/agora_os/kernel/
  machine.gd      AgoraMachine   one computer: vfs, users, processes, clock, spawn, login, save/load
  installer.gd    AgoraInstaller lays down the base system (FHS dirs, /etc, /bin)
  vfs.gd          AgoraVfs       single tree from mounted backends, path resolution, permissions
  fs/             AgoraFs backends: mem_fs (saved), host_fs (real dir), proc_fs, dev_fs
  process.gd      AgoraProcess   pid, cred, cwd, env, streams, tty, signals, file calls
  program.gd      AgoraProgram   base class of every executable
  programs.gd     AgoraPrograms  explicit registry: name -> script (works in exports)
  stream.gd       AgoraStream    pipes: refcounted ends, EOF, broken pipe
  tty.gd          AgoraTty       terminal line between a front end and processes
  users.gd        AgoraUsers     reads and edits passwd/group/shadow
  cred.gd         AgoraCred      uid/gid/ruid/groups/umask
  clock.gd        AgoraClock     in-game time: any date, any speed
  net/            the network stack, one per running kernel (see Networking):
                  netstack.gd AgoraNetStack, inet.gd AgoraInet, neighbours.gd (ARP),
                  bridge.gd, icmp.gd, udp.gd, tcp.gd, netfilter.gd, conntrack.gd,
                  dhcp.gd, dns.gd (message helpers), resolver.gd (nsswitch,
                  /etc/hosts, resolv.conf, DNS queries)
  mime.gd         AgoraMime      file types (/etc/mime.types) and default apps (.desktop, mimeapps.list)
  shell/          lexer + parser for sh
addons/agora_os/hardware/ AgoraHardware, AgoraDisk, AgoraNic, AgoraCable (the box the OS
                          runs on); AgoraWorld (boxes and cables under one clock, saved
                          as one file); AgoraWorldSpec, AgoraBoxSpec,
                          AgoraCableSpec (a world as a resource); the firmware:
                          AgoraCmos (settings), AgoraBios (POST, boot menu, boot
                          devices, the router's CFE), AgoraBiosSetup (Setup),
                          AgoraGrub (GRUB 0.97: menu.lst, commands, update-grub's
                          menu), AgoraGrubMenu (its screens), AgoraFwScreen (80x25
                          screen and raw keyboard on the console tty)
addons/agora_os/system/   distro.gd (packages, profiles), packages.gd, media.gd (install CD),
                          apkg, busybox, agora-install, getty/login live in kernel/bin;
                          init systems and daemons: systemd, systemctl, journalctl,
                          sysvinit (+ telinit), service, start-stop-daemon, reboot,
                          syslogd, logger, dmesg, crond, crontab, sshd
  bin/            programs (sh and the coreutils)
  display/        AgoraDisplay (display server), AgoraWindow
addons/agora_os/gui/
  display_view.gd AgoraDisplayView  shows a display in the scene tree ("the monitor")
  term_view.gd    AgoraTermView     terminal emulator widget (ANSI colors, line editing)
  gui_program.gd  AgoraGuiProgram   base for windowed programs ($DISPLAY lookup)
  wm/             window frame and theme parser used by the wm program
  dialog.gd       AgoraDialog       modal dialogs drawn inside a program's window
  style.gd        AgoraStyle        bundled mono font, icons drawn in code
  fonts/          DejaVu Sans Mono (see CREDITS.md)
  apps/           greeter, wm, panel, desktop, terminal, files, edit, view, open
main.tscn            demo front end: the world in worlds/home.tres, one screen per box
worlds/              world specs (AgoraWorldSpec resources)
tests/run_tests.gd   headless test suite
tools/repl.gd        console front end
```

## Key mechanisms

### Processes are coroutines
`AgoraProgram.main(p)` may `await`. Blocking reads, `sleep` and waiting for a child
all suspend the coroutine. There are no threads.

Godot resumes awaiting coroutines synchronously inside `emit()`. So when one stage of
a pipeline writes, the next stage runs right away, nested in the same call.

The shell creates every stage of a pipeline first and starts them last to first. That
way readers are already waiting before writers produce anything.

Programs that loop for a long time call `await p.tick()` so the engine keeps drawing.

### Streams
An `AgoraStream` counts its writers and readers.
- When the last writer goes away, readers see EOF.
- When the last reader goes away, writes fail. The writer is killed with SIGPIPE, which
  is how `yes | head` stops.

### The shell
`sh` parses input into a syntax tree with a recursive descent parser
(`shell/parser.gd`). The tree has pipelines, `if`/`elif`/`else`,
`while`/`until`, `for`, `case`, `{ }` groups, `( )` subshells and functions.

- **Execution.** In a pipeline, external programs run as processes and are all
  started first. Builtins, functions and compound commands then run inside the
  shell, reading and writing the pipes.
- **Subshells.** `( )` and `$(...)` run in-process, with the shell's state saved and
  restored. That gives the same result as a fork: functions are visible inside,
  and changes are discarded afterwards.
- **Loops.** Loops yield a frame between iterations, so `while true; do :; done`
  never freezes the game.
- **Arithmetic.** `$(( ))` is evaluated with Godot's `Expression`, with variables
  substituted first.
- **Interactive input.** An unfinished construct makes the shell ask for more input
  with `PS2`. History stores it as one valid line.

### Signals
`send_signal` runs the program's `signal_handler` first, if it has one. Otherwise the
default action ends the process with status 128 + signal.

When a process ends, its streams are released. That wakes any blocked read, so a
killed process never hangs. Ctrl+C on a tty sends SIGINT to `tty.foreground`, which the
shell sets around each job.

### Executables
A native binary is a text file that starts with `\x7fAGX <name>`. Running it looks up
`<name>` in `AgoraPrograms`.

Scripts that start with `#!` run through their interpreter. The setuid bit is honored
on binaries (`su`, `sudo`, `passwd`) and ignored on scripts.

### Permissions
`AgoraVfs.can_access` implements owner/group/other rwx checks.
- Root bypasses everything, except that it can't execute a file with no x bit.
- Removing an entry needs w+x on its directory.
- In a sticky directory, only the owner of the entry or of the directory may remove it.

### Persistence
`AgoraMachine.save_image` stores the hardware with its disks and the clock in a
zstd-compressed file. Mounts, processes and kernel state (addresses, routes,
firewall rules) are not saved: a loaded machine boots fresh and configures itself
from its files, as a real one does.

## Hardware

`AgoraHardware` is the box: CPU, RAM, disks, network ports, an optional
monitor and a serial console.

- **Templates.** `pc`, `server`, `router` (MIPS, 16 MB, 1 WAN + 4 LAN, serial only)
  and `virtual` (headless, used by `AgoraMachine.create`).
- **Disks.** An `AgoraDisk` (HDD, CD-ROM, USB, flash) holds one `AgoraMemFs`, or
  none until `mkfs`. Device names follow Linux: `sda`/`sda1`, `sdb1` for a USB
  stick, `sr0`, `mtdblock0`.
- **Ports and cables.** `AgoraNic` has a MAC address, a top speed and an extra
  one-way latency. `AgoraCable` (`plug`, or `hardware.connect_port` with a length)
  gives both ends carrier and runs at the slower card's speed. Each direction has
  a transmit queue: a frame holds the line for preamble and SFD, the frame padded
  to 60 bytes and the FCS; the next one starts after the 96-bit interframe gap;
  then the signal travels about 5 ns per metre. Frames arrive in order, and the
  delay they picked up, queueing included, is recorded for `ping`. The
  interface's `txqueuelen` bounds the queue; what doesn't fit is dropped.
- **Firmware.** It boots the first bootable device in `boot_order`. A hard disk
  or USB stick is bootable with something in its boot sector
  (`AgoraDisk.boot_sector`: `grub`, or `syslinux` on the install stick); a CD or
  the router's flash with a kernel at `/boot/vmlinuz`. A reboot goes back through
  the firmware, so a machine whose installer ejected its CD comes up from the
  hard disk. Two ways to run (see below): at once (tests, `AgoraMachine.create`,
  embedding), or interactive (`hardware.interactive`, set by the demo for every
  box in its world).
- **CMOS.** `AgoraCmos`, saved with the box: quick POST, NumLock, the onboard
  LAN (off: the kernel finds no network card), Security Setup/System with the
  supervisor and user passwords, the CMOS clock (`rtc_offset`). `clear()` is the
  clear-CMOS jumper: defaults back, and the next POST says "CMOS checksum error -
  Defaults loaded". The kernel runs on `hardware.rtc`, a clock that follows the
  world's clock moved by the CMOS offset; `set_time` on it moves that box only,
  until the next boot.
- **Consoles.** The monitor's text console is `tty1`. It is drawn under all
  windows by `AgoraDisplayView`. The serial port is `ttyS0`; connect a terminal
  to it as you would a console cable. Kernel messages go to the console.
- **What the kernel shows.** `/dev` (disks, ttys, `fb0`), `/sys/class/net/*`,
  `/sys/block/*`, `/proc/cpuinfo` and `/proc/meminfo`.
- **Tools.** `lsblk`, `free`, `ip link`, `mount`/`umount`, `mkfs`, `eject`.
- **Persistence.** `hardware.save()` stores the whole box with every disk. Images
  saved before hardware existed load as a `pc`.

## Networking

Everything is simulated: a packet is a Dictionary passed between objects, and
nothing touches the real network. The goal is that people who know networking
recognize the behavior and the output of every tool.

- **Layers.** `AgoraNic.transmit` puts an Ethernet frame `{dst, src, type, payload}`
  on the cable; the other end's kernel gets a copy on the next engine frame (later,
  on slow links). `AgoraNetStack` owns the interfaces (`lo`, one per NIC, bridges),
  IPv4 addresses, the main and local routing tables (longest prefix match), ARP
  with Linux's neighbour states (`AgoraNeighbours`), forwarding, ICMP, UDP and TCP.
  Packets carry the latency they picked up (`lat`), which `ping` and `traceroute`
  report.
- **Netfilter.** The filter and nat tables run at Linux's hooks (PREROUTING,
  INPUT, FORWARD, OUTPUT, POSTROUTING) with connection tracking. NAT is decided on
  a flow's first packet and undone on replies and on ICMP errors about it.
- **TCP.** Everything travels as segments with sequence numbers: handshake, data
  (MSS 1460), ACKs, FIN, RST. Unacknowledged data is retransmitted with a doubling
  timeout until `tcp_retries2` gives up, so a pulled cable or a new firewall rule
  affects open connections too. RST, ICMP errors and timeouts give Linux's errno.
  Programs see a connection as two `AgoraStream`s. ssh frames its session inside
  the stream (`AgoraSshChannel`: data, stderr, terminal modes, signals, exit status).
- **Names.** `AgoraResolver` works like glibc: `hosts:` in `/etc/nsswitch.conf`,
  `/etc/hosts`, then DNS over UDP with `resolv.conf`'s nameservers, search list
  and options. `dnsmasq` answers from `/etc/hosts`, `address=` and `cname=`,
  forwards the rest and caches it; the router runs it for the LAN.
- **Capture.** `AgoraCapture` is a packet socket (AF_PACKET): the stack taps
  frames where Linux does (a NIC's output and input after its MAC filter, a bridge
  both ways, `lo` once per packet) and queues copies. Promiscuous mode is a
  counter the bridge and captures share. `tcpdump` decodes the dictionaries and
  uses `AgoraWire`, which gives a frame its real bytes (headers, checksums, DNS
  and DHCP encoding), for `-A`, `-x` and `-X`.
- **What the kernel shows.** `/proc/net/{dev,route,arp,tcp,udp,nf_conntrack}`,
  `/proc/sys/net/ipv4/*` (writable), `/sys/class/net/*`, kernel log lines.
- **Tools.** iproute2 `ip` and `bridge`; net-tools `ifconfig`, `route`, `arp`,
  `netstat`; `ping`, `traceroute`, `nc`, `sysctl`, `iptables` with save/restore,
  `dig`, `host`, `nslookup`, `getent`, `dnsmasq`, `tcpdump`,
  `brctl`; ifupdown with `/etc/network/interfaces` and the `networking` service;
  busybox `udhcpc`/`udhcpd`/`dumpleases`; `ssh`/`sshd` over TCP. Busybox applets
  print busybox's own formats where they differ.
- **The router.** `br-lan` bridges the four LAN ports (192.168.1.1/24), udhcpd hands
  out 192.168.1.100-199, the WAN port asks for an address with udhcpc, and
  `/etc/init.d/firewall` masquerades the LAN and lets only replies in.

## Packages and profiles

`AgoraDistro` (`system/distro.gd`) defines every package. A package is a
dictionary of dirs, files, programs (binaries) and symlinks. It also defines
the profiles:

- `desktop`: everything.
- `server`: no graphics.
- `router`: busybox, router configuration and openssh.
- `live`: the install CD.

`AgoraPackages` installs packages onto any VFS and keeps
`/var/lib/apkg/{installed,info/}`. `apkg` installs and removes packages from
repositories of `.pkg` files (JSON), such as `/repo` on the install CD.

**busybox.** On the router, `/bin/busybox` is one setuid binary, and every
applet is a symlink to it. The name it is started under picks the applet, and
applets other than su, passwd and crontab drop the setuid privilege.

**Installation.** `AgoraMedia.installer()` builds the install CD: a live system
whose inittab runs `getty -n -l /sbin/agora-install` on every console, plus the
package repository. The installer asks, in text mode:

1. the disk,
2. the profile,
3. the host name,
4. the root password,
5. a user,
6. the init system.

It then runs `mkfs`, installs the packages, configures the system, ejects the
CD and reboots. `AgoraMachine.create()` does the same without questions on a
virtual box.

## Boot and init

- **BIOS** (`AgoraBios`, interactive boxes only). POST on the console: banner,
  CPU, a counting memory test, the IDE channels, "Press DEL to enter SETUP, F12
  for BOOT MENU". DEL opens Setup (`AgoraBiosSetup`, Award-style blue screens:
  Standard CMOS Features with the date and time, Advanced BIOS Features with the
  boot order, Integrated Peripherals, PC Health Status, defaults, passwords,
  Save & Exit / Exit Without Saving, F10). F12 boots one device once. With
  Security "System" the password is asked at boot; three wrong ones halt. No
  bootable device: "DISK BOOT FAILURE, INSERT SYSTEM DISK AND PRESS ENTER". The
  firmware owns the console in raw mode (`AgoraFwScreen`) and gives it back
  before the kernel starts. Cutting the power abandons whatever it was doing.
  The router prints a CFE loader on its serial port instead.
- **GRUB** (`AgoraGrub`). Stage 2 and `/boot/grub/menu.lst` on the boot disk;
  `(hd0)` is the disk booted from. The entry's `root`, `kernel` (file and command
  line) and `initrd` are run, with GRUB's messages and errors (Error 15, 13, 21,
  22, 8...). Without a menu: the `grub>` command line. Interactive
  (`AgoraGrubMenu`): the menu with its countdown and colours, `e` (entry editor:
  b, e, o, O, d), `c` (command line: root, kernel, initrd, boot, find, cat,
  setup, displaymem, help, reboot, halt), `password` with `p`, `hiddenmenu`. The
  `grub` package has `grub-install` (stage files, `device.map`, the boot sector)
  and `update-grub` (rewrites the entries between the AUTOMAGIC markers from the
  kernels in `/boot`, keeping `kopt`, `groot`, `alternative`, `defoptions`,
  `altoptions` and the rest of the file), run by the kernel package's
  postinst; `grub-md5-crypt` for `password --md5`. Both installers put GRUB
  on the disk.
- **Clocks.** The kernel starts from the CMOS clock. `date -s` sets the system
  clock only; `hwclock -w` (and sysvinit's `hwclock.sh` at shutdown) writes it
  back, `hwclock -s` reads it.
- **The kernel command line** (`machine.cmdline`, `/proc/cmdline`). The kernel
  reads `root=` (the root device; a missing one panics), `ro`/`rw`, `init=`,
  `quiet` and `loglevel=` (what reaches the console), `console=` (tty1, ttyS0;
  the last is `/dev/console`). Other words go to init as arguments, name=value
  pairs into its environment.

The kernel only mounts `/proc`, `/dev` and a fresh `/run`, then executes
`/sbin/init` (or `init=`) as pid 1 on `/dev/console`. What init is depends on
the file system. With `ro`, `/` starts read-only: sysvinit's
`/etc/rcS.d/S10checkroot.sh` and systemd remount it (`mount -o remount,rw /`).
A runlevel on the command line (`1`-`5`, `single`/`S`) overrides initdefault;
single-user mode runs `sulogin` on the console, and leaving its shell boots on
to the default runlevel. systemd takes `single`, `emergency`, a runlevel or
`systemd.unit=` (rescue.target, emergency.target).

- **Swapping init.** `/sbin/init` is a symlink, so swapping init is just
  `ln -sf /lib/sysvinit/init /sbin/init; reboot`. Without a working init, the
  kernel uses a built-in fallback. If init dies, the kernel panics: every
  process stops and `machine.panicked` fires.
- **Talking to init.** Init creates `/dev/initctl` (mode 0600). `reboot`,
  `halt`, `poweroff`, `shutdown`, `telinit` and `systemctl` write requests there
  (`AgoraInitCtl`). Init stops its services and then calls `machine.power()`,
  the reboot(2) of this kernel. Poweroff fires `machine.powered_off`, and the
  demo front end closes the window.
- **systemd** (`/lib/systemd/systemd`, the default for the addon):
  - Units live in `/lib/systemd/system`, and `/etc/systemd/system` overrides
    them.
  - Supported keys: Requires/Wants, `.wants/` links, After/Before ordering,
    ConditionPathExists, Type=simple|oneshot, Restart= with a start limit,
    User= and Environment=.
  - Each service runs in its own session, and stopping it kills the whole
    session.
  - Service output goes to the journal (`/var/log/journal`, read with
    `journalctl`). Unit state is in `/run/systemd/units`.
  - Tools: `systemctl` (status, start, stop, enable, disable, list-units, cat,
    set-default and more) and `service`, which forwards to it.
- **sysvinit** (`/lib/sysvinit/init`):
  - Reads `/etc/inittab` (initdefault, sysinit, wait, once, respawn, with the
    "respawning too fast" limit).
  - `/etc/init.d/rc N` runs the `K*` and `S*` links in `/etc/rcN.d`.
  - Init scripts use `start-stop-daemon` with pid files in `/run`.
  - Tools: `telinit`, `runlevel`, `service`. Script output goes to the console,
    which is the kernel log (`dmesg`).
- **Shared daemons.** Both inits run the same daemons:
  - `syslogd` serves `/dev/log` and routes messages by `/etc/syslog.conf`.
    Without it, messages only reach the kernel ring buffer.
  - `crond` reads `/etc/crontab` and `crontab` spools, and runs on game time.
  - `sshd` listens on port 22. `ssh` is refused when nothing listens there.
- **Login screen.** It is a service: `display-manager.service` with
  `ConditionPathExists=/dev/fb0`, or an inittab respawn line. Attaching a display
  creates `/dev/fb0`. Front ends attach the display before calling `boot()`.

## Graphics

The graphics layer follows X11, not a typical toy desktop.

- **Display server.** `AgoraDisplay` belongs to a machine. A headless machine has
  none, so `terminal` on a server, or from an ssh session, fails with
  "cannot open display". Windows belong to processes and close when their process
  exits.
- **Window manager.** `wm` is a program that registers with the display and builds
  a frame for every window.
  - Kill it and windows become bare. Start it again and they get frames back.
  - The look comes from `/usr/share/themes/<name>/wm.theme`, chosen by
    `~/.config/wm.conf` or `/etc/wm.conf` (`theme=classic`).
- **Session.** `greeter` runs as root and checks the password against
  `/etc/shadow`. It then runs `~/.xinitrc`, or `/etc/X11/xinitrc` if there is none,
  as the user in a new session (sid).
  - The default script starts `desktop &`, `panel &`, `terminal &` and then `wm`,
    so the session ends when `wm` exits.
  - When the session ends, the greeter kills everything left with that sid and
    shows the login screen again.
  - Session output goes to `~/.xsession-errors`. Logins are logged to
    `/var/log/auth.log`.
- **Layers.** Windows sit on DESKTOP, NORMAL, PANEL or OVERLAY. A panel reserves a
  screen edge with `set_strut`, and maximized windows avoid it.
- **Application menu.** It is built from `/usr/share/applications/*.desktop`.
- **Opening files.** `open <file>` works like xdg-open. The type comes from
  `/etc/mime.types`, or from sniffing the content. The app comes from the
  `MimeType=` lines in `.desktop` files, and `~/.config/mimeapps.list` can
  override it. Executables open in a terminal.
- **Apps.**
  - `files` runs with the user's own permissions. Copy, move and delete run the
    real `cp`, `mv` and `rm`.
  - `edit` opens files it can't write as read-only and asks before discarding
    changes.
  - `view` shows PNG, JPEG and WebP images.
  - `desktop` shows `~/Desktop` as icons. New users get it from `/etc/skel`.
- **Terminal.** `terminal` allocates a pseudo-terminal (`pts/N`) and runs `$SHELL`
  on it. `AgoraTermView` does canonical line editing, hides input while echo is
  off, and supports history, Ctrl+C/D/L/U/W, paste, scrollback, the 16 ANSI colors
  and clearing the screen.

## Extending (for the game)

- **New windowed program:** extend `AgoraGuiProgram`, call `open_window(p, control, opts)`,
  then `await win.closed`.
- **New program:** write a script that extends `AgoraProgram`, then call
  `AgoraPrograms.register("name", script)` and `AgoraInstaller.install_program(machine, "name")`.
- **New device:** call `machine.dev.add_device("modem", reader, writer)`.
- **New machine:** call `AgoraMachine.create(hostname, {users, root_password, motd,
  network})`, where `network` is `{"eth0": {"method": "static", "address": ...,
  "netmask": ..., "gateway": ...}}` or `{"eth0": {"method": "dhcp"}}`. Then cable it:
  `machine.hardware.connect_port("eth0", other.hardware, "eth1")`. Names go in
  `/etc/hosts`.
- **Game time:** call `clock.set_time(unix)` and `clock.set_speed(x)`. Several machines can
  share one clock.

## Not done yet (planned)

- Job control (`fg`, `bg`), here-documents, `set -e`.
- Drag and drop between windows. Symlink badges on icons.
- Network depth: `scp`/`ftp`/`telnet`, `tcpdump -w`/`-r` (pcap files), IPv6, DNS over TCP and zones,
  fragmentation and MTU limits, STP, TCP congestion and flow control.
- Hard links, file locking, and quotas.
