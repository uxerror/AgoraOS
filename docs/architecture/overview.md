# Architecture overview

AgoraOS is a Unix-like operating system simulated inside Godot. It is built as
an addon (`addons/agora_os/`) so that a game can embed it. Its main future user
is a game set in the hacker culture of the 2000s, for players who know how real
systems and networks behave.

## Principles

1. **Kernel first, GUI on top.** The kernel is plain GDScript with no nodes and
   no UI, and it runs headless. The desktop is one front end among others, as X11
   is on Unix. The console REPL (`tools/repl.gd`) is another.
2. **Machines are objects, not globals.** An `AgoraMachine` is one computer with
   its own file system, accounts, processes and logs. A game can create any
   number of them, put them in a world and cable their ports together.
3. **Everything is a file.** Accounts are `/etc/passwd`, `/etc/group` and
   `/etc/shadow`; the host name is `/etc/hostname`; logs are in `/var/log`;
   process information is in `/proc`, devices in `/dev`. Programs in `/bin` are
   files too: they can be copied, renamed, deleted and chmod-ed.
4. **Accurate to the real tools.** Programs match the real Linux tools of the
   era in behaviour and output (see [the requirements](../development/conventions.md#requirements)).
   Every simplification sits behind an interface that can grow, and is listed in
   [simplifications](../reference/simplifications.md).
5. **Simulated, sandboxed.** Everything happens inside Godot: no real sockets,
   no real network. A machine's disks are virtual and saved with its world. The
   player's real disk is reachable only through an explicit host mount
   (`AgoraMachine.mount_host`).

## The layers

```
 front ends   main.gd (desk, 3D view)   tools/repl.gd   a game
 ───────────────────────────────────────────────────────────────────
 GUI          AgoraDisplayView, AgoraTermView, AgoraHardwareView3D (gui/)
 programs     sh, coreutils, daemons, GUI apps        (kernel/bin, system, gui/apps)
 kernel       AgoraMachine: VFS, processes, ttys, network stack   (kernel/)
 firmware     AgoraBios, AgoraGrub                    (hardware/)
 hardware     AgoraHardware: disks, NICs, cables, CMOS; AgoraWorld (hardware/)
```

A world (`AgoraWorld`) holds boxes (`AgoraHardware`) and the cables between
them under one clock. Powering a box on runs its firmware, which finds a boot
device, runs GRUB and starts a kernel (`AgoraMachine`) on the root disk. The
kernel runs `/sbin/init`, which starts the services; the services and the
programs people run are coroutines in that kernel.

## Source layout

```
addons/agora_os/
  kernel/
    machine.gd      AgoraMachine    one running kernel: vfs, users, processes, spawn, login,
                                    the kernel command line, klog, power, save/load
    vfs.gd          AgoraVfs        one tree of mounted backends; path resolution; permissions
    fs/             AgoraFs backends: mem_fs (disks, saved), host_fs (a real directory),
                    proc_fs, sys_fs, dev_fs
    process.gd      AgoraProcess    pid, cred, cwd, env, streams, tty, signals, file calls
    program.gd      AgoraProgram    base class of every executable
    programs.gd     AgoraPrograms   explicit registry: name -> script, and install paths
    stream.gd       AgoraStream     pipes: counted ends, EOF, broken pipe
    tty.gd          AgoraTty        a terminal line: canonical or raw, echo, size, foreground
    users.gd        AgoraUsers      passwd, group, shadow
    cred.gd         AgoraCred       uid, gid, ruid, groups, umask
    clock.gd        AgoraClock      game time: any date, any speed; follow() for box clocks
    installer.gd    AgoraInstaller  formats a disk, installs a profile, configures, GRUB
    args.gd, path.gd, stat.gd, errno.gd   getopt, paths, stat, errno
    mime.gd         AgoraMime       file types and default applications
    mbox.gd         AgoraMbox       mbox files (mail, popa3d, Pigeon)
    html.gd         AgoraHtml       HTML for lynx
    shell/          lexer and parser of sh
    net/            the network stack (see networking.md)
    display/        AgoraDisplay (display server), AgoraWindow
    bin/            programs: sh, coreutils, util-linux, net tools, clients
  hardware/
    hardware.gd     AgoraHardware   the box; power, boot order, the sync firmware path
    disk.gd, nic.gd, cable.gd       AgoraDisk, AgoraNic, AgoraCable
    cmos.gd         AgoraCmos       BIOS settings
    bios.gd         AgoraBios       POST, boot menu, boot devices; the router's CFE
    bios_setup.gd   AgoraBiosSetup  the Setup screens
    grub.gd         AgoraGrub       GRUB 0.97: menu.lst, commands, update-grub's menu, MD5-crypt
    grub_menu.gd    AgoraGrubMenu   GRUB's menu, editor and command line
    fw_screen.gd    AgoraFwScreen   80x25 screen and raw keyboard on a tty
    world.gd        AgoraWorld      boxes and cables under one clock, saved as one file
    world_spec.gd, box_spec.gd, cable_spec.gd   a world as a resource (.tres)
  system/           the distribution: distro.gd (packages, profiles), packages.gd,
                    archive.gd, fetch.gd, media.gd (install CD), apkg; init systems,
                    daemons and their tools (see the other chapters)
  gui/
    display_view.gd AgoraDisplayView    a display in the scene tree ("the monitor")
    term_view.gd    AgoraTermView       terminal emulator widget
    gui_program.gd  AgoraGuiProgram     base of windowed programs
    html_view.gd    AgoraHtmlView       the browser engine (Kestrel, Pigeon)
    gif.gd, gif_texture.gd              GIF decoder, animated texture
    dialog.gd, style.gd                 dialogs; font and icons
    wm/             window frames and themes
    apps/           greeter, wm, panel, desktop, terminal, files, edit, view, open,
                    kestrel, pigeon, pingmsg
    view3d/         AgoraHardwareView3D: the hardware in 3D
    fonts/          DejaVu Sans Mono (see CREDITS.md)
assets/             3D models (.glb)
main.gd, main.tscn  the demo front end
worlds/             world specs (home.tres) and the files copied onto their boxes
tests/run_tests.gd  the test suite
tools/              repl.gd (console front end), gen_docs.gd (programs reference)
```

## Key mechanisms

### Processes are coroutines

`AgoraProgram.main(p)` may `await`. Blocking reads, `sleep` and waiting for a
child suspend the coroutine. There are no threads.

Godot resumes awaiting coroutines synchronously inside `emit()`. When one stage
of a pipeline writes, the next stage runs at once, nested in the same call. The
shell creates every stage of a pipeline first and starts them last to first, so
readers are already waiting before writers produce anything. Programs that loop
for a long time call `await p.tick()` so the engine keeps drawing.

### Streams

An `AgoraStream` counts its writers and readers. When the last writer goes,
readers see end-of-file. When the last reader goes, writes fail and the writer
gets SIGPIPE, which is how `yes | head` stops. A terminal's input is a stream
too: keys typed while nothing reads it are lost, which is why the firmware
registers itself as a reader (`AgoraFwScreen.begin`).

### Signals

`send_signal` runs the program's `signal_handler` first, if it has one;
otherwise the default action ends the process with status 128 + signal. When a
process ends its streams are released, which wakes any blocked read, so a
killed process never hangs. Ctrl+C on a tty sends SIGINT to `tty.foreground`,
which the shell sets around each job.

### Executables

A native binary is a text file that starts with `\x7fAGX <name>`; running it
looks `<name>` up in `AgoraPrograms`. Scripts that start with `#!` run through
their interpreter. The setuid bit is honoured on binaries (`su`, `sudo`,
`passwd`, `exim4`, `crontab`) and ignored on scripts.

### Permissions

`AgoraVfs.can_access` checks owner/group/other rwx. Root bypasses everything
except executing a file with no x bit. Removing an entry needs w and x on its
directory; in a sticky directory only the owner of the entry or of the
directory may remove it.

### Persistence

A box is saved with all its disks, its CMOS and the clock
(`AgoraHardware.save`, zstd-compressed); a world saves all its boxes, cables
and which boxes were on. Mounts, processes and kernel state (addresses, routes,
firewall rules) are not saved: a loaded box boots fresh and configures itself
from its files, as a real one does after a power cut.

## The chapters

- [Kernel](kernel.md): the machine, file systems, processes, the shell, users, terminals, clocks.
- [Hardware](hardware.md): boxes, disks, network cards and cables, consoles, the 3D view.
- [Firmware and boot](boot.md): BIOS, CMOS, GRUB, the kernel command line, init.
- [Networking](networking.md): the stack, netfilter, TCP, names, capture, the router.
- [Services](services.md): inetd, telnet, FTP, the web, mail, Ping!, the search engine.
- [Packages](packages.md): the distribution, apkg and archives, building packages, the installer.
- [Graphics](gui.md): display server, window manager, session, apps, the browser engine.
- [Worlds](worlds.md): worlds, their specs, and the home world.
