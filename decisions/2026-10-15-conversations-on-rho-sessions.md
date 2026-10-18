# Conversations are rho sessions; Delete and Undo are branch moves
- Date: 2026-10-15
- Status: accepted

## Context
The live agent keeps its own transcript (rho JSONL sessions). Keeping a second
copy of every message in SQLite meant replaying it into the loop and two
sources of truth.

## Decision
The session file is the transcript; SQLite keeps only the shelf. Delete starts
a new branch without the message; Undo returns to the earlier leaf (copying
anything added since). A one-time migration moved old conversations.

## Consequences
The model sees exactly what the chat shows. Messages after a deleted one get
new ids (copied onto the new branch). Session files only grow. See
lib/bezalel/library/transcript.ex (since 2026-10-17 in bezalel_core:
decisions/2026-10-17-agent-surface-in-bezalel-core.md).
