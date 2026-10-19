defmodule Bezalel.Views.SavePicture do
  @moduledoc """
  Saving a picture to the phone's photos (mob_photos' `MobPhotos.save/3`):
  a drawing, a photo or still among the materials, a picture in a reply.
  Asked from the viewer's Save, a picture material's detail, or a long
  press on a picture in the chat (an action sheet with Save to Photos).

  The flow: ask for `:media_save` (iOS's add-only access, asked once;
  Android 10+ grants it without a dialog), then find the picture at full
  size off the screen process (`Bezalel.Images.original/2`: a session's
  picture is decoded from the session), then save it in the `Bezalel`
  album (Android's `Pictures/Bezalel`; iOS ignores albums when it may only
  add). A toast says how it went. `:saving` holds the picture's key while
  this runs (one save at a time: a second asks to wait, so no answer is
  matched to the wrong picture); `:picture_menu` the key a long press
  opened the sheet for.
  """

  alias Bezalel.{Images, Library, MaterialStore, Native}
  alias Bezalel.Views.Helpers
  alias Bezalel.Views.Images, as: ImagesView
  alias Mob.Socket

  @album "Bezalel"

  @doc "The assigns this view keeps."
  def assigns, do: [saving: nil, picture_menu: nil]

  @doc """
  Starts saving the picture `key` (a chat image's key): asks for the
  permission first. While another save runs, says so and does nothing.
  """
  def save(%{assigns: %{saving: key}} = socket, key), do: socket

  def save(%{assigns: %{saving: other}} = socket, _key) when is_binary(other),
    do: Helpers.toast(socket, "Still saving the last picture. Try again in a moment.")

  def save(socket, key) do
    socket
    |> Socket.assign(:saving, key)
    |> Native.request_permission(:media_save)
  end

  @doc "A long press on a picture in the chat: the sheet with Save to Photos."
  def menu(socket, key) do
    socket
    |> Socket.assign(:picture_menu, key)
    |> Native.action_sheet(
      title: "Picture",
      buttons: [
        [label: "Save to Photos", action: :save_picture],
        [label: "Open", action: :open_picture],
        [label: "Cancel", style: :cancel, action: :dismiss]
      ]
    )
  end

  @doc "The sheet's answer (`{:alert, action}`)."
  def alert(:save_picture, %{assigns: %{picture_menu: key}} = socket) when is_binary(key),
    do: socket |> Socket.assign(:picture_menu, nil) |> save(key)

  def alert(:open_picture, %{assigns: %{picture_menu: key}} = socket) when is_binary(key) do
    {:noreply, socket} =
      ImagesView.handle({:open, key}, Socket.assign(socket, :picture_menu, nil))

    socket
  end

  def alert(_action, socket), do: Socket.assign(socket, :picture_menu, nil)

  @doc "The answer to `:media_save`."
  def permission(:granted, %{assigns: %{saving: key}} = socket) when is_binary(key) do
    case ImagesView.find(socket, key) do
      nil ->
        failed(socket, "This picture is gone.")

      image ->
        Socket.start_async(socket, {:save_picture, key}, fn -> original(image) end)
    end
  end

  def permission(_denied, %{assigns: %{saving: key}} = socket) when is_binary(key),
    do: denied(socket)

  def permission(_result, socket), do: socket

  # Runs in the async task: the full-size file and the name it's saved as.
  defp original(%{material: id} = image) do
    with {:ok, path} <- Images.original(nil, image) do
      name =
        case MaterialStore.fetch(id, %{}) do
          {:ok, m} -> name(m.name, path)
          :error -> Path.basename(path)
        end

      {:ok, path, name}
    end
  end

  defp original(%{key: key, entry: entry} = image) do
    case key |> String.split("/") |> hd() |> Library.session_path_by_id() do
      nil ->
        {:error, :no_session}

      session_path ->
        with {:ok, path} <- Images.original(session_path, image) do
          {:ok, path, "Bezalel #{entry}" <> Path.extname(path)}
        end
    end
  end

  # The material's name as a file name, with the file's own extension (a
  # name already ending in it, in any case or as .jpeg for .jpg, keeps one).
  defp name(name, path) do
    ext = Path.extname(path)
    stem = name |> strip_ext(ext) |> String.replace(["/", "\\", <<0>>], "-") |> String.trim()

    case stem do
      s when s in ["", ".", ".."] -> Path.basename(path)
      s -> s <> ext
    end
  end

  defp strip_ext(name, ext) do
    if same_ext?(Path.extname(name), ext), do: Path.rootname(name), else: name
  end

  defp same_ext?(a, b), do: ext_key(a) == ext_key(b) and a != ""

  defp ext_key(ext) do
    case String.downcase(ext) do
      ".jpeg" -> ".jpg"
      e -> e
    end
  end

  @doc "The full-size file is ready (`handle_async({:save_picture, key}, ...)`): saves it."
  def found(key, {:ok, {:ok, path, name}}, %{assigns: %{saving: key}} = socket),
    do: Native.save_photo(socket, path, album: @album, name: name)

  def found(key, _failed, %{assigns: %{saving: key}} = socket),
    do: failed(socket, "This picture can’t be saved.")

  def found(_key, _result, socket), do: socket

  @doc "mob_photos' answer: `{:photos, :saved | :save_failed, info}`."
  def answered(:saved, _info, socket) do
    socket
    |> Socket.assign(:saving, nil)
    |> Helpers.toast("Saved to your photos.")
  end

  def answered(:save_failed, %{reason: :permission_denied}, socket), do: denied(socket)

  def answered(:save_failed, %{reason: reason}, socket),
    do: failed(socket, "Couldn’t save the picture (#{reason(reason)}).")

  defp reason(:not_found), do: "its file is gone"
  defp reason(:unsupported), do: "the photos app doesn’t take this kind of file"
  defp reason(message) when is_binary(message), do: message
  defp reason(other), do: inspect(other)

  defp denied(socket) do
    socket
    |> Socket.assign(:saving, nil)
    |> Helpers.toast(
      "Bezalel isn’t allowed to add to your photos. Allow it in the phone’s Settings, then try again."
    )
  end

  defp failed(socket, text), do: socket |> Socket.assign(:saving, nil) |> Helpers.toast(text)
end
