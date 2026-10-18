defmodule Bezalel.StillsTest do
  # The stills picker (Bezalel.Views.Stills) driven through Mob.ScreenCase,
  # with MobMedia.Engine.Fake answering for the video: its length, and the
  # frame (scripted again before each move, so a still is known by its bytes).
  use Mob.ScreenCase
  @moduletag :screen

  import Kernel, except: [tap: 2]

  alias Bezalel.Agent.Live
  alias Bezalel.{AppScreen, Materials, MaterialStore, Repo}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.MaterialStore.{Link, Row}
  alias Bezalel.Test.{FakeLLM, MemoryStore, Native, Png, Whisper}
  alias MobMedia.Engine.Fake
  alias ReqLLM.Message.ContentPart

  @fixtures Path.expand("../fixtures/images", __DIR__)
  @video "not really an mp4, scripted"

  setup do
    for schema <- [Tool, Conversation, Link, Row], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model, :bezalel_read_aloud],
        do: Mob.State.delete(key)

    File.rm_rf!(MaterialStore.dir())
    File.rm_rf!(Path.join(MaterialStore.cache_dir(), "stills"))
    MemoryStore.clear()
    Native.reset()
    Whisper.reset()
    Fake.reset()

    on_exit(fn ->
      Fake.reset()
      Application.delete_env(:bezalel, Live)
      Application.delete_env(:bezalel_core, :draw_image)
      Application.delete_env(:bezalel, :stills_test_pid)
      Bezalel.Agent.release_all()
    end)

    :ok
  end

  defp jpeg(name), do: File.read!(Path.join(@fixtures, name))

  defp tap(view, event), do: render_info(view, {:tap, event})

  # Where the store keeps the video, scripted before it's there.
  defp script_video(frame, extra \\ []) do
    path = MaterialStore.path(Materials.new(@video, name: "clip.mp4"))
    File.mkdir_p!(Path.dirname(path))
    unless File.exists?(path), do: File.write!(path, @video)

    Fake.script(
      path,
      [
        info: %{duration_ms: 10_000, has_video: true, width: 4, height: 4, mime: "video/mp4"},
        frame: {frame, 4, 4}
      ] ++ extra
    )

    path
  end

  test "a video's detail picks a still: the frame follows the scrubber, and Keep keeps that frame" do
    script_video(jpeg("quads_444.jpg"))
    {:ok, video} = MaterialStore.put(Materials.new(@video, name: "clip.mp4"), @video, %{})

    view =
      AppScreen
      |> mount_screen()
      |> tap({:tab, :materials})
      |> tap({:materials, {:open, video.id}})

    assert text(view) =~ "Pick a still"

    view = view |> tap({:materials, {:stills, video.id}}) |> render_async()
    assert assigns(view).sheet == {:stills, video.id}
    assert %{duration_ms: 10_000, frame: {:ok, %{at_ms: 0}}} = assigns(view).stills
    assert text(view) =~ "0:00.0 of 0:10.0"
    assert_renderable(view)

    # Two moves in quick succession: only where it rests is decoded.
    script_video(jpeg("detail_444.jpg"))
    view = render_info(view, {:change, {:stills, :at}, 1_000.0})
    view = render_info(view, {:change, {:stills, :at}, 4_321.6})
    assert_receive {:stills, :settle, 1} = stale, 1_000
    view = render_info(view, stale)
    assert %{frame: {:ok, %{at_ms: 0}}, loading: false} = assigns(view).stills

    assert_receive {:stills, :settle, 2} = settle, 1_000
    view = view |> render_info(settle) |> render_async()
    assert {:ok, %{at_ms: 4_322}} = assigns(view).stills.frame
    assert text(view) =~ "0:04.3 of 0:10.0"
    # The replaced preview is gone.
    assert [preview] = Path.wildcard(Path.join([MaterialStore.cache_dir(), "stills", "*"]))
    assert preview =~ "-4322.jpg"

    # Kept twice, the same frame is one still.
    view = view |> tap({:stills, :keep}) |> tap({:stills, :keep})
    assert [_one] = assigns(view).stills.kept

    assert [still] = MaterialStore.derivatives(video.id, %{})

    assert %{derivation: :still, kind: :image, mime: "image/jpeg", meta: %{at_ms: 4_322}} =
             still

    assert MaterialStore.read(still, %{}) == {:ok, jpeg("detail_444.jpg")}
    assert MaterialStore.sessions(still.id) == [assigns(view).conversation.session_id]
    assert assigns(view).toast.text =~ still.name
    # From Materials, a still isn't put on a question until asked.
    assert assigns(view).attachments == []
    assert Enum.map(assigns(view).mat_open.stills, & &1.id) == [still.id]

    view = tap(view, {:stills, :close})
    assert assigns(view).sheet == nil
    assert Path.wildcard(Path.join([MaterialStore.cache_dir(), "stills", "*"])) == []

    view = tap(view, {:materials, {:ask, still.id}})
    assert assigns(view).tab == :study
    assert [%{id: id}] = assigns(view).attachments
    assert id == still.id
  end

  test "a video without a picture says so, and nothing can be kept" do
    path = script_video(jpeg("quads_444.jpg"))
    Fake.script(path, info: %{duration_ms: 3_000, has_video: false, has_audio: true})
    {:ok, video} = MaterialStore.put(Materials.new(@video, name: "clip.mp4"), @video, %{})

    view =
      AppScreen
      |> mount_screen()
      |> tap({:materials, {:stills, video.id}})
      |> render_async()

    assert {:error, "This video has no picture" <> _} = assigns(view).stills.frame
    view = tap(view, {:stills, :keep})
    assert MaterialStore.derivatives(video.id, %{}) == []
    assert_renderable(view)
  end

  test "a picker closed by a swipe stops and cleans up; a late frame never lands in the next one" do
    script_video(jpeg("quads_444.jpg"))
    {:ok, a} = MaterialStore.put(Materials.new(@video, name: "clip.mp4"), @video, %{})
    other = "another video's bytes"
    {:ok, b} = MaterialStore.put(Materials.new(other, name: "other.mp4"), other, %{})
    Fake.script(MaterialStore.path(b), info: {:error, :unsupported})

    view = AppScreen |> mount_screen() |> tap({:materials, {:stills, a.id}}) |> render_async()
    assert {:ok, _} = assigns(view).stills.frame

    view = render_info(view, {:dismiss, :sheet})
    assert assigns(view).sheet == nil
    assert assigns(view).stills == nil
    assert Path.wildcard(Path.join([MaterialStore.cache_dir(), "stills", "*"])) == []

    # A's frame still being made when its picker closes and B's opens.
    Fake.script(MaterialStore.path(a),
      info: %{duration_ms: 10_000, has_video: true},
      frame: {jpeg("detail_444.jpg"), 4, 4},
      delay: 100
    )

    view = view |> tap({:materials, {:stills, a.id}}) |> render_async()
    view = render_info(view, {:change, {:stills, :at}, 2_000.0})
    assert_receive {:stills, :settle, _} = settle, 1_000
    view = view |> render_info(settle) |> tap({:materials, {:stills, b.id}}) |> render_async()

    assert assigns(view).sheet == {:stills, b.id}
    assert {:error, "This phone can't read this video" <> _} = assigns(view).stills.frame
    view = tap(view, {:stills, :keep})
    assert MaterialStore.derivatives(b.id, %{}) == []
    assert Path.wildcard(Path.join([MaterialStore.cache_dir(), "stills", a.id <> "-*"])) == []
    assert_renderable(view)
  end

  test "a video added while another sheet is up doesn't push the picker over it" do
    script_video(jpeg("quads_444.jpg"))
    picked = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-clip.mp4")
    File.write!(picked, @video)

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:photos, :picked, [%{path: picked, name: "clip.mp4", type: :video}]})

    view =
      view
      |> tap({:attach, {:video_ok, elem(assigns(view).sheet, 1)}})
      |> tap({:attach, :menu})
      |> render_async()

    assert assigns(view).sheet == :attach
    assert assigns(view).stills == nil
    assert assigns(view).toast.text =~ "Pick stills from it in Materials"
    assert [%{kind: :video}] = assigns(view).attachments
  end

  test "right after a video is added, its picker opens; a still kept goes on the question as a picture, and draw_image can draw from it" do
    pcm = for i <- 0..7_999, into: <<>>, do: <<rem(i, 100) * 50::little-signed-16>>
    script_video(jpeg("quads_444.jpg"), audio: {pcm, 16_000, 1})
    Whisper.put_text("Look at the lampstand")
    still_id = Materials.new(jpeg("quads_444.jpg")).id

    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

    {:ok, llm} =
      FakeLLM.start([
        [{:tool_call, "d1", "draw_image", %{"prompt" => "Gold", "references" => [still_id]}}],
        [{:text, "Drawn from your still."}]
      ])

    Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)
    Application.put_env(:bezalel, :stills_test_pid, self())

    Application.put_env(:bezalel_core, :draw_image,
      generate: {__MODULE__, :generate},
      credential: {__MODULE__, :openai_key}
    )

    picked = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-clip.mp4")
    File.write!(picked, @video)

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:photos, :picked, [%{path: picked, name: "clip.mp4", type: :video}]})

    view = view |> tap({:attach, {:video_ok, elem(assigns(view).sheet, 1)}}) |> render_async()
    [video] = assigns(view).attachments
    assert assigns(view).sheet == {:stills, video.id}
    assert {:ok, %{at_ms: 0}} = assigns(view).stills.frame

    view = view |> tap({:stills, :keep}) |> tap({:stills, :close})
    assert Enum.map(assigns(view).attachments, & &1.id) == [video.id, still_id]

    view =
      view
      |> render_info({:change, :draft, "Draw this in gold"})
      |> tap({:study, :send})
      |> render_async()
      |> drain_loop()

    assert_receive {:llm_request, request}
    question = request.messages |> Enum.filter(&(&1.role == :user)) |> List.last()
    assert Enum.any?(question.content, &(&1.type == :image and is_binary(&1.data)))
    assert Enum.any?(question.content, &(&1.type == :text and &1.text =~ "Look at the lampstand"))

    assert_receive {:drew_from, source}
    assert source == jpeg("quads_444.jpg")
    assert Enum.any?(assigns(view).messages, &(&1.text == "Draw this in gold"))
  end

  # Feeds the loop's events to the screen until its run ends.
  defp drain_loop(view) do
    receive do
      {:rho, _session, %{type: :agent_end}} = message -> render_info(view, message)
      {:rho, _session, _event} = message -> view |> render_info(message) |> drain_loop()
    after
      3_000 -> flunk("the loop went quiet")
    end
  end

  @doc false
  def generate(model, _prompt, opts) do
    send(Application.fetch_env!(:bezalel, :stills_test_pid), {:drew_from, opts[:source_image]})

    message = %ReqLLM.Message{
      role: :assistant,
      content: [ContentPart.image(Png.solid(8, 8, {1, 2, 3}), "image/png")]
    }

    {:ok, %ReqLLM.Response{id: "img_1", model: model, context: nil, message: message}}
  end

  @doc false
  def openai_key(:openai), do: {:ok, %{type: :api_key, key: "sk-test"}}
end
