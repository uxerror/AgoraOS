# Testing

## Running the tests

```sh
godot --headless --import                         # once after adding class_name scripts
godot --headless --path . -s tests/run_tests.gd   # everything, a few minutes
TEST_ONLY=test_grub,test_bios godot --headless --path . -s tests/run_tests.gd
TRACE_TESTS=1 godot --headless --path . -s tests/run_tests.gd   # print each test's name
```

The suite exits with 0 when everything passes and prints `N checks, M failed`.
It takes a few minutes because network timeouts, POST and GRUB pauses run in
real time.

## Writing tests

All tests are in `tests/run_tests.gd`, one `test_*` function per area, listed
in `_run_all`. Helpers:

- `make_machine(hostname, extra)`: a booted virtual machine with root
  (`toor`), alice (`wonderland`, sudo) and bob (`builder`); `extra` goes to the
  installer (`template`, `profile`, `init`, `network`...). It is shut down after
  the test.
- `run(m, cmd, user)`: runs `sh -c cmd` and returns `{out, err, code}`.
  `start(m, cmd, user)` runs it in the background.
- `until(cond, frames)`: waits for a condition. Never wait with fixed delays.
- `check(cond, what)`, `check_eq(actual, expected, what)`: put the actual value
  into `what` so a failure shows it.
- Register machines you make yourself in `_machines` (and set
  `_owned_hardware` for hardware you built) so they are shut down.
- `cmdline_machine(cmdline, init)`: a machine not booted yet, to boot with a
  kernel command line.
- Firmware: set `hardware.interactive`, collect the console's output, and use
  `frame(text)` (the screen since the last clear, without escapes) and
  `keys_when(screen, shown, tty, keys)` (type keys once something is shown).
  Key sequences are constants (`K_DEL`, `K_F10`, `K_F12`, `K_UP`, `K_DOWN`,
  `K_ESC`).

Wait for state, not time: a reboot is done when `m.boot_time` has changed and
the service you need listens, not when the machine is running (it was running
before the reboot too).

## Screenshots

The headless tests can't render. To see a screen, run a small script under
Xvfb that builds the scene, drives it and saves the root viewport:

```gdscript
extends SceneTree
func _initialize() -> void:
	root.size = Vector2i(760, 470)
	var hw := AgoraHardware.from_template("pc")
	AgoraInstaller.install_disk(hw.disks[0], "desk", {}, hw.clock)
	hw.interactive = true
	var view := AgoraTermView.new()
	view.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(view)
	view.attach(hw.console)
	hw.power_on()
	await create_timer(1.5).timeout
	root.get_texture().get_image().save_png("/tmp/post.png")
	quit()
```

```sh
xvfb-run -a -s "-screen 0 1024x768x24" godot --path . -s /path/to/shots.gd
```

Keep such scripts outside the repository (they are throwaway).
