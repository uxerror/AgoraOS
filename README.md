# AgoraOS

A Unix-like operating system simulated in Godot 4.7: a virtual file system,
users and permissions, processes, pipes and a shell, with an X11-style
graphics layer on top. It is designed to be embedded in games.

MIT licensed. The idea started from GodotOS, but no code, text or assets from it
are used; see [CLEANROOM.md](CLEANROOM.md).

## Try it

Run the project (`godot --path .`, or press F5 in the editor). The first time,
you get an empty PC with the install CD in its drive, and the installer runs on
the text console. Answer its questions and it reboots into the new system. To
skip installation, start with `godot --path . -- --preinstalled`, then log in as
`user` / `user`. The whole PC, disks included, is saved when you close the
window.

Or use the console front end, with no GUI:

```sh
godot --headless --path . -s tools/repl.gd            # resume the saved machine
godot --headless --path . -s tools/repl.gd -- --fresh # start over
```

You log in as `user` (password `user`, allowed to use sudo). The root password
is `root`. Another machine is on the network: `ssh admin@server.lan`, password
`admin`.

## Tests

```sh
godot --headless --path . -s tests/run_tests.gd
```

## Docs

- [docs/architecture.md](docs/architecture.md): how the kernel works and how to extend it
