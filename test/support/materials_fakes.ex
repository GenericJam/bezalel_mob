defmodule Bezalel.Test.Native do
  @moduledoc """
  The phone's native calls in tests (`config :bezalel, :native`): each call
  is recorded, in order, for `calls/0`; nothing reaches a picker, the
  camera, the microphone or a voice. `thumbnail/2` answers what
  `put_thumbnail/1` set (a file it copies to a fresh path, as mob_photos
  writes one), else `{:error, :unavailable}`; `voices/0` what
  `put_voices/1` set, else `{:error, :unsupported}` (as off device).
  """
  @behaviour Bezalel.Native

  @table __MODULE__

  @doc "Creates the table (owned by the caller, which must outlive the tests)."
  def start, do: :ets.new(@table, [:named_table, :public, :ordered_set])

  @doc "Forgets the recorded calls, the thumbnail and the voices."
  def reset, do: :ets.delete_all_objects(@table)

  @doc "The calls made since the last `reset/0`, oldest first: `{name, args}`."
  def calls, do: for({{:call, _n}, call} <- :ets.tab2list(@table), do: call)

  @doc "The names of the calls made since the last `reset/0`."
  def names, do: Enum.map(calls(), &elem(&1, 0))

  @doc "Makes `thumbnail/2` answer with a copy of the file at `path`."
  def put_thumbnail(path), do: :ets.insert(@table, {:thumbnail, path})

  @doc "Makes `voices/0` answer `result` (`{:ok, voices}` or `{:error, reason}`)."
  def put_voices(result), do: :ets.insert(@table, {:voices, result})

  defp record(name, args) do
    :ets.insert(@table, {{:call, System.unique_integer([:monotonic])}, {name, args}})
  end

  @impl true
  def pick_photos(socket, opts), do: tap(socket, fn _ -> record(:pick_photos, opts) end)
  @impl true
  def capture_photo(socket, opts), do: tap(socket, fn _ -> record(:capture_photo, opts) end)
  @impl true
  def capture_video(socket, opts), do: tap(socket, fn _ -> record(:capture_video, opts) end)
  @impl true
  def pick_files(socket, opts), do: tap(socket, fn _ -> record(:pick_files, opts) end)
  @impl true
  def request_permission(socket, cap),
    do: tap(socket, fn _ -> record(:request_permission, cap) end)

  @impl true
  def start_recording(socket), do: tap(socket, fn _ -> record(:start_recording, nil) end)
  @impl true
  def stop_recording(socket), do: tap(socket, fn _ -> record(:stop_recording, nil) end)
  @impl true
  def play(socket, path), do: tap(socket, fn _ -> record(:play, path) end)
  @impl true
  def stop_playback(socket), do: tap(socket, fn _ -> record(:stop_playback, nil) end)
  @impl true
  def speak(socket, text, opts), do: tap(socket, fn _ -> record(:speak, {text, opts}) end)
  @impl true
  def stop_speaking(socket), do: tap(socket, fn _ -> record(:stop_speaking, nil) end)

  @impl true
  def voices do
    case :ets.lookup(@table, :voices) do
      [{:voices, result}] -> result
      [] -> {:error, :unsupported}
    end
  end

  @impl true
  def thumbnail(path, opts) do
    record(:thumbnail, {path, opts})

    case :ets.lookup(@table, :thumbnail) do
      [{:thumbnail, source}] ->
        out = Path.join(System.tmp_dir!(), "thumb_#{System.unique_integer([:positive])}.jpg")
        File.cp!(source, out)
        {:ok, %{path: out}}

      [] ->
        {:error, :unavailable}
    end
  end

  # Recorded, then saved for real through mob_photos with its host
  # stand-in (`config :mob_photos, nif: MobPhotos.Fake` in config/test.exs),
  # which answers {:photos, :saved | :save_failed, …} as the phone does.
  @impl true
  def save_photo(socket, path, opts) do
    record(:save_photo, {path, opts})
    MobPhotos.save(socket, path, opts)
  end

  @impl true
  def action_sheet(socket, opts), do: tap(socket, fn _ -> record(:action_sheet, opts) end)
end

defmodule Bezalel.Test.Whisper do
  @moduledoc """
  Whisper in tests (`config :bezalel, :whisper`): `transcribe/2` records
  the PCM it was given and answers `put_text/1`'s text (default
  "words"); the model counts as ready unless `put_ready/1` says not, and
  `prefetch/1` answers at once.
  """

  @table __MODULE__

  def start, do: :ets.new(@table, [:named_table, :public, :set])

  def reset, do: :ets.delete_all_objects(@table)

  def put_text(text), do: :ets.insert(@table, {:text, text})
  def put_ready(ready?), do: :ets.insert(@table, {:ready, ready?})

  @doc "The PCM of each transcription, oldest first."
  def heard, do: for({{:heard, _}, pcm} <- :ets.tab2list(@table) |> Enum.sort(), do: pcm)

  def transcribe(pcm, _opts) do
    :ets.insert(@table, {{:heard, System.unique_integer([:monotonic])}, pcm})

    case :ets.lookup(@table, :text) do
      [{:text, {:error, _} = error}] -> error
      [{:text, text}] -> {:ok, text}
      [] -> {:ok, "words"}
    end
  end

  def status do
    case :ets.lookup(@table, :ready) do
      [{:ready, false}] -> %{model_state: :not_loaded}
      _ -> %{model_state: :ready}
    end
  end

  def prefetch(opts) do
    if pid = opts[:notify], do: send(pid, {:mob_whisper, :model, :ready})
    :ok
  end
end
