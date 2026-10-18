defmodule Bezalel.MaterialStoreTest do
  # Changes the store's tables and the shared fakes (Bezalel.Test.Native,
  # Bezalel.Test.Whisper, MobMedia's fake engine).
  use ExUnit.Case, async: false

  alias Bezalel.Images.Codec
  alias Bezalel.{Materials, MaterialStore, Repo, Transcribe}
  alias Bezalel.MaterialStore.{Link, Row}
  alias Bezalel.Test.{Native, Png, Whisper}
  alias MobMedia.Engine.Fake, as: MediaFake
  alias MobMedia.PCM

  setup do
    Repo.delete_all(Link)
    Repo.delete_all(Row)
    File.rm_rf!(MaterialStore.dir())
    File.rm_rf!(MaterialStore.cache_dir())
    Native.reset()
    Whisper.reset()
    MediaFake.reset()
    :ok
  end

  defp keep(bytes, attrs, session_id \\ "s1") do
    {:ok, m} = MaterialStore.put(Materials.new(bytes, attrs), bytes, %{session_id: session_id})
    m
  end

  test "a material is kept as a file named by its bytes, and read back as it was" do
    m = keep("%PDF-1.4 notes", name: "notes.pdf")

    assert File.read!(MaterialStore.path(m)) == "%PDF-1.4 notes"
    assert MaterialStore.path(m) =~ ~r"materials/[0-9a-f]{2}/[0-9a-f]{64}\.pdf$"
    assert {:ok, ^m} = MaterialStore.fetch(m.id, %{session_id: nil})
    assert {:ok, "%PDF-1.4 notes"} = MaterialStore.read(m, %{session_id: "other"})
    assert Materials.store() == {:ok, MaterialStore}
  end

  test "the same bytes put again are one material: the first record, every parent, every conversation" do
    a = keep("audio a", name: "a.m4a")
    b = keep("audio b", name: "b.m4a")
    # Two silent recordings have the same empty transcript.
    t1 = Materials.derive(:transcript, a, "")
    t2 = Materials.derive(:transcript, b, "")

    {:ok, _} = MaterialStore.put(t1, "", %{session_id: "s1"})
    {:ok, kept} = MaterialStore.put(t2, "", %{session_id: "s2"})

    assert kept.id == t1.id
    assert kept.name == t1.name
    assert Enum.sort(kept.derived_from) == Enum.sort([a.id, b.id])
    assert Repo.aggregate(Row, :count) == 3
    assert MaterialStore.sessions(kept.id) == ["s1", "s2"]
    assert [%{id: id}] = MaterialStore.derivatives(b.id, %{session_id: nil})
    assert id == kept.id
    # Linked once per conversation, however often it's put.
    {:ok, _} = MaterialStore.put(t2, "", %{session_id: "s2"})
    assert MaterialStore.sessions(kept.id) == ["s1", "s2"]
  end

  test "the tab lists originals and drawings, newest first, by kind and conversation" do
    photo =
      keep(Png.solid(4, 4, {1, 2, 3}), name: "photo.png", inserted_at: ~U[2026-10-18 10:00:00Z])

    audio =
      keep("sound", [name: "talk.m4a", inserted_at: ~U[2026-10-18 11:00:00Z]], "s2")

    {:ok, _} =
      MaterialStore.put(Materials.derive(:transcript, audio, "hi"), "hi", %{session_id: "s2"})

    drawing = Materials.derive(:generated, photo, Png.solid(2, 2, {9, 9, 9}))
    {:ok, drawing} = MaterialStore.put(drawing, Png.solid(2, 2, {9, 9, 9}), %{session_id: "s1"})

    assert Enum.map(MaterialStore.list(), & &1.id) |> Enum.sort() ==
             Enum.sort([photo.id, audio.id, drawing.id])

    assert [%{id: a}] = MaterialStore.list(kind: :audio)
    assert a == audio.id
    assert MaterialStore.list(session_id: "s2") |> Enum.map(& &1.id) == [audio.id]
  end

  test "deleting a material deletes what was made from it alone, not a drawing from it" do
    photo = keep(Png.solid(4, 4, {1, 2, 3}), name: "photo.png")
    audio = keep("sound", name: "talk.m4a")
    {:ok, t} = MaterialStore.put(Materials.derive(:transcript, audio, "hi"), "hi", %{})
    bytes = Png.solid(2, 2, {9, 9, 9})
    {:ok, drawing} = MaterialStore.put(Materials.derive(:generated, photo, bytes), bytes, %{})

    :ok = MaterialStore.delete(audio.id)
    :ok = MaterialStore.delete(photo.id)

    assert MaterialStore.fetch(audio.id, %{}) == :error
    assert MaterialStore.fetch(t.id, %{}) == :error
    refute File.exists?(MaterialStore.path(t))
    refute File.exists?(MaterialStore.path(photo))
    assert {:ok, _} = MaterialStore.fetch(drawing.id, %{})
    # Its reference is gone: a stored reference to it can't be read.
    assert {:error, :not_found} = Materials.resolve(%{"ref" => photo.id}, %{session_id: "s1"})
  end

  describe "pictures for a model" do
    test "one providers take as it is goes as it is" do
      bytes = Png.solid(800, 600, {10, 20, 30})
      m = keep(bytes, name: "small.png")

      assert {:ok, {"image/png", ^bytes}} =
               Materials.resolve(%{"ref" => m.id}, %{session_id: "s1"})

      assert Native.names() == []
    end

    test "a large photo goes as the platform's downscaled JPEG, made once" do
      bytes = Png.solid(3000, 2000, {10, 20, 30})
      m = keep(bytes, name: "big.png")
      thumb = Path.join(System.tmp_dir!(), "fake_thumb.jpg")
      File.write!(thumb, <<0xFF, 0xD8, 0xFF, "small jpeg">>)
      Native.put_thumbnail(thumb)

      assert {:ok, {"image/jpeg", <<0xFF, 0xD8, 0xFF, "small jpeg">>}} =
               MaterialStore.for_model(m, %{session_id: "s1"})

      assert [{:thumbnail, {path, opts}}] = Native.calls()
      assert path == MaterialStore.path(m)
      assert opts[:max_size] == 1568

      # The next request of the conversation reads the copy.
      assert {:ok, {"image/jpeg", _}} = MaterialStore.for_model(m, %{session_id: "s1"})
      assert [_] = Native.calls()
    end

    test "without the platform's thumbnail, a large one is shrunk here" do
      m = keep(Png.solid(3000, 2000, {10, 20, 30}), name: "big.png")
      assert {:ok, {"image/png", png}} = MaterialStore.for_model(m, %{session_id: "s1"})
      assert {:ok, %{width: 1568, height: 1045}} = Codec.info(png)
    end
  end

  describe "transcripts" do
    test "a WAV is made 16 kHz mono here, block by block, exactly as MobMedia.PCM converts it whole" do
      # 2.5 s of 44.1 kHz stereo: more than one block, a partial last one.
      frames = div(44_100 * 5, 2)

      pcm =
        for i <- 0..(frames * 2 - 1),
            into: <<>>,
            do: <<rem(i * 37, 20_000) - 10_000::little-signed-16>>

      assert Transcribe.to_whisper(pcm, 44_100, 2) == PCM.convert(pcm, 44_100, 2, 16_000, 1)
      # 48 kHz mono too (a 3:1 period).
      mono = binary_part(pcm, 0, 48_000 * 2 + 600)
      assert Transcribe.to_whisper(mono, 48_000, 1) == PCM.convert(mono, 48_000, 1, 16_000, 1)
    end

    test "a recording is transcribed and the transcript kept as its derivative" do
      pcm = for i <- 0..44_099, into: <<>>, do: <<rem(i, 200) * 100 - 10_000::little-signed-16>>
      wav = PCM.wav(pcm, 44_100, 1)
      audio = keep(wav, name: "Recording.wav")
      Whisper.put_text("  In the beginning  ")

      assert {:ok, t} = Transcribe.transcribe(audio, %{session_id: "s1"})

      assert t.kind == :transcript and t.derived_from == [audio.id]
      assert {:ok, "In the beginning"} = MaterialStore.read(t, %{})
      assert Whisper.heard() == [Transcribe.to_whisper(pcm, 44_100, 1)]
    end

    test "a compressed file goes through mob_media's decoder" do
      audio = keep("not really aac", name: "voice.m4a")
      pcm = <<1::little-16, 2::little-16, 3::little-16>>
      MediaFake.script(MaterialStore.path(audio), audio: {pcm, 16_000, 1})

      assert {:ok, _t} = Transcribe.transcribe(audio, %{session_id: "s1"})
      assert Whisper.heard() == [pcm]
    end

    test "audio with no transcript is missing for the model until it's transcribed" do
      audio = keep(PCM.wav(<<0::little-16, 5::little-16>>, 16_000, 1), name: "Recording.wav")
      ctx = %{session_id: "s1"}
      inputs = Rho.Models.inputs("anthropic:claude-sonnet-4-5")

      assert {:missing, [missing]} = Materials.attachments([audio.id], inputs, ctx)
      assert missing.id == audio.id

      Whisper.put_text("hello")
      {:ok, _} = Transcribe.transcribe(audio, ctx)

      assert {:ok, [%{kind: :text, ref: ref, text: "hello"}]} =
               Materials.attachments([audio.id], inputs, ctx)

      assert ref == audio.id
    end
  end
end
