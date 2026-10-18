defmodule Bezalel.Transcribe do
  @moduledoc """
  What's said in a recording, a sound file or a video, on the phone: its
  audio as 16 kHz mono PCM, then Whisper (mob_whisper), kept as the
  material's `:transcript` derivative (`Bezalel.Materials.derive/4`) in
  `Bezalel.MaterialStore`. A model gets the transcript, never the sound
  (`Bezalel.Materials.route/3`); the recording stays in Materials.

  **The PCM** (`pcm/1`): a WAV of 16-bit samples (what `Mob.Audio` records
  on iOS with `format: :wav`) is read here, in Elixir: its header parsed
  and the samples averaged to mono and resampled to 16 kHz by
  `MobMedia.PCM.convert/5`'s rule, one second's block at a time (that
  function works on lists; a whole recording at once would hold millions
  of list cells on a phone). Anything else (m4a, the AAC Android records
  whatever the format asked for, mp3, ogg, a video's audio track) is
  decoded by the platform, `MobMedia.audio_pcm/2`.

  **Whisper** is `config :bezalel, :whisper` (`MobWhisper` by default;
  tests stand in for it). Its model (60 MB) downloads the first time it is
  needed; `model_ready?/0` says whether that has happened, so the screen
  can say why the first transcript takes a while.

  These calls block (decoding, then transcribing, take seconds): the
  screen runs them in `Mob.Socket.start_async/3`.
  """

  alias Bezalel.{Materials, MaterialStore}
  alias Bezalel.Materials.Material
  alias MobMedia.PCM

  @rate 16_000

  @doc """
  Transcribes `material` (audio or video) and keeps the transcript for
  `ctx`'s owner: `{:ok, transcript}`, or `{:error, reason}`. A video with
  no sound gets an empty transcript (there is nothing said to send).
  """
  @spec transcribe(Material.t(), map()) :: {:ok, Material.t()} | {:error, term()}
  def transcribe(%Material{kind: kind} = m, ctx) when kind in [:audio, :video] do
    with {:ok, text} <- text(m) do
      MaterialStore.put(Materials.derive(:transcript, m, text), text, ctx)
    end
  end

  def transcribe(%Material{}, _ctx), do: {:error, :not_audio}

  defp text(m) do
    case pcm(MaterialStore.path(m)) do
      {:ok, ""} ->
        {:ok, ""}

      {:ok, pcm} ->
        with {:ok, text} <- whisper().transcribe(pcm, []), do: {:ok, String.trim(text)}

      {:error, :no_audio} ->
        {:ok, ""}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  The audio of the file at `path` as 16 kHz mono signed 16-bit
  little-endian PCM (what Whisper takes). See the moduledoc.
  """
  @spec pcm(Path.t()) :: {:ok, binary()} | {:error, term()}
  def pcm(path) do
    with {:ok, head} <- head(path) do
      if wav?(head), do: wav_pcm(path), else: MobMedia.audio_pcm(path, rate: @rate, channels: 1)
    end
  end

  defp head(path) do
    with {:ok, file} <- File.open(path, [:read, :binary]) do
      try do
        case IO.binread(file, 12) do
          data when is_binary(data) -> {:ok, data}
          _eof -> {:ok, ""}
        end
      after
        File.close(file)
      end
    end
  end

  defp wav?(<<"RIFF", _size::little-32, "WAVE">>), do: true
  defp wav?(_head), do: false

  # A WAV this parser doesn't read (8- or 24-bit, float) goes to the
  # platform's decoder instead.
  defp wav_pcm(path) do
    with {:ok, bytes} <- File.read(path) do
      case PCM.parse_wav(bytes) do
        {:ok, %{rate: rate, channels: channels, pcm: pcm}} ->
          {:ok, to_whisper(pcm, rate, channels)}

        {:error, :unsupported} ->
          MobMedia.audio_pcm(path, rate: @rate, channels: 1)
      end
    end
  end

  @doc """
  `pcm` (16-bit little-endian, `rate` Hz, `channels` interleaved) as 16 kHz
  mono: exactly `MobMedia.PCM.convert(pcm, rate, channels, 16_000, 1)`,
  worked out a block of whole resampling periods at a time when
  downsampling (a box never spans two blocks, so the samples are the
  same), whole when upsampling (rare: a recording below 16 kHz).
  """
  @spec to_whisper(binary(), pos_integer(), pos_integer()) :: binary()
  def to_whisper(pcm, rate, channels) when rate < @rate,
    do: PCM.convert(pcm, rate, channels, @rate, 1)

  def to_whisper(pcm, rate, channels) do
    # `period` input frames make `div(@rate, gcd)` output frames exactly.
    period = div(rate, Integer.gcd(rate, @rate))
    block = period * max(div(rate, period), 1) * channels * 2

    pcm
    |> blocks(block, [])
    |> Enum.map(&PCM.convert(&1, rate, channels, @rate, 1))
    |> IO.iodata_to_binary()
  end

  defp blocks(<<>>, _size, acc), do: Enum.reverse(acc)

  defp blocks(pcm, size, acc) when byte_size(pcm) <= size, do: Enum.reverse([pcm | acc])

  defp blocks(pcm, size, acc) do
    <<block::binary-size(^size), rest::binary>> = pcm
    blocks(rest, size, [block | acc])
  end

  @doc "Whether Whisper's model is on the phone and loaded (no download before the next transcript)."
  @spec model_ready?() :: boolean()
  def model_ready? do
    whisper().status()[:model_state] == :ready
  catch
    :exit, _ -> false
  end

  @doc """
  Starts fetching and loading Whisper's model in the background;
  `{:mob_whisper, :model, :ready | {:error, reason}}` goes to `notify`.
  """
  @spec prefetch(pid()) :: :ok
  def prefetch(notify), do: whisper().prefetch(notify: notify)

  defp whisper, do: Application.get_env(:bezalel, :whisper, MobWhisper)
end
