# Save pictures to the phone's photos through mob_photos

Status: accepted (2026-10-19)

## Context

Kevin wants to keep a picture from the app (a drawing, a photo or video
still in Materials, a picture in a reply) in the phone's own photo library.
mob core already had `Mob.Storage.Apple.save_to_photo_library/2` and
`Mob.Storage.Android.save_to_media_store/3`, but they are two platform
modules with different answers, the Android one runs on the calling thread,
inserts with a wildcard MIME (`image/*`) and no album folder, and its
failures arrive as `{:storage, :error, "save_failed"}`, not the documented
shape. mob_photos owns the photo library (picker, listing, thumbnails) and
had no save.

## Decision

- Save through a new `MobPhotos.save/3` (mob_photos), one API for both
  platforms: `{:photos, :saved, %{path, uri}}` / `{:photos, :save_failed,
  %{path, reason}}`. Android: a pending MediaStore item under
  `Pictures/Bezalel` (the `album:` option), copied on the bridge's own
  thread. iOS: add-only access (`PHAccessLevelAddOnly`), so saving never
  asks to read the library; iOS has no album (that needs read-write).
- Ask for the `:media_save` capability before each save
  (`Bezalel.Views.SavePicture`): it is the iOS add-only prompt (asked
  once), Android 9's `WRITE_EXTERNAL_STORAGE`, and granted without a dialog
  on Android 10+. A refusal, then or at save time, is one toast that says
  where to allow it.
- Save the picture at full size: a material's own file, or a session's
  picture decoded once from the session (`Bezalel.Images.original/2`),
  never the chat's downscaled copy.
- Entry points: the viewer's Save, Save to Photos on a picture material's
  detail, and a long press on a picture in the chat (the platform's action
  sheet: Save to Photos, Open).

## Consequences

- Host tests drive the whole flow with `MobPhotos.Fake`
  (`config :mob_photos, nif: MobPhotos.Fake`): the saved file's bytes are
  checked, not just the call.
- A session picture's full-size file is kept beside its sized copies under
  `images/<session id>/`, so a conversation's purge removes it with them.
- Core's `Mob.Storage` save functions stay unused here.
