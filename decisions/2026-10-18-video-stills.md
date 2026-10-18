# Video stills

2026-10-18. Status: accepted. Bead: bezalel-at6.10 (the rest of it; the
notice and the audio-track transcript came with
`2026-10-18-materials-on-the-phone.md`). Contracts: bezalel_core's
`decisions/2026-10-18-materials.md` (a still is a `:still` derivative,
its time in `meta.at_ms`).

## Context

A video goes to the model as the transcript of its audio track. Kevin
asked for stills too: the user picks moments of a video, and those go to
the model as pictures (and the agent can draw from them). mob_media
(6f9422d) gives the length (`MobMedia.info/2`) and a frame at a time
(`MobMedia.frame/3`, exact, upright, a JPEG).

## Decisions

- **A sheet with a scrubber** (`Bezalel.Views.Stills`): a slider over the
  video's length, the time (m:ss.t) under it, and the frame there above.
  The frame is made off the screen (`start_async`) once the slider rests
  for 250 ms; a newer one replaces one still being made. Frames are 1280 px
  on the longest side: the preview is the still kept, so the user keeps
  exactly what they saw, and it's under the size providers take as is.
- **Where it opens**: from a video's detail in Materials (**Pick a
  still**), and by itself right after a video is added to a question (the
  user just chose that video to ask about). From the composer, each still
  kept also waits as a chip; from Materials it doesn't (the stills are
  listed under the video, each with **Ask**, which puts it on the question).
- **Keep this still** stores the frame shown as
  `Materials.derive(:still, video, jpeg, meta: %{at_ms: ...})`, linked to
  the conversation open. A still is an image material: it goes to the model
  as a picture, and its ref works in draw_image's `references`. Deleting
  the video deletes its stills (`MaterialStore.delete/1`, as before).
- Previews live under the cache's `stills/`, one file per time, removed
  as they're replaced and when the picker closes.

## Consequences

- A video the platform can't decode, or one with no picture, says so in
  the sheet; nothing can be kept.
- The Materials grid doesn't list stills on their own (derivatives show
  with what they came from); they're under their video.
