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
   them and connect them with an `AgoraNetwork`.
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
  network.gd      AgoraNetwork   flat network: ip/hostname -> machine
  mime.gd         AgoraMime      file types (/etc/mime.types) and default apps (.desktop, mimeapps.list)
  shell/          lexer + parser for sh
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
main.tscn            demo front end: one machine with a monitor
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
`AgoraMachine.save_image` stores the root memfs, the clock and the IP in a
zstd-compressed file. Mounts and processes are not saved: a loaded machine boots fresh.

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
- **New machine:** call `AgoraMachine.create(hostname, {users, root_password, motd, programs})`,
  then attach it to the network with `network.attach(machine, ip, dns_name)`.
- **Game time:** call `clock.set_time(unix)` and `clock.set_speed(x)`. Several machines can
  share one clock.

## Not done yet (planned)

- Shell control flow (`if`, `for`, `while`, functions) and job control (`fg`, `bg`).
- Drag and drop between windows. Symlink badges on icons.
- Network depth: ports and services, firewalls, routing, `scp`/`ftp`/`telnet`.
- Hard links, file locking, and quotas.
