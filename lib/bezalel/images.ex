defmodule Bezalel.Images do
  @moduledoc """
  Pictures in the chat, sized for the screen on the phone.

  A picture lives where it arrived, in the conversation's session (rho
  writes pi's image parts, base64, into a tool's result, a model's turn
  or a user message with an attachment), whichever provider or tool it
  came from; `Bezalel.Library.Message` lists them by entry and part. Before
  the chat shows one it's decoded and downscaled here, in Elixir
  (`Bezalel.Images.Codec`: PNG, baseline JPEG; the platform views would
  otherwise hold the full-size bitmap), to the box it's drawn in (the
  chat's width, or the full-screen viewer's), and the result is cached as
  a file under `<data dir>/images/<session id>/`, which the native image
  view reads. A picture the codec can't shrink (it already fits, or a
  format it doesn't decode) is cached as it is. The original's size goes
  with the file (in its name, `<entry>-<part>-<box>.<width>x<height>.<ext>`):
  the chat and the viewer size a picture by it, not by the file's pixels,
  so one decoded smaller than its box is still drawn at its size.
  """

  alias Bezalel.Images.Codec

  # The chat's side margins (dp) and its tallest picture (dp).
  @margins 32
  @chat_height 420
  # The viewer's picture: up to this many times the screen, for zooming.
  @viewer_zoom 2
  @viewer_max_px 2560

  @type size :: :chat | :viewer
  @typedoc "A made picture: its file, the file's pixels, and the original's."
  @type ready :: %{
          path: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          original: {pos_integer(), pos_integer()}
        }

  @doc """
  The screen in dp and its pixel ratio (`:mob_nif.screen_info/0` on the
  phone; an iPhone's on the host).
  """
  @spec screen() :: %{width: number(), height: number(), scale: number()}
  def screen do
    case :mob_nif.screen_info() do
      %{width: w, height: h, scale: s} when w > 0 and s > 0 -> %{width: w, height: h, scale: s}
      _ -> host_screen()
    end
  rescue
    _ -> host_screen()
  catch
    _, _ -> host_screen()
  end

  defp host_screen, do: %{width: 393, height: 852, scale: 3.0}

  @doc "The pixel box a picture of `size` is made to fit."
  @spec box(size(), map()) :: {pos_integer(), pos_integer()}
  def box(size, screen \\ screen())

  def box(:chat, %{width: w, scale: s}),
    do: {round((w - @margins) * s), round(@chat_height * s)}

  def box(:viewer, %{width: w, height: h, scale: s}) do
    {min(round(w * s * @viewer_zoom), @viewer_max_px),
     min(round(h * s * @viewer_zoom), @viewer_max_px)}
  end

  @doc """
  The picture's file at `size`: made the first time, then from the cache.
  A session's picture (`Message.image()`) is read from the session at
  `session_path`; a material's (`%{key: "material/<id>", material: id,
  mime: mime}`) from `Bezalel.MaterialStore`, its copies kept under the
  store's cache directory (`chat/`), not by session. `{:error, reason}`
  when the entry, the material or its picture is gone or can't be read.
  """
  @spec prepare(String.t() | nil, map(), size()) :: {:ok, ready()} | {:error, term()}
  def prepare(session_path, image, size) do
    {w, h} = box(size)
    base = cache_base(image, w, h)

    case cached(base) do
      {:ok, _} = hit -> hit
      :miss -> make(read(session_path, image), image.mime, w, h, base)
    end
  end

  defp read(_session_path, %{material: id, mime: mime}),
    do: File.read(Bezalel.MaterialStore.file(id, mime))

  defp read(session_path, image), do: read_part(session_path, image.entry, image.index)

  defp make(read, mime, w, h, base) do
    with {:ok, bytes} <- read,
         {:ok, %{width: ow, height: oh}} <- Codec.info(bytes) do
      base = "#{base}.#{ow}x#{oh}"

      case Codec.thumbnail(bytes, w, h) do
        {:ok, %{data: data, width: tw, height: th}} ->
          write(base <> ".png", data, tw, th, {ow, oh})

        {:original, %{width: ow, height: oh}} ->
          write(base <> extension(mime, bytes), bytes, ow, oh, {ow, oh})

        {:error, _} = error ->
          error
      end
    else
      :error -> {:error, :unrecognized}
      {:error, _} = error -> error
    end
  end

  defp write(path, data, width, height, original) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, data)
    File.rename!(tmp, path)
    {:ok, %{path: path, width: width, height: height, original: original}}
  end

  # A file made earlier at this box (any extension), with its size and the
  # original's (from its name; a file named without it, or a `.tmp` one
  # being written, doesn't count).
  defp cached(base) do
    (base <> ".*")
    |> Path.wildcard()
    |> Enum.find_value(:miss, &cached_file/1)
  end

  defp cached_file(path) do
    with [_base, dims, _ext] <- path |> Path.basename() |> String.split("."),
         {:ok, original} <- dims(dims),
         {:ok, bytes} <- File.read(path),
         {:ok, %{width: w, height: h}} <- Codec.info(bytes) do
      {:ok, %{path: path, width: w, height: h, original: original}}
    else
      _ -> nil
    end
  end

  defp dims(text) do
    with [w, h] <- String.split(text, "x"),
         {w, ""} when w > 0 <- Integer.parse(w),
         {h, ""} when h > 0 <- Integer.parse(h) do
      {:ok, {w, h}}
    else
      _ -> :error
    end
  end

  defp cache_base(%{material: id}, w, h),
    do: Path.join([Bezalel.MaterialStore.cache_dir(), "chat", "#{id}-#{w}x#{h}"])

  defp cache_base(%{key: key}, w, h) do
    [session_id, entry, index] = String.split(key, "/")
    Path.join([dir(), session_id, "#{entry}-#{index}-#{w}x#{h}"])
  end

  @doc "Where the cache is."
  @spec dir() :: String.t()
  def dir, do: Path.join(Rho.Config.data_dir(), "images")

  defp extension(mime, bytes) do
    case {mime, Codec.info(bytes)} do
      {_, {:ok, %{format: format}}} when format != :unknown -> ".#{format}"
      {"image/" <> sub, _} -> "." <> sub
      _ -> ".img"
    end
  end

  # The `index`th content part of entry `entry` in the session file: the
  # file is read line by line, and only that entry is decoded.
  defp read_part(path, entry, index) do
    needle = ~s("id":"#{entry}")
    found = path |> File.stream!(:line) |> Enum.find_value(&entry_on(&1, needle, entry))

    with %{"message" => %{"content" => content}} when is_list(content) <- found,
         %{"type" => "image", "data" => data} <- Enum.at(content, index),
         {:ok, bytes} <- Base.decode64(data) do
      {:ok, bytes}
    else
      _ -> {:error, :not_found}
    end
  rescue
    e in File.Error -> {:error, e.reason}
  end

  # The line's entry, if it's `entry` (a cheap look before decoding).
  defp entry_on(line, needle, entry) do
    with true <- String.contains?(line, needle),
         {:ok, %{"id" => ^entry} = decoded} <- Jason.decode(line) do
      decoded
    else
      _ -> nil
    end
  end
end
