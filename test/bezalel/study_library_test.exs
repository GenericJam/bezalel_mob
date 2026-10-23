defmodule Bezalel.StudyLibraryTest do
  use Mob.ScreenCase
  # The app's own Bezalel.Packs (test_helper.exs), pointed at a local
  # library for each test.
  @moduletag :screen

  alias Bezalel.{AppScreen, AttributionsScreen, Packs, Repo}
  alias Bezalel.Library.Conversation
  alias Bezalel.Packs.Manifest
  alias Bezalel.Test.{Browser, MemoryStore, PackServer}
  alias Bezalel.Views.StudyLibrary

  setup do
    {server, base} = PackServer.start()
    core = PackServer.pack("core", "v1")
    notes = PackServer.pack("notes", "v1")
    url = PackServer.publish(server, base, 1, [{"core", core, true}, {"notes", notes, false}])
    Application.put_env(:bezalel, :packs_manifest_url, url)
    dir = :sys.get_state(Packs).dir
    # No API key left by another module: Settings' key rows have their own
    # "Remove" buttons.
    MemoryStore.clear()
    Mob.State.delete(:bezalel_study_preferences)
    # Nor its conversations: the screen opens the latest (one with a block
    # Study can't draw, such as TitlesTest's, failed the first-launch test).
    Repo.delete_all(Conversation)
    Mob.State.delete(:bezalel_conversation)

    # This test's library replaces the last one's.
    :ok = Packs.subscribe()
    :ok = Packs.check()
    assert_receive {:bezalel_packs, {:notice, "Up to date: study library version 1."}}, 5_000
    flush()

    on_exit(fn ->
      Application.put_env(:bezalel, :packs_manifest_url, "http://127.0.0.1:9/packs/manifest.json")
      Application.delete_env(:bezalel, :test_network)
      Bezalel.Settings.put_packs_offered()
      Mob.State.delete(:bezalel_study_preferences)
      for name <- ["core", "notes", "translations"], do: Packs.cancel(name)
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
    end)

    %{core: core, notes: notes, server: server, base: base}
  end

  defp flush do
    receive do
      {:bezalel_packs, _} -> flush()
    after
      0 -> :ok
    end
  end

  # The screen gets Bezalel.Packs' messages through the test process.
  defp follow(view, until) do
    assert_receive {:bezalel_packs, event}, 5_000
    view = render_info(view, {:bezalel_packs, event})
    if until.(event, view), do: view, else: follow(view, until)
  end

  defp notice(text), do: fn event, _view -> event == {:notice, text} end

  defp settings, do: AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})

  # The pack's own button (a pill Box tapping {:packs, event}).
  defp pack_button?(view, event) do
    view |> find_all(:box) |> Enum.any?(&match?(%{props: %{on_tap: {_, {:packs, ^event}}}}, &1))
  end

  test "first launch offers the core pack with its sizes, once; Download fetches it in the background",
       ctx do
    Mob.State.delete(:bezalel_packs_offered)
    Application.put_env(:bezalel, :test_network, %{transport: :cellular, expensive: true})
    view = mount_screen(AppScreen)

    assert assigns(view).sheet == :packs_offer
    text = text(view)
    assert text =~ "Download the study library"
    assert text =~ "#{StudyLibrary.size(byte_size(ctx.core.zst))} to download"
    assert text =~ "You're on mobile data"
    assert_renderable(view)

    view = render_info(view, {:tap, {:packs, {:download, "core"}}})
    assert assigns(view).sheet == nil
    view = follow(view, notice("The core pack is ready."))
    assert assigns(view).toast.text == "The core pack is ready."

    # Offered once: the next start doesn't ask again.
    refute mount_screen(AppScreen) |> assigns() |> Map.get(:sheet)
  end

  test "Settings lists the packs; download, check for updates, remove the optional one" do
    view = settings()

    text = text(view)
    assert text =~ "Core · needed"
    assert text =~ "Notes"
    assert text =~ "on the phone"
    assert text =~ "Storage used"
    assert find(view, :text, text: "Check for updates")
    refute text =~ "mobile data"
    assert_renderable(view)

    view = render_info(view, {:tap, {:packs, {:download, "notes"}}})
    view = follow(view, notice("The notes pack is ready."))
    assert text(view) =~ "On the phone · "
    assert pack_button?(view, {:remove, "notes"})

    view = render_info(view, {:tap, {:packs, :check}})
    view = follow(view, notice("Up to date: study library version 1."))
    assert text(view) =~ "Up to date: study library version 1."

    view = render_info(view, {:tap, {:packs, {:remove, "notes"}}})
    assert assigns(view).toast.text == "Removed the Notes pack."
    refute pack_button?(view, {:remove, "notes"})
    assert pack_button?(view, {:download, "notes"})
  end

  test "a failed download says why and offers it again", ctx do
    view = settings()
    PackServer.put_file(ctx.server, "/packs/v1/core.sqlite.zst", nil)

    view = render_info(view, {:tap, {:packs, {:download, "core"}}})
    view = follow(view, fn event, _ -> match?({:notice, _}, event) end)

    text = "Couldn't download the core pack: the library answered 404."
    assert assigns(view).toast.text == text
    assert text(view) =~ text
    assert find(view, :text, text: "Download")
  end

  test "the sources screen opens from Settings, shows each attribution and opens its links" do
    view = render_info(settings(), {:tap, {:packs, :attributions}})
    assert navigated_to(view) == AttributionsScreen

    view = mount_screen(AttributionsScreen)
    text = text(view)
    assert text =~ "Modified for Bezalel: the sources below were converted into SQLite databases"

    assert text =~
             "from STEP Bible (www.STEPBible.org), created by Tyndale House, Cambridge. CC BY 4.0. Modified."

    assert text =~ "This text of God's Word has been dedicated to the public domain."
    assert text =~ "transcription by Martin G. Abegg Jr., James E. Bowley and Edward M. Cook"
    assert text =~ "Leon Levy Dead Sea Scrolls Digital Library"
    assert text =~ "Summaries of John Owen's works"
    assert text =~ "Permission is hereby granted, free of charge"

    # The NET, quoted by permission: its acknowledgement verbatim, the
    # licence note and its link.
    assert text =~
             "Scripture quoted by permission. Quotations designated (NET) are from the NET Bible® copyright ©1996, 2019 by Biblical Studies Press, L.L.C. http://netbible.com All rights reserved."

    assert text =~ "Free non-commercial use by permission (netbible.com/copyright)."
    assert text =~ "The NET's translators' notes are not included."

    assert %{props: %{on_tap: {_, {:open, "http://netbible.org"}}}} =
             find(view, :text, text: "http://netbible.org")

    assert_renderable(view)

    render_info(
      view,
      {:tap, {:open, "https://github.com/GenericJam/bezalel_mob/blob/master/data/SOURCES.md"}}
    )

    assert Browser.last() ==
             "https://github.com/GenericJam/bezalel_mob/blob/master/data/SOURCES.md"

    assert %{props: %{on_tap: {_, {:open, "https://creativecommons.org/licenses/by-nc/4.0/"}}}} =
             find(view, :text, text: "CC BY-NC 4.0")
  end

  test "with a translation from the translations pack chosen and the pack not on the phone, the study library says the tools quote the BSB" do
    view = settings()

    assert text(view) =~
             "Your translation, the NET Bible, is in the Bible translations pack. Until it's on this phone, the study tools quote the BSB from the core pack and say so."

    assert StudyLibrary.title("translations") == "Bible translations"

    view = render_info(view, {:tap, {:settings, {:translation, "jps1917"}}})
    assert text(view) =~ "Your translation, the JPS 1917, is in the Bible translations pack."

    view = render_info(view, {:tap, {:settings, {:translation, "bsb"}}})
    refute text(view) =~ "is in the Bible translations pack"
  end

  test "a library with the translations pack lists it as Bible translations, optional: download, then remove",
       ctx do
    translations = PackServer.translations_pack("v3", ~w(net jps1917 ult ust))

    PackServer.publish(ctx.server, ctx.base, 2, [
      {"core", ctx.core, true},
      {"translations", translations, false},
      {"notes", ctx.notes, false}
    ])

    :ok = Packs.check()
    assert_receive {:bezalel_packs, {:notice, "Up to date: study library version 2."}}, 5_000
    flush()

    view = render_info(settings(), {:tap, {:settings, {:translation, "ult"}}})
    assert Enum.map(assigns(view).packs.packs, & &1.name) == ["core", "translations", "notes"]
    assert %{required: false} = Enum.find(assigns(view).packs.packs, &(&1.name == "translations"))
    text = text(view)
    assert text =~ "Bible translations"
    refute text =~ "Bible translations · needed"

    missing =
      "Your translation, the Literal Text (ULT, adapted), is in the Bible translations pack."

    assert text =~ missing
    assert pack_button?(view, {:download, "translations"})

    view = render_info(view, {:tap, {:packs, {:download, "translations"}}})
    view = view |> follow(notice("The translations pack is ready.")) |> render_async()
    assert pack_button?(view, {:remove, "translations"})
    refute text(view) =~ missing
    assert text(view) =~ "From the Bible translations pack on this phone."

    view = render_info(view, {:tap, {:packs, {:remove, "translations"}}})
    assert assigns(view).toast.text == "Removed the Bible translations pack."
    assert pack_button?(view, {:download, "translations"})
    assert text(view) =~ missing
  end

  test "a translations pack from before data version 3 (the NET only), not yet checked: the JPS, ULT and UST say it needs updating",
       ctx do
    PackServer.publish(ctx.server, ctx.base, 3, [
      {"core", ctx.core, true},
      {"translations", PackServer.translations_pack("v3", ~w(net jps1917 ult ust)), false}
    ])

    :ok = Packs.check()
    assert_receive {:bezalel_packs, {:notice, "Up to date: study library version 3."}}, 5_000
    flush()

    # The old pack lands after the check (pushed, or kept from an older
    # build): installed, with no update flagged.
    old = PackServer.translations_pack("v2", ~w(net))
    File.write!(Path.join(:sys.get_state(Packs).dir, "translations.sqlite"), old.raw)

    view = settings()

    assert %{installed: %{}, update: false} =
             Enum.find(assigns(view).packs.packs, &(&1.name == "translations"))

    # The pack is read off the screen: until it's read, nothing is said
    # about it, neither missing nor on the phone.
    assert assigns(view).pack_translations == :loading
    loading = text(view)
    assert loading =~ "Biblical Studies Press, 2019; quoted by permission. The whole Bible."
    refute loading =~ "Needs the Bible translations pack"
    refute loading =~ "Your translation, the NET Bible, is in the Bible translations pack"
    refute loading =~ "From the Bible translations pack on this phone."

    view = render_async(view)
    assert assigns(view).pack_translations == ["net"]
    assert text(view) =~ "From the Bible translations pack on this phone."

    view = render_info(view, {:tap, {:settings, {:translation, "ult"}}})

    assert text(view) =~
             "The Bible translations pack on this phone is older and doesn't have it: update the pack (Study library)."

    assert text(view) =~
             "Your translation, the Literal Text (ULT, adapted), isn't in the Bible translations pack on this phone: update it."

    # A read of the file as it was before a change is dropped; the current
    # stamp's is kept.
    stamp = assigns(view).pack_translations_stamp
    socket = view.socket
    stale = put_elem(stamp, 1, elem(stamp, 1) + 1)
    kept = StudyLibrary.translations_read({:ok, {stale, ~w(net ult)}}, socket)
    assert kept.assigns.pack_translations == ["net"]
    taken = StudyLibrary.translations_read({:ok, {stamp, ~w(net ult)}}, socket)
    assert taken.assigns.pack_translations == ~w(net ult)

    # Replaced by a v3 pack, it's read again.
    new = PackServer.translations_pack("v3", ~w(net jps1917 ult ust))
    # As a download lands it: a new file renamed over the old one.
    dir = :sys.get_state(Packs).dir
    File.write!(Path.join(dir, ".translations.part"), new.raw)
    File.rename!(Path.join(dir, ".translations.part"), Path.join(dir, "translations.sqlite"))
    view = view |> render_info({:bezalel_packs, :changed}) |> render_async()
    assert assigns(view).pack_translations == ~w(net jps1917 ult ust)
    assert text(view) =~ "From the Bible translations pack on this phone."
    refute text(view) =~ "is older and doesn't have it"
  end

  test "a translations pack that can't be read says so: remove it and download it again",
       ctx do
    PackServer.publish(ctx.server, ctx.base, 3, [
      {"core", ctx.core, true},
      {"translations", PackServer.translations_pack("v3", ~w(net jps1917 ult ust)), false}
    ])

    :ok = Packs.check()
    assert_receive {:bezalel_packs, {:notice, "Up to date: study library version 3."}}, 5_000
    flush()

    File.write!(
      Path.join(:sys.get_state(Packs).dir, "translations.sqlite"),
      "not a database" <> :binary.copy(<<0>>, 4096)
    )

    view = render_async(settings())
    assert assigns(view).pack_translations == :unreadable

    assert text(view) =~
             "The Bible translations pack on this phone can't be read: remove it and download it again (Study library)."

    assert text(view) =~
             "Your translation, the NET Bible, is in the Bible translations pack, but the one on this phone can't be read: remove it and download it again."

    refute text(view) =~ "update the pack"
  end

  test "a library with the scrolls pack lists it as the Dead Sea Scrolls, optional, after the ancient sources; a pack this app doesn't know is left out",
       ctx do
    PackServer.publish(ctx.server, ctx.base, 2, [
      {"scrolls", PackServer.pack("scrolls", "v2"), false},
      {"future", PackServer.pack("future", "v2"), false},
      {"ancient", PackServer.pack("ancient", "v2"), false},
      {"core", ctx.core, true}
    ])

    :ok = Packs.check()
    assert_receive {:bezalel_packs, {:notice, "Up to date: study library version 2."}}, 5_000
    flush()

    view = settings()
    assert Enum.map(assigns(view).packs.packs, & &1.name) == ["core", "ancient", "scrolls"]
    assert %{required: false} = Enum.find(assigns(view).packs.packs, &(&1.name == "scrolls"))
    assert text(view) =~ "Dead Sea Scrolls"
    assert pack_button?(view, {:download, "scrolls"})
  end

  test "data version 3's packs are listed, optional, in Settings' order", ctx do
    assert Manifest.known() ==
             ~w(core translations notes lxx witnesses ancient scrolls fathers dictionaries syntax graph)

    optional =
      for name <- ~w(syntax fathers graph witnesses dictionaries),
          do: {name, PackServer.pack(name, "v3"), false}

    PackServer.publish(ctx.server, ctx.base, 3, [{"core", ctx.core, true} | optional])
    :ok = Packs.check()
    assert_receive {:bezalel_packs, {:notice, "Up to date: study library version 3."}}, 5_000
    flush()

    view = settings()

    assert Enum.map(assigns(view).packs.packs, & &1.name) ==
             ~w(core witnesses fathers dictionaries syntax graph)

    text = text(view)

    for {name, title} <- [
          {"witnesses", "Textual witnesses (Samaritan Pentateuch, SBLGNT, HOTTP)"},
          {"fathers", "Apostolic Fathers"},
          {"dictionaries", "UBS Hebrew and Greek dictionaries"},
          {"syntax", "Clause structure (MACULA)"}
        ] do
      assert StudyLibrary.title(name) == title
      assert text =~ title
      assert %{required: false} = Enum.find(assigns(view).packs.packs, &(&1.name == name))
      assert pack_button?(view, {:download, name})
    end

    assert_renderable(view)
  end
end
