# Tickets and roadmap

Since 2026-11-27 the project's tickets and its planning roadmap live in the
owner's private project tracker (OpenProject, project `mohiworks`), not in
files of this repository. The tracker's address is not written here: it is
in the workspace's local rules file, which is never committed.

This file is the note every agent reads first.

## Tags and who works on what

Every ticket (work package) carries exactly one of three tags:

| Tag | Scope | Worked by |
|-----|-------|-----------|
| `FPS` | in-world frame rate: memory sync, copy-back, texture checks, pacing | the FPS agent |
| `Frames` | picture correctness: black screens, shaders, pipelines, models, textures, lighting, the upscaler | the Frames agent |
| `Socials` | posts, demo videos, the community tracker, README claims | the Socials agent |

An agent works only on tickets with its own tag. Work that crosses tags gets
one ticket per tag, linked to each other.

## Rules

- One ticket in progress per agent; the owner reviews a ticket before the
  next one starts.
- A ticket is done only with proof attached or linked: a harness result
  folder and, for anything that reaches the screen, saved frames.
- New work is a new ticket in the tracker first; do not start a queue in a
  document.
- Tickets must not name the title, and must not name the owner's personal
  account.
- The tracker runs on a production server: agents do not log in to that
  server to edit it. Tickets are created and updated through the tracker
  itself (web or its API with the credentials the owner provides).

## The earlier queues

These documents hold the queues and decision records written before the
tracker; they are sources to migrate from, not places to add to:

- `docs/decision-record.md` (branch `main`): won, lost, drifted, open.
- `docs/frames-decisions.md` (branch `depth-float`): tickets FR-00 to FR-10.
- `docs/fps-queue.md` and `docs/fps-decision-record.md` (branch `fps`).

Until an item is migrated, its ID in those documents stays its reference.
