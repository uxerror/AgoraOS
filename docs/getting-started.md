# Getting started

You need Godot 4.7.

## The demo

```sh
godot --path .                       # or F5 in the editor
godot --path . -- --preinstalled     # a ready desktop: user/user, root/root
```

You get the world in `worlds/home.tres`: an evening in October 2003, a PC with
a monitor and a home router, cabled to a small internet. The provider (LanLink)
hands the router an address and runs the name server; behind its switch are web
search engine whose crawler really walks those sites (`lynx www.ferret.org`).
servers with era sites, a messenger server, a package mirror and Ferret, a
See [worlds](architecture/worlds.md) for what is where.

The first time, the PC is empty with the install CD in its drive. It goes
through the BIOS (DEL for Setup, F12 for the boot menu) and boots the CD; the
installer runs on the text console (choose DHCP for the network). After the
install it reboots into GRUB's menu and the new system.

- The bar at the top switches between the boxes, like a KVM switch (Scroll Lock
  does the same), and has their power buttons.
- Boxes without a monitor are reached through their serial console. The
  router's root password is `admin`.
- "3D" shows the box itself: press its buttons, open the CD tray, pull cables,
  open the case.
- The whole world, every disk and cable included, is saved to
  `user://worlds/home.agw` when the window closes. Delete that file to start
  over.

## The console front end

No GUI, one machine and a server cabled to it:

```sh
godot --headless --path . -s tools/repl.gd            # resume its saved machine
godot --headless --path . -s tools/repl.gd -- --fresh # start over
```

Log in as `user` / `user` (sudo allowed); root's password is `root`. The other
machine is `ssh admin@server.lan` (10.0.0.7), password `admin`.

## Tests

```sh
godot --headless --import
godot --headless --path . -s tests/run_tests.gd
```

See [testing](development/testing.md).

## Where to go next

- [Architecture overview](architecture/overview.md) and its chapters.
- [Programs and packages](reference/programs.md): everything you can run.
- [Roadmap](ROADMAP.md): what is done and what comes next.
- [Extending](development/extending.md): using AgoraOS in a game.
