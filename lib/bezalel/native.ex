defmodule Bezalel.Native do
  @moduledoc """
  The phone's native calls the Materials features make (pickers, camera,
  microphone, the voice, permission prompts, photo thumbnails), in one
  place so host tests can stand in for them: `config :bezalel, :native`
  names the module (`Bezalel.Native.Mob`, the real one, by default; tests
  use one that records each call). Each call answers as the plugin does:
  results come later as messages to the screen (`{:photos, :picked, …}`,
  `{:camera, :photo, …}`, `{:files, :picked, …}`, `{:audio, :recorded,
  …}`, `{:permission, …}`, `{:speech, :done | :cancelled | :failed}`),
  except `thumbnail/2` and `voices/0`, which return.
  """

  @callback pick_photos(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  @callback capture_photo(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  @callback capture_video(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  @callback pick_files(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  @callback request_permission(Mob.Socket.t(), atom()) :: Mob.Socket.t()
  @callback start_recording(Mob.Socket.t()) :: Mob.Socket.t()
  @callback stop_recording(Mob.Socket.t()) :: Mob.Socket.t()
  @callback play(Mob.Socket.t(), Path.t()) :: Mob.Socket.t()
  @callback stop_playback(Mob.Socket.t()) :: Mob.Socket.t()
  @callback speak(Mob.Socket.t(), String.t(), keyword()) :: Mob.Socket.t()
  @callback stop_speaking(Mob.Socket.t()) :: Mob.Socket.t()
  @callback voices() :: {:ok, [map()]} | {:error, :unavailable | :unsupported}
  @callback thumbnail(Path.t(), keyword()) :: {:ok, %{path: Path.t()}} | {:error, term()}

  @doc "The photo library's picker (mob_photos): `{:photos, :picked | :cancelled, …}`."
  def pick_photos(socket, opts \\ []), do: impl().pick_photos(socket, opts)

  @doc "The camera for a photo (mob_camera): `{:camera, :photo | :cancelled, …}`."
  def capture_photo(socket, opts \\ []), do: impl().capture_photo(socket, opts)

  @doc "The camera for a video (mob_camera): `{:camera, :video | :cancelled, …}`."
  def capture_video(socket, opts \\ []), do: impl().capture_video(socket, opts)

  @doc "The system file picker (`Mob.Files`): `{:files, :picked | :cancelled, …}`."
  def pick_files(socket, opts \\ []), do: impl().pick_files(socket, opts)

  @doc "Asks for a permission (`Mob.Permissions`): `{:permission, capability, result}`."
  def request_permission(socket, capability), do: impl().request_permission(socket, capability)

  @doc "Starts recording the microphone (`Mob.Audio`, WAV where the platform records it)."
  def start_recording(socket), do: impl().start_recording(socket)

  @doc "Stops the recording: `{:audio, :recorded, %{path, duration}}` or `{:audio, :error, …}`."
  def stop_recording(socket), do: impl().stop_recording(socket)

  @doc "Plays an audio file (`Mob.Audio`): `{:audio, :playback_finished, …}` when it ends."
  def play(socket, path), do: impl().play(socket, path)

  @doc "Stops playing."
  def stop_playback(socket), do: impl().stop_playback(socket)

  @doc """
  Says `text` with the platform's voice (`Mob.Speech`), `voice:` a voice
  id from `voices/0` (else the system default). The caller gets one
  `{:speech, :done | :cancelled | :failed}` when it ends.
  """
  def speak(socket, text, opts \\ []), do: impl().speak(socket, text, opts)

  @doc "Stops speaking: each utterance not yet ended sends `{:speech, :cancelled}`."
  def stop_speaking(socket), do: impl().stop_speaking(socket)

  @doc """
  The phone's text-to-speech voices (`Mob.Speech.voices/0`), sorted by
  language, then quality. Blocks (on Android up to 5 s the first time):
  call it from `start_async`.
  """
  def voices, do: impl().voices()

  @doc "A downscaled upright JPEG of a picture file (mob_photos), synchronous."
  def thumbnail(path, opts), do: impl().thumbnail(path, opts)

  defp impl, do: Application.get_env(:bezalel, :native, Bezalel.Native.Mob)
end

defmodule Bezalel.Native.Mob do
  @moduledoc "The phone's own calls (`Bezalel.Native`)."
  @behaviour Bezalel.Native

  @impl true
  def pick_photos(socket, opts), do: MobPhotos.pick(socket, opts)

  @impl true
  def capture_photo(socket, opts), do: MobCamera.capture_photo(socket, opts)

  @impl true
  def capture_video(socket, opts), do: MobCamera.capture_video(socket, opts)

  @impl true
  def pick_files(socket, opts), do: Mob.Files.pick(socket, opts)

  @impl true
  def request_permission(socket, capability), do: Mob.Permissions.request(socket, capability)

  # WAV, which Bezalel turns into Whisper's PCM itself (Bezalel.Transcribe);
  # Android's recorder makes an m4a whatever the format, which goes through
  # mob_media like any other compressed recording.
  @impl true
  def start_recording(socket), do: Mob.Audio.start_recording(socket, format: :wav)

  @impl true
  def stop_recording(socket), do: Mob.Audio.stop_recording(socket)

  @impl true
  def play(socket, path), do: Mob.Audio.play(socket, path)

  @impl true
  def stop_playback(socket), do: Mob.Audio.stop_playback(socket)

  @impl true
  def speak(socket, text, opts), do: Mob.Speech.speak(socket, text, opts)

  @impl true
  def stop_speaking(socket), do: Mob.Speech.stop_speaking(socket)

  @impl true
  def voices, do: Mob.Speech.voices()

  @impl true
  def thumbnail(path, opts) do
    MobPhotos.thumbnail(path, opts)
  rescue
    # A build without mob_photos' NIF (a host run).
    e in [ErlangError, UndefinedFunctionError] -> {:error, {:unavailable, Exception.message(e)}}
  end
end
