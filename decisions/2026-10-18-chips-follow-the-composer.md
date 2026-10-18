# Chips follow the composer; a material deletes from the grid

2026-10-18. Status: accepted. Beads: bezalel-37q, bezalel-xa6. Supersedes
the "goes only to the conversation it was started in … (or isn't added as
a chip there)" part of `2026-10-18-materials-on-the-phone.md` ("Sending
with materials"); the rest of that record stands.

## Context

Kevin (2026-10-18): the chips over the question box (a material picked,
not yet sent) were cleared whenever another conversation opened. They
should stay until they're sent or removed. And each material should be
deletable straight from the Materials grid, not only from its detail.

## Decision

- **Chips belong to the composer, not to a conversation.** Opening another
  conversation (the Conversations tab, a new one, "Went with" in Materials,
  the Workshop) keeps them, with the words heard under a recording's chip;
  they go with the next question sent, wherever it's asked. The words typed
  still clear on a switch: they're about the conversation left.
- **Something still being added when the user switches** (a photo being
  hashed, a recording being kept) lands as a chip where they are now; no
  more "you'd moved to another conversation" toast. A still kept from the
  picker opened by the composer is a chip the same way.
- **A question whose materials were being made ready when the user moved
  on** isn't sent (it was for the conversation left), and its chips come
  back to the composer where they are now, before anything added
  meanwhile, with a toast saying so; its words come back only in its own
  conversation. The same when its materials couldn't be made ready. If
  the user is back in its conversation by the time they're ready, it goes:
  it's where they asked it, and nothing else of theirs was sent meanwhile.
  A material deleted while they were made ready stops the question (it
  comes back as for any material not found), even if its attachment was
  already built. A question asked again (Try again) is unchanged: it keeps
  its Try again in its conversation.
- **"Went with" means sent with.** A material picked from the + menu is no
  longer linked to the conversation open when it was added, only to the
  one its question goes to (`Study.send_prepared/5` links it). A still
  stays linked to the conversation open when it was kept
  (`2026-10-18-video-stills.md`).
- **Not across a restart.** Chips live in the screen's assigns, so they
  last as long as the app runs. Keeping them over a restart would need
  their ids in `Mob.State`, a fetch per id at mount and dropping deleted
  ones, and a transcript being made wouldn't resume; a restart is rare next
  to a switch, and the material is in Materials anyway (Ask about this puts
  it back).
- **Deleting a material drops its chip**, and the chips of what's deleted
  with it (a video's stills, its transcript): every chip whose material is
  gone after the delete, also among a question's chips coming back.
- **The grid's ×**: each card in the Materials tab has an × over its
  top-right corner (a 40 pt target with button role and a "Delete <name>"
  label, a 26 pt round badge on `:surface` so it reads over a picture).
  It asks the same question as the detail's Delete
  (the `{:delete_material, id}` sheet, "Keep it" backs out), then deletes
  the same way (`MaterialStore.delete/1`: its transcripts, audio tracks and
  stills made from it alone; a drawing made from it stays). No Undo, as for
  the detail's Delete. Materials still stay when a conversation they went
  with is deleted.

## Consequences

- A question can carry materials the user picked while in another
  conversation; the chip row is the only place that says what goes with it.
- `Bezalel.Views.Attach.kept/2` and `handle_async({:keep, ref}, …)` no
  longer carry a conversation id; `Study.send_prepared/5` keeps its
  moved-on check only for a question asked again.
- The website (bezalel_ca, same day) has the same rule with three
  differences: its chips survive a reload (kept per user); a question
  left before its files were ready stays in its own conversation for Try
  again rather than giving its chips back; and its grid × deletes at once
  with an Undo toast, as its detail's Delete does there.
