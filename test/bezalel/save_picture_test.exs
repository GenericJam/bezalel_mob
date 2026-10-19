defmodule Bezalel.SavePictureTest do
  # Saving a picture to the phone's photos: the viewer's Save, a picture
  # material's Save to Photos, a long press in the chat. The permission and
  # the action sheet are recorded (Bezalel.Test.Native); the save itself
  # goes through mob_photos with its host stand-in (MobPhotos.Fake), which
  # copies the file into its own library and answers as the phone does.
  use Mob.ScreenCase
  @moduletag :screen

  import Kernel, except: [tap: 2]

  alias Bezalel.{AppScreen, Images, Materials, MaterialStore, Repo}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.MaterialStore.{Link, Row}
  alias Bezalel.Test.{Native, Png}

  setup do
    for schema <- [Tool, Conversation, Link, Row], do: Repo.delete_all(schema)
    Mob.State.delete(:bezalel_conversation)
    File.rm_rf!(MaterialStore.dir())
    Native.reset()

    library = Path.join(System.tmp_dir!(), "bezalel_photos_#{System.unique_integer([:positive])}")
    Application.put_env(:mob_photos, :fake_library_dir, library)
    MobPhotos.Fake.reset()

    on_exit(fn ->
      MobPhotos.Fake.reset()
      Application.delete_env(:mob_photos, :fake_library_dir)
    end)

    %{library: library}
  end

  defp tap(view, event), do: render_info(view, {:tap, event})
  # A drawing as draw_image keeps one: a :generated PNG material.
  defp drawing(name, file_name \\ nil, color \\ {28, 42, 68}) do
    png = Png.solid(1200, 800, color)
    material = Materials.derive(:generated, [], png, name: file_name || name <> ".png")
    {:ok, m} = MaterialStore.put(material, png, %{session_id: "s1"})
    {m, png}
  end

  # What the phone sends back after save_photo: the fake has already
  # answered into this (the screen's) mailbox.
  defp photos_answer(view) do
    assert_receive {:photos, _outcome, _info} = answer
    render_info(view, answer)
  end

  test "a drawing saves from its detail, at full size, into the Bezalel album", %{
    library: library
  } do
    {m, png} = drawing("Bezaleel at the lampstand")
    key = "material/" <> m.id

    view =
      AppScreen |> mount_screen() |> tap({:tab, :materials}) |> tap({:materials, {:open, m.id}})

    assert text(view) =~ "Save to Photos"

    view = tap(view, {:image, {:save, key}})
    assert {:request_permission, :media_save} in Native.calls()
    assert assigns(view).saving == key
    assert text(view) =~ "Saving…"

    view = view |> render_info({:permission, :media_save, :granted}) |> render_async()

    assert [{path, [album: "Bezalel", name: "Bezaleel at the lampstand.png"]}] =
             for({:save_photo, call} <- Native.calls(), do: call)

    assert path == MaterialStore.file(m.id, m.mime)

    view = photos_answer(view)
    assert assigns(view).toast.text == "Saved to your photos."
    assert assigns(view).saving == nil
    assert MobPhotos.Fake.saved() == ["Bezalel/Bezaleel at the lampstand.png"]
    assert File.read!(Path.join(library, "Bezalel/Bezaleel at the lampstand.png")) == png
  end

  test "a long press on a picture offers Save to Photos, which saves it" do
    {m, _png} = drawing("Lampstand")
    key = "material/" <> m.id
    view = AppScreen |> mount_screen()

    view = render_info(view, {:long_press, {:image, {:menu, key}}})
    assert [opts] = for({:action_sheet, opts} <- Native.calls(), do: opts)
    assert [label: "Save to Photos", action: :save_picture] in opts[:buttons]

    view =
      view
      |> render_info({:alert, :save_picture})
      |> render_info({:permission, :media_save, :granted})
      |> render_async()
      |> photos_answer()

    assert assigns(view).toast.text == "Saved to your photos."
    assert MobPhotos.Fake.saved() == ["Bezalel/Lampstand.png"]
  end

  test "Open from the long-press sheet opens the viewer; Cancel does nothing" do
    {m, _png} = drawing("Lampstand")
    key = "material/" <> m.id
    view = AppScreen |> mount_screen()

    view = render_info(view, {:long_press, {:image, {:menu, key}}})
    view = render_info(view, {:alert, :dismiss})
    assert assigns(view).viewer == nil
    assert assigns(view).picture_menu == nil

    view = render_info(view, {:long_press, {:image, {:menu, key}}})
    view = render_info(view, {:alert, :open_picture})
    assert %{key: ^key} = assigns(view).viewer
    assert find(view, :box, id: "viewer-save")
  end

  test "a save from the viewer shows its outcome over the viewer" do
    {m, _png} = drawing("Lampstand")
    key = "material/" <> m.id

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:long_press, {:image, {:menu, key}}})
      |> render_info({:alert, :open_picture})
      |> tap({:image, {:save, key}})
      |> render_info({:permission, :media_save, :granted})
      |> render_async()
      |> photos_answer()

    assert %{key: ^key} = assigns(view).viewer

    # The root Box draws its children in order: the toast comes after the
    # (opaque, full-screen) viewer, so it is drawn over it.
    children = tree(view).children
    viewer_at = Enum.find_index(children, &find(&1, :box, id: "viewer-save"))
    toast_at = Enum.find_index(children, &(text(&1) =~ "Saved to your photos."))
    assert viewer_at && toast_at && toast_at > viewer_at
  end

  test "a second save while one runs asks to wait, and the first still saves" do
    {a, _} = drawing("Lampstand")
    {b, _} = drawing("Laver", nil, {90, 60, 30})

    view =
      AppScreen
      |> mount_screen()
      |> tap({:image, {:save, "material/" <> a.id}})
      |> tap({:image, {:save, "material/" <> b.id}})

    assert assigns(view).toast.text =~ "Still saving the last picture"
    assert assigns(view).saving == "material/" <> a.id

    view =
      view
      |> render_info({:permission, :media_save, :granted})
      |> render_async()
      |> photos_answer()

    assert MobPhotos.Fake.saved() == ["Bezalel/Lampstand.png"]
  end

  test "a name already ending in the file's extension, in any case, keeps one" do
    {m, _png} = drawing("Lampstand", "Lampstand.PNG")

    AppScreen
    |> mount_screen()
    |> tap({:image, {:save, "material/" <> m.id}})
    |> render_info({:permission, :media_save, :granted})
    |> render_async()
    |> photos_answer()

    assert MobPhotos.Fake.saved() == ["Bezalel/Lampstand.png"]
  end

  test "any other failure at save time says why" do
    {m, _png} = drawing("Lampstand")
    MobPhotos.Fake.set_save_answer({:error, "the disk is full"})

    view =
      AppScreen
      |> mount_screen()
      |> tap({:image, {:save, "material/" <> m.id}})
      |> render_info({:permission, :media_save, :granted})
      |> render_async()
      |> photos_answer()

    assert assigns(view).toast.text == "Couldn’t save the picture (the disk is full)."

    assert assigns(view).saving == nil
  end

  test "a refused permission says how to allow it, and nothing is saved" do
    {m, _png} = drawing("Lampstand")
    view = AppScreen |> mount_screen() |> tap({:image, {:save, "material/" <> m.id}})

    view = render_info(view, {:permission, :media_save, :denied})
    assert assigns(view).toast.text =~ "isn’t allowed to add to your photos"
    assert assigns(view).toast.text =~ "Settings"
    assert assigns(view).saving == nil
    refute Enum.any?(Native.calls(), &match?({:save_photo, _}, &1))
    assert MobPhotos.Fake.saved() == []
  end

  test "the photo library refusing at save time says the same" do
    {m, _png} = drawing("Lampstand")
    MobPhotos.Fake.set_save_answer(:permission_denied)

    view =
      AppScreen
      |> mount_screen()
      |> tap({:image, {:save, "material/" <> m.id}})
      |> render_info({:permission, :media_save, :granted})
      |> render_async()
      |> photos_answer()

    assert assigns(view).toast.text =~ "isn’t allowed to add to your photos"
    assert MobPhotos.Fake.saved() == []
  end

  test "a picture whose file is gone says it can't be saved" do
    {m, _png} = drawing("Lampstand")
    File.rm!(MaterialStore.file(m.id, m.mime))

    view =
      AppScreen
      |> mount_screen()
      |> tap({:image, {:save, "material/" <> m.id}})
      |> render_info({:permission, :media_save, :granted})
      |> render_async()

    assert assigns(view).toast.text == "This picture can’t be saved."
    refute Enum.any?(Native.calls(), &match?({:save_photo, _}, &1))
  end

  describe "Images.original/2 (a session's picture at full size)" do
    test "decodes the picture from its session entry once, then reuses the file" do
      png = Png.solid(3000, 1500, {9, 9, 9})
      session_id = "sess#{System.unique_integer([:positive])}"
      session = Path.join(System.tmp_dir!(), session_id <> ".jsonl")

      File.write!(session, [
        Jason.encode!(%{"id" => "other", "message" => %{"content" => []}}),
        "\n",
        Jason.encode!(%{
          "id" => "e1",
          "message" => %{
            "content" => [
              %{"type" => "text", "text" => "Here"},
              %{"type" => "image", "data" => Base.encode64(png), "mimeType" => "image/png"}
            ]
          }
        }),
        "\n"
      ])

      image = %{key: "#{session_id}/e1/1", entry: "e1", index: 1, mime: "image/png"}
      assert {:ok, path} = Images.original(session, image)
      assert File.read!(path) == png
      assert Path.extname(path) == ".png"

      # Read from the file now, not the session.
      File.rm!(session)
      assert Images.original(session, image) == {:ok, path}
    end

    test "a missing entry is an error" do
      session = Path.join(System.tmp_dir!(), "empty#{System.unique_integer([:positive])}.jsonl")
      File.write!(session, "")
      image = %{key: "x/e9/0", entry: "e9", index: 0, mime: "image/png"}
      assert Images.original(session, image) == {:error, :not_found}
    end
  end
end
