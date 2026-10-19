# Kernel

The kernel is `AgoraMachine` (`kernel/machine.gd`) and what it owns: a VFS, the
accounts, processes, terminals and, while it runs, a network stack. It has no
nodes and runs headless.

## The machine

The firmware creates one `AgoraMachine` per boot of a box, with its root file
system on a disk of that box, and calls `boot()`. Tests and embedding code use
`AgoraMachine.create(hostname, opts)`, which builds a headless `virtual` box,
installs the system on its disk and powers it on.

- `boot()` reads the [kernel command line](boot.md#the-kernel-command-line),
  mounts `/proc`, `/dev`, `/sys` and a fresh `/run` (tmpfs), creates the
  device nodes, starts the network stack and runs `/sbin/init` (or `init=`) as
  pid 1 on `/dev/console`. Without a working init, a do-nothing fallback runs.
- `power(action, caller)` is reboot(2): only pid 1 may call it, after stopping
  its services. It stops every process and hands control back to the hardware
  (reboot goes back through the firmware).
- If init dies, the kernel panics: everything stops and `panicked` fires.
- `klog(message, level)` appends to the ring buffer (`dmesg`, `/proc/kmsg`) and
  prints on the consoles when `level` is below `console_loglevel` (`quiet`
  sets 4).
- `shutdown()` pulls the plug without a clean shutdown.
- Signals for front ends: `booted`, `powered_off`, `panicked`,
  `process_started`, `process_exited`.

## File systems

`AgoraVfs` is one tree of mounted backends (`AgoraFs`), with path resolution,
symlinks (up to 16 in a path, then ELOOP), permissions and mount points.

| Backend | Mounted at | What |
|---|---|---|
| `AgoraMemFs` | `/`, other disks, `/run` | the contents of a disk; saved with it. Counts I/O for the disk light |
| `AgoraHostFs` | anywhere (`mount_host`) | a real directory, the only way out of the sandbox |
| `AgoraProcFs` | `/proc` | `cmdline`, `cpuinfo`, `kmsg`, `meminfo`, `mounts`, `uptime`, `version`; per pid `cmdline`, `cwd`, `environ`, `status`; `net/` (`arp`, `dev`, `nf_conntrack`, `route`, `tcp`, `udp`); writable `sys/` (net.ipv4 settings) |
| `AgoraSysFs` | `/sys` | `class/net/*` (address, carrier, operstate, flags, statistics, duplex...), `class/dmi/id`, `block/*` |
| `AgoraDevFs` | `/dev` | `null`, `zero`, `random`, `urandom`, disks, ttys, `fb0`, `log`, `initctl`; a game adds devices with `dev.add_device(name, reader, writer)` |

A file system has its own `read_only` flag (a CD, `ro` on the command line,
`mount -o ro`); `mount -o remount,rw` clears it unless the medium itself is
read-only. Disks hold one file system each, seen as `sda1` on a hard disk or
stick and as the device itself on a CD (`sr0`) or flash (`mtdblock0`).

## Processes

`AgoraProcess` has a pid, parent, session, credentials (`AgoraCred`: uid, gid,
real ids, groups, umask), cwd, environment, stdin/stdout/stderr streams, a tty
and helpers for file calls (`read_text`, `write_text`, `stat`...). `spawn()`
finds the executable on `PATH`, loads it (native binary or `#!` script),
applies setuid/setgid and starts it; `start: false` lets the caller wire a
pipeline first. See [overview](overview.md#key-mechanisms) for coroutines,
streams, signals and executables.

Programs extend `AgoraProgram` and implement `main(p) -> int` and
`summary()`; they are registered by name in `AgoraPrograms` (an explicit list,
so it works in exported games), which also knows where each one is installed.
The [programs reference](../reference/programs.md) lists them all.

## The shell

`sh` parses its input into a syntax tree with a recursive descent parser
(`shell/lexer.gd`, `shell/parser.gd`): pipelines, `&&`/`||`, `;`, `&`,
`if`/`elif`/`else`, `while`/`until`, `for`, `case`, `{ }` groups, `( )`
subshells, functions, redirections, `$VAR`/`${VAR}`, `$(...)` and backquotes,
`$(( ))`, globs, `~`, aliases and history. Builtins: `: . [ alias break cd
continue eval exit export false history jobs local logout pwd read return set
shift source test true type umask unalias unset wait`.

- In a pipeline, external programs run as processes and are started first;
  builtins, functions and compound commands run inside the shell, reading and
  writing the pipes.
- `( )` and `$(...)` run in-process with the shell's state saved and restored,
  which gives the same result as a fork.
- Loops yield a frame between iterations, so `while true; do :; done` never
  freezes the game.
- `$(( ))` is evaluated with Godot's `Expression` after variables are
  substituted.
- An unfinished construct makes an interactive shell ask for more with `PS2`;
  history stores it as one line.
- A login shell (argv[0] starting with `-`) prints `/etc/motd` and reads
  `/etc/profile` and `~/.profile`.

## Users

`AgoraUsers` reads and edits `/etc/passwd`, `/etc/group` and `/etc/shadow`;
editing those files by hand works too. Password hashes are
`$5$<salt>$<sha256 hex>` (a simplification of crypt's SHA-256); an empty field
means no password, `*` or `!` a locked account. Tools: `login`, `su`, `sudo`
(group `sudo`), `passwd`, `useradd`, `id`, `whoami`. Packages can declare
system accounts (www-data, ftp, mail...), created locked.

## Terminals

`AgoraTty` is a terminal line between a front end (a terminal window, the
REPL, a serial console view, an ssh or telnet session) and the processes on it.

- **Canonical mode.** The front end edits the line and sends it with
  `type_line`; `echo` false hides what is typed (passwords).
- **Raw mode** (`raw`). Every key reaches the program at once (`type_key`), with
  VT100 sequences for arrows, Home/End, PgUp/PgDn, Insert/Delete and F1-F12.
  Full-screen programs (lynx, the BIOS, GRUB) use it.
- `cols`/`rows` are the window size (TIOCGWINSZ); `foreground` gets Ctrl+C;
  `hang_up()` sends SIGHUP and EOF.
- A box has `tty1` (the monitor's text console, drawn under all windows) and
  `ttyS0` (the serial port). Terminal windows, ssh and telnet allocate `pts/N`.

`AgoraTermView` (gui) is the emulator: a scrollback of cells with the 16 ANSI
colours, bold and reverse, cursor movement and clearing, canonical line editing
with history, Ctrl+C/D/L/U/W, paste, and raw mode.

## Clocks

`AgoraClock` is game time: it starts at any date and runs at any speed
(`set_time`, `set_speed`, `tz_offset_minutes`); several boxes share the world's
clock. A kernel runs on its box's `rtc`, made with `AgoraClock.follow(world
clock)`: it keeps the world's time and speed, moved by the CMOS clock's offset.
Setting it (`date -s`) moves that box only, until the next boot takes the time
from the CMOS again (see [clocks](boot.md#clocks)). DHCP leases and cron follow
game time; ARP, TCP retransmission and conntrack timers follow real time.
