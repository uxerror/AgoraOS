# Clean-room record

AgoraOS is an independent, MIT-licensed implementation inspired by the
*functionality* of GodotOS (https://github.com/popcar2/GodotOS, AGPL-3.0).
No code, scene files, text or assets from GodotOS are used in this project.

## Process

| Date | Step | Who |
|---|---|---|
| 2026-10-17 | An analyst agent cloned GodotOS (shallow clone, last upstream commit dated 2026-03-09) into an isolated temporary directory outside this repository. It only read the files there and ran nothing. | Analyst (separate Claude subagent) |
| 2026-10-17 | The analyst wrote a behavioral specification (since removed, see below). Rules it followed: no code or pseudo-code, no original identifiers, file layout or node trees, no copied prose, no assets. | Analyst |
| 2026-10-17 | The spec was checked automatically for code-like content and original identifiers. Nothing was found. | Implementer |
| 2026-10-17 | The temporary clone was deleted. From now on, open questions are decided independently and never by consulting the original. | Implementer |
| 2026-10-17 | The kernel was implemented from our own design: VFS, users, processes, shell, multiple machines. None of this exists in the original. | Implementer (main Claude session, directed by uxerror) |
| 2026-10-17 | The project's direction moved away from a desktop toy to a deep Unix simulation, and the spec was judged no longer relevant. It was deleted from the repository before any GUI work started. The GUI is designed from scratch around the kernel's Unix architecture (display server, window manager and panel as separate programs). | uxerror, implementer |

## Rules for contributors

- Do not open, copy or paraphrase GodotOS source code, scenes or assets while working on AgoraOS.
- Assets must be original, or carry a licence compatible with MIT distribution, with attribution recorded in `CREDITS.md`.
- Do not use the Godot logo or the GodotOS name as branding.

## Caveat

The implementer is an AI model trained on public code. GodotOS may have been in
its training data. To counter this, the architecture, naming and structure were
deliberately designed from scratch and differ substantially from the original.
