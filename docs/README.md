# AgoraOS documentation

AgoraOS is a Unix-like operating system of the early 2000s simulated in Godot:
boxes with firmware, disks and network cards, a kernel with a VFS, processes and
a shell, Debian-like tools and services, an X11-style desktop. It is built to be
embedded in a game.

## Start here

- [Getting started](getting-started.md): run the demo, the console front end
  and the tests.
- [Roadmap](ROADMAP.md): what is done, what is being worked on, what comes next.

## Architecture

How it works, layer by layer.

- [Overview](architecture/overview.md): principles, layers, source layout, the
  key mechanisms (coroutines, streams, signals, executables, persistence).
- [Kernel](architecture/kernel.md): the machine, file systems, processes, the
  shell, users, terminals, clocks.
- [Hardware](architecture/hardware.md): templates, disks, network cards and
  cables, power and consoles, the 3D view.
- [Firmware, boot and init](architecture/boot.md): BIOS, CMOS, GRUB, the kernel
  command line, sysvinit and systemd.
- [Networking](architecture/networking.md): the stack, netfilter, names,
  capture, the router, ssh.
- [Services](architecture/services.md): inetd, telnet, FTP, the web, mail,
  Ping!, the search engine.
- [Packages](architecture/packages.md): the distribution, apkg and archives,
  building packages, the installer.
- [Graphics](architecture/gui.md): display server, window manager, session,
  apps, the browser engine.
- [Worlds](architecture/worlds.md): worlds, world specs, the home world, the
  demo.

## Reference

- [Programs and packages](reference/programs.md): every package and program
  (generated from the code).
- [Simplifications and gaps](reference/simplifications.md): where the
  simulation is simpler than the real thing.

## Development

- [Conventions](development/conventions.md): requirements, code, docs, commits.
- [Testing](development/testing.md): the suite, its helpers, screenshots.
- [Extending](development/extending.md): machines, worlds, programs and devices
  from a game.
