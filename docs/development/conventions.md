# Conventions

## Requirements

These come from the project's owner and apply to all work:

- The game is accurate and aimed at people who understand Unix and networking.
  Tools match the real Linux tools of the era (Debian Etch, around 2003-2007) in
  behaviour and output: messages, formats, exit codes, file locations.
- Everything is simulated inside Godot. No real sockets and no real network.
- Work in small steps. Commit after each one, once the tests are green.
- Authored data is Godot-native (`.tres` resources), not JSON.
- The project is an MIT-licensed clean-room work: nothing from GodotOS (see
  [CLEANROOM.md](../../CLEANROOM.md)). Assets must be original or MIT-compatible,
  recorded in [CREDITS.md](../../CREDITS.md). Names of hardware vendors and
  products in the world are fictional.

## Code

- GDScript 4.7. There are no octal literals: write modes in decimal with an
  octal comment (`493 # 0o755`).
- Don't name members `_set`, `theme`, `load`, `get_script`, `script` or
  `connect`; they clash with built-ins.
- Typed variables: when a value comes from a Dictionary or a Variant, write
  `var x: T =` instead of `:=`.
- Packed arrays are values: `(d.lines as PackedStringArray).append(x)` changes a
  copy. Take the array out, change it, put it back.
- A Callable to a method of a RefCounted doesn't keep it alive (pass the clock
  to `AgoraInstaller.target_vfs`).
- New `class_name` scripts need `godot --headless --import` once before the
  tests see them.
- Programs extend `AgoraProgram`, are registered in `kernel/programs.gd` (with a
  path in `PATHS` or `SBIN` if not `/bin`), and belong to a package in
  `system/distro.gd`. Router applets go into `BUSYBOX_APPLETS`; an applet checks
  `multicall == "busybox"` to print busybox's format.
- Callables stored on long-lived objects (signal handlers, connections to
  lambdas) must be dropped when the process or connection ends, or they keep
  the objects alive.
- A process that reads a terminal must be its reader (`add_reader`), or keys are
  dropped as on a broken pipe once nothing else reads it.
- Comments say why, in the style of the surrounding code: full sentences,
  doc comments (`##`) on classes and public functions.

## Documentation

- Change the docs in the same commit as the code they describe: the chapter in
  `docs/architecture/`, the [roadmap](../ROADMAP.md) (move items to Done, add
  what was found), [simplifications](../reference/simplifications.md) for what
  was left out.
- After changing packages or program summaries, regenerate the programs
  reference: `godot --headless --path . -s tools/gen_docs.gd`.
- Docs and code are in English.

## Commits

- Author `uxerror`. Subject `area: what changed`, in plain words (`grub: ...`,
  `net: ...`, `view3d: ...`), a body saying what and why, and the line
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- The full test suite is green before every commit.
