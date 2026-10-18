defmodule Bezalel.MaterialsScreenTest do
  # Materials in the app: the + menu, the camera, the recorder, sending,
  # read-aloud and dictation, driven through Mob.ScreenCase. The screen runs
  # in the test process: the phone's native calls are recorded
  # (Bezalel.Test.Native), and what the platform would send back is fed to
  # the screen as messages.
  use Mob.ScreenCase
  @moduletag :screen

  import Kernel, except: [tap: 2]

  alias Bezalel.Agent.Live
  alias Bezalel.{AppScreen, Library, Materials, MaterialStore, Repo, Settings}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.MaterialStore.{Link, Row}
  alias Bezalel.Test.{FakeLLM, MemoryStore, Native, Png, Whisper}
  alias Bezalel.Views.{Attach, Study}
  alias Mob.Screen.Async
  alias MobMedia.PCM
  alias ReqLLM.Message.ContentPart

  setup do
    for schema <- [Tool, Conversation, Link, Row], do: Repo.delete_all(schema)

    for key <- [
          :bezalel_conversation,
          :bezalel_mode,
          :bezalel_model,
          :bezalel_study_preferences,
          :bezalel_read_aloud,
          :bezalel_voice
        ],
        do: Mob.State.delete(key)

    File.rm_rf!(MaterialStore.dir())
    MemoryStore.clear()
    Native.reset()
    Whisper.reset()

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Application.delete_env(:bezalel, :dictation)
      Bezalel.Agent.release_all()
    end)

    :ok
  end

  defp tmp(name, bytes) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, bytes)
    path
  end

  defp tap(view, event), do: render_info(view, {:tap, event})

  # The camera hands back a photo (after the + menu and the permission).
  defp take_photo(view, bytes \\ Png.solid(40, 30, {200, 10, 10})) do
    view
    |> tap({:attach, :camera})
    |> render_info({:permission, :camera, :granted})
    |> render_info({:camera, :photo, %{path: tmp("cam.png", bytes), width: 40, height: 30}})
    |> render_async()
  end

  defp recording do
    pcm = for i <- 0..15_999, into: <<>>, do: <<rem(i, 100) * 50::little-signed-16>>
    PCM.wav(pcm, 44_100, 1)
  end

  defp record(view) do
    view
    |> tap({:attach, :record})
    |> render_info({:permission, :microphone, :granted})
    |> tap({:attach, :stop_recording})
    |> render_info({:audio, :recorded, %{path: tmp("rec.wav", recording()), duration: 0.4}})
    # Kept, then transcribed.
    |> render_async()
    |> render_async()
  end

  describe "the + menu" do
    test "opens as a sheet offering each way to add, and the photo library opens the picker" do
      view = AppScreen |> mount_screen() |> tap({:attach, :menu})

      assert assigns(view).sheet == :attach

      for label <- ~w(Photo\ library Take\ a\ photo Record\ a\ video Record\ audio Files),
          do: assert(text(view) =~ label)

      view = tap(view, {:attach, :photos})
      assert assigns(view).sheet == nil
      assert [{:pick_photos, _opts}] = Native.calls()
    end

    test "a photo is taken only once the camera is allowed, and waits as a chip, kept in Materials" do
      view = AppScreen |> mount_screen() |> tap({:attach, :camera})
      assert Native.names() == [:request_permission]
      assert [{:request_permission, :camera}] = Native.calls()

      view = take_photo(view)
      assert :capture_photo in Native.names()

      assert [%{kind: :image, mime: "image/png", name: "Photo " <> _} = photo] =
               assigns(view).attachments

      assert {:ok, ^photo} = MaterialStore.fetch(photo.id, %{})
      # Its chip (the name cut to fit).
      assert text(view) =~ "Photo "
    end

    test "a refused camera says so and takes nothing" do
      view =
        AppScreen
        |> mount_screen()
        |> tap({:attach, :camera})
        |> render_info({:permission, :camera, :denied})

      refute :capture_photo in Native.names()
      assert assigns(view).toast.text =~ "camera"
      assert assigns(view).pending == nil
    end

    test "a video is recorded only after the notice, with the camera and the microphone allowed" do
      view = AppScreen |> mount_screen() |> tap({:attach, :video})
      assert assigns(view).sheet == {:video_notice, :camera}
      assert text(view) =~ Materials.video_notice()
      assert Native.calls() == []

      view =
        view
        |> tap({:attach, {:video_ok, :camera}})
        |> render_info({:permission, :camera, :granted})

      refute :capture_video in Native.names()
      view = render_info(view, {:permission, :microphone, :granted})
      assert :capture_video in Native.names()
      assert assigns(view).sheet == nil
    end

    test "a video picked from the library waits for the notice, and is kept only if the user goes on" do
      video = tmp("clip.mp4", "not really a video")
      image = tmp("photo.png", Png.solid(4, 4, {1, 1, 1}))

      items = [
        %{path: video, name: "clip.mp4", type: :video},
        %{path: image, name: "photo.png", type: :image, width: 4, height: 4}
      ]

      view =
        AppScreen |> mount_screen() |> render_info({:photos, :picked, items}) |> render_async()

      assert [%{name: "photo.png"}] = assigns(view).attachments
      assert {:video_notice, [%{name: "clip.mp4"}]} = assigns(view).sheet

      view = view |> tap({:attach, {:video_ok, elem(assigns(view).sheet, 1)}}) |> render_async()
      assert Enum.map(assigns(view).attachments, & &1.kind) == [:image, :video]
    end
  end

  describe "recording" do
    test "the recorder records, stops, keeps the recording and shows its transcript" do
      Whisper.put_text("In the beginning was the Word")

      view =
        AppScreen
        |> mount_screen()
        |> tap({:attach, :record})
        |> render_info({:permission, :microphone, :granted})

      assert :start_recording in Native.names()
      assert %{seconds: 0} = assigns(view).recorder
      assert text(view) =~ "Recording"

      view =
        view
        |> tap({:attach, :stop_recording})
        |> render_info({:audio, :recorded, %{path: tmp("rec.wav", recording()), duration: 0.4}})
        |> render_async()
        |> render_async()

      assert assigns(view).recorder == nil

      assert [%{kind: :audio, mime: "audio/wav", meta: %{duration_ms: 400}} = audio] =
               assigns(view).attachments

      assert assigns(view).transcripts[audio.id] == "In the beginning was the Word"
      assert text(view) =~ "In the beginning was the Word"
      assert [%{derivation: :transcript}] = MaterialStore.derivatives(audio.id, %{})
    end

    test "a cancelled recording is not kept" do
      path = tmp("rec.wav", recording())

      view =
        AppScreen
        |> mount_screen()
        |> tap({:attach, :record})
        |> render_info({:permission, :microphone, :granted})
        |> tap({:attach, :cancel_recording})
        |> render_info({:audio, :recorded, %{path: path, duration: 0.4}})

      assert assigns(view).attachments == []
      refute File.exists?(path)
      assert MaterialStore.list() == []
    end
  end

  describe "sending" do
    test "a photo goes with the question, by reference, and shows in the chat" do
      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments

      view =
        view
        |> render_info({:change, :draft, "What is this?"})
        |> tap({:study, :send})
        |> render_async()

      assert assigns(view).attachments == []
      question = Enum.find(assigns(view).messages, &(&1.text == "What is this?"))
      assert [%{id: id, kind: :image}] = question.materials
      assert id == photo.id
      # Linked to the conversation it was sent in.
      assert MaterialStore.sessions(photo.id) == [assigns(view).conversation.session_id]
    end

    test "a recording with no transcript yet is transcribed, and the model gets the transcript" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
      {:ok, llm} = FakeLLM.start([[{:text, "A reading from Genesis."}]])
      Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)

      view = AppScreen |> mount_screen()
      # Recorded, its transcription failed (no connection then), so the
      # question has to transcribe it.
      Whisper.put_text({:error, :network})
      view = record(view)
      [audio] = assigns(view).attachments
      assert {:error, _} = assigns(view).transcripts[audio.id]
      assert MaterialStore.derivatives(audio.id, %{}) == []

      Whisper.put_text("Let there be light")
      view = view |> tap({:study, :send}) |> render_async()

      assert_receive {:llm_request, request}
      question = List.last(request.messages)
      assert Enum.any?(question.content, &(&1.type == :text and &1.text =~ "Let there be light"))
      assert assigns(view).attachments == []
      assert [%{derivation: :transcript}] = MaterialStore.derivatives(audio.id, %{})
    end

    test "Try again sends the question's photo again, by reference" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

      {:ok, llm} =
        FakeLLM.start([[{:error, {:http, 401, "invalid x-api-key"}}], [{:text, "A red square."}]])

      Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)

      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments

      view =
        view
        |> render_info({:change, :draft, "What is this?"})
        |> tap({:study, :send})
        |> render_async()
        |> drain_loop()

      assert_receive {:llm_request, first}
      assert has_picture?(first)

      view = view |> tap({:study, :retry}) |> render_async() |> drain_loop()
      assert_receive {:llm_request, again}
      assert has_picture?(again)

      question = Enum.find(assigns(view).messages, &(&1.text == "What is this?"))
      assert [%{id: id}] = question.materials
      assert id == photo.id
    end

    # The request's last user message carries a picture with its bytes
    # (rho resolved the reference through the store).
    defp has_picture?(request) do
      question = request.messages |> Enum.filter(&(&1.role == :user)) |> List.last()
      Enum.any?(question.content, &(&1.type == :image and is_binary(&1.data)))
    end

    test "audio that can't be transcribed isn't sent, and the user is told why" do
      view = AppScreen |> mount_screen()
      Whisper.put_text({:error, :unavailable})
      view = record(view)

      view =
        view |> render_info({:change, :draft, "Listen"}) |> tap({:study, :send}) |> render_async()

      assert assigns(view).toast.text =~ "can't go to a model that doesn't take audio"
      assert [%{kind: :audio}] = assigns(view).attachments
      assert assigns(view).draft == "Listen"
      refute Enum.any?(assigns(view).messages, &(&1.text == "Listen"))
    end

    test "Try again with materials keeps its Try again if they can't be made ready, or the user moves on" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

      {:ok, llm} =
        FakeLLM.start([[{:error, {:http, 401, "invalid x-api-key"}}], [{:text, "A reading."}]])

      Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)
      Whisper.put_text("Let there be light")

      view = AppScreen |> mount_screen() |> record()
      [audio] = assigns(view).attachments
      cid = assigns(view).conversation.id

      view =
        view
        |> render_info({:change, :draft, "Listen"})
        |> tap({:study, :send})
        |> render_async()
        |> drain_loop()

      assert_receive {:llm_request, _first}
      assert %{status: :error} = assigns(view).streams[cid]

      # The transcript is gone and can't be made again now.
      for t <- MaterialStore.derivatives(audio.id, %{}), do: :ok = MaterialStore.delete(t.id)
      Whisper.put_text({:error, :unavailable})
      view = view |> tap({:study, :retry}) |> render_async()

      assert assigns(view).toast.text =~ "can't go to a model that doesn't take audio"
      assert %{status: :error} = assigns(view).streams[cid]
      assert Enum.any?(assigns(view).messages, &(&1.text == "Listen"))

      # Asked again, then the user moves on before it goes.
      Whisper.put_text("Let there be light")
      {:ok, other} = Library.create_conversation(%{name: "Other", kicker: "STUDY", kind: "Study"})

      view =
        view
        |> tap({:study, :retry})
        |> tap({:convs, {:open, other.id}})
        |> render_async()

      assert assigns(view).toast.text =~ "wasn't asked again"
      refute_received {:llm_request, _}

      view = tap(view, {:convs, {:open, cid}})
      assert %{status: :error} = assigns(view).streams[cid]

      _view = view |> tap({:study, :retry}) |> render_async() |> drain_loop()
      assert_receive {:llm_request, again}
      question = List.last(again.messages)
      assert Enum.any?(question.content, &(&1.type == :text and &1.text =~ "Let there be light"))
    end

    test "Try again waits while a new question's materials are made ready" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

      {:ok, llm} =
        FakeLLM.start([[{:error, {:http, 401, "invalid x-api-key"}}], [{:text, "A blue one."}]])

      Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)

      view =
        AppScreen
        |> mount_screen()
        |> render_info({:change, :draft, "Hello"})
        |> tap({:study, :send})
        |> drain_loop()

      assert_receive {:llm_request, _first}
      cid = assigns(view).conversation.id
      failed = assigns(view).streams[cid]
      assert %{status: :error} = failed

      view =
        view
        |> take_photo(Png.solid(10, 10, {0, 0, 200}))
        |> render_info({:change, :draft, "And this?"})
        |> tap({:study, :send})

      assert assigns(view).preparing != nil
      view = tap(view, {:study, :retry})
      assert assigns(view).streams[cid] == failed

      view = view |> render_async() |> drain_loop()
      assert_receive {:llm_request, request}
      assert has_picture?(request)
      refute_receive {:llm_request, _}, 100

      assert Enum.any?(assigns(view).messages, &(&1.text == "And this?"))
      assert Enum.any?(assigns(view).messages, &(&1.text == "Hello"))
    end

    test "something kept after the user moved on waits as a chip where they are now" do
      view =
        AppScreen
        |> mount_screen()
        |> tap({:attach, :camera})
        |> render_info({:permission, :camera, :granted})
        |> render_info(
          {:camera, :photo, %{path: tmp("cam.png", Png.solid(4, 4, {9, 9, 9})), width: 4}}
        )

      {:ok, other} = Library.create_conversation(%{name: "Other", kicker: "STUDY", kind: "Study"})
      view = view |> tap({:convs, {:open, other.id}}) |> render_async()
      assert assigns(view).conversation.id == other.id

      assert [%{kind: :image, id: id}] = assigns(view).attachments
      assert [%{id: ^id}] = MaterialStore.list()
      assert assigns(view).toast == nil
    end

    test "chips stay in the composer across conversations and go with the question asked there" do
      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments

      {:ok, other} = Library.create_conversation(%{name: "Other", kicker: "STUDY", kind: "Study"})
      view = view |> render_info({:change, :draft, "Half"}) |> tap({:convs, {:open, other.id}})
      assert assigns(view).attachments == [photo]
      assert assigns(view).draft == ""

      view = tap(view, {:convs, :new})
      refute assigns(view).conversation.id == other.id
      assert assigns(view).attachments == [photo]

      view =
        view
        |> render_info({:change, :draft, "Look"})
        |> tap({:study, :send})
        |> render_async()

      question = Enum.find(assigns(view).messages, &(&1.text == "Look"))
      assert [%{id: id}] = question.materials
      assert id == photo.id
      assert assigns(view).attachments == []
      # It went with this conversation only, not the one open when it was added.
      here = Library.get_conversation(assigns(view).conversation.id)
      assert MaterialStore.sessions(photo.id) == [here.session_id]
    end

    test "a question the user moved away from before it went gives its chips back there" do
      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments
      {:ok, other} = Library.create_conversation(%{name: "Other", kicker: "STUDY", kind: "Study"})

      view =
        view
        |> render_info({:change, :draft, "First"})
        |> tap({:study, :send})
        |> tap({:convs, {:open, other.id}})
        |> render_async()

      assert assigns(view).conversation.id == other.id
      assert assigns(view).attachments == [photo]
      assert assigns(view).draft == ""
      assert assigns(view).toast.text =~ "wasn't sent"
      refute Enum.any?(assigns(view).messages, &(&1.text == "First"))
    end

    test "a question that can't go doesn't give back chips deleted meanwhile, a video's stills too" do
      Whisper.put_text("In the beginning")
      bytes = "not really a video"
      {:ok, video} = MaterialStore.put(Materials.new(bytes, name: "clip.mp4"), bytes, %{})
      png = Png.solid(4, 4, {1, 1, 1})
      {:ok, still} = MaterialStore.put(Materials.derive(:still, video, png, meta: %{}), png, %{})

      view =
        AppScreen
        |> mount_screen()
        |> tap({:materials, {:ask, video.id}})
        |> tap({:materials, {:ask, still.id}})
        |> render_info({:change, :draft, "Watch"})
        |> tap({:study, :send})

      assert %{materials: [_, _]} = assigns(view).preparing

      view =
        view
        |> tap({:materials, {:confirm_delete, video.id}})
        |> render_async()

      assert assigns(view).preparing == nil
      assert assigns(view).attachments == []
      assert assigns(view).draft == "Watch"
    end

    test "a material deleted after its question's attachments were made ready isn't sent" do
      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments
      view = view |> render_info({:change, :draft, "Look"}) |> tap({:study, :send})
      assert %{materials: [_]} = assigns(view).preparing

      # The attachments are made ready before the delete is confirmed …
      ready = Attach.attachments([photo.id], [:text, :image], %{})
      view = tap(view, {:materials, {:confirm_delete, photo.id}})

      # … and arrive after it.
      cid = assigns(view).conversation.id
      {:noreply, socket} = AppScreen.handle_async({:prepare, cid}, {:ok, ready}, view.socket)
      view = %{view | socket: socket}

      assert assigns(view).preparing == nil
      refute Enum.any?(assigns(view).messages, &(&1.text == "Look"))
      assert assigns(view).attachments == []
      assert assigns(view).draft == "Look"
    end

    test "sending while a recording is transcribed waits for that transcript, not a second one" do
      Whisper.put_text("In the beginning")

      view =
        AppScreen
        |> mount_screen()
        |> tap({:attach, :record})
        |> render_info({:permission, :microphone, :granted})
        |> tap({:attach, :stop_recording})
        |> render_info({:audio, :recorded, %{path: tmp("rec.wav", recording()), duration: 0.4}})
        # Kept; its transcription starts.
        |> deliver_one()

      [audio] = assigns(view).attachments
      assert assigns(view).transcripts[audio.id] == :working

      view = view |> render_info({:change, :draft, "Listen"}) |> tap({:study, :send})
      assert %{started: false} = assigns(view).preparing

      view = render_async(view)
      assert [_one] = Whisper.heard()
      question = Enum.find(assigns(view).messages, &(&1.text == "Listen"))
      assert [%{id: id}] = question.materials
      assert id == audio.id
    end

    test "chips and words added while a question is made ready stay in the composer" do
      view = AppScreen |> mount_screen() |> take_photo()
      [first] = assigns(view).attachments

      bytes = Png.solid(6, 6, {0, 90, 0})
      {:ok, second} = MaterialStore.put(Materials.new(bytes, name: "leaf.png"), bytes, %{})

      view =
        view
        |> render_info({:change, :draft, "First"})
        |> tap({:study, :send})

      assert assigns(view).draft == ""
      assert assigns(view).attachments == []

      view =
        view
        |> tap({:materials, {:ask, second.id}})
        |> render_info({:change, :draft, "Second"})
        |> render_async()

      question = Enum.find(assigns(view).messages, &(&1.text == "First"))
      assert Enum.map(question.materials, & &1.id) == [first.id]
      assert Enum.map(assigns(view).attachments, & &1.id) == [second.id]
      assert assigns(view).draft == "Second"
    end

    test "Try again for a question that was only a photo, deleted since, keeps its Try again" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
      {:ok, llm} = FakeLLM.start([[{:error, {:http, 401, "invalid x-api-key"}}]])
      Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)

      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments
      cid = assigns(view).conversation.id
      view = view |> tap({:study, :send}) |> render_async() |> drain_loop()
      assert_receive {:llm_request, _first}

      :ok = MaterialStore.delete(photo.id)
      view = tap(view, {:study, :retry})

      assert assigns(view).toast.text =~ "nothing to ask again"
      assert %{status: :error} = assigns(view).streams[cid]
      assert assigns(view).preparing == nil
      refute_receive {:llm_request, _}, 100
    end

    test "a question that can't go comes back before words dictated meanwhile" do
      Application.put_env(:bezalel, :dictation,
        primary: {MobSpeech.Engine.Fake, script: [:listening, {:partial, "and more"}]}
      )

      Whisper.put_text({:error, :unavailable})
      view = AppScreen |> mount_screen() |> record()

      view =
        view
        |> render_info({:change, :draft, "Listen"})
        |> tap({:study, :send})
        |> tap({:attach, :mic})

      assert assigns(view).dictation != nil
      view = render_async(view)
      assert assigns(view).draft == "Listen"

      view = feed_speech(view, &match?({:speech, :partial, "and more"}, &1))
      assert assigns(view).draft == "Listen and more"
    end

    test "Try again while another question is on its way says so" do
      view = AppScreen |> mount_screen() |> take_photo()
      view = view |> render_info({:change, :draft, "Look"}) |> tap({:study, :send})
      assert assigns(view).preparing != nil

      view = tap(view, {:study, :ask_again})

      assert %{text: "A question is still on its way." <> _, ask_again: true} =
               assigns(view).toast
    end
  end

  describe "read aloud" do
    test "the speaker reads a reply's summary, made speakable; a second tap stops it" do
      view = AppScreen |> mount_screen()
      reply = Enum.find(assigns(view).messages, &(&1.role == :agent and &1.blocks != []))

      view = tap(view, {:study, {:speak, reply.id}})
      assert [{:stop_speaking, nil}, {:speak, {said, []}}] = Native.calls()
      assert said == Study.speakable(reply)
      assert said != "" and not (said =~ "**")
      assert assigns(view).speaking == reply.id

      Native.reset()
      view = tap(view, {:study, {:speak, reply.id}})
      assert Native.names() == [:stop_speaking]
      assert assigns(view).speaking == nil
    end

    test "the stop shows until the reading ends; a stopped reading's end doesn't clear the next" do
      view = AppScreen |> mount_screen()
      reply = Enum.find(assigns(view).messages, &(&1.role == :agent and &1.blocks != []))
      speak = {:study, {:speak, reply.id}}

      # Read, stopped, read again before the stopped one's :cancelled arrives.
      view = view |> tap(speak) |> tap(speak) |> tap(speak)
      assert assigns(view).speaking == reply.id

      view = render_info(view, {:speech, :cancelled})
      assert assigns(view).speaking == reply.id
      view = render_info(view, {:speech, :done})
      assert assigns(view).speaking == nil
    end

    test "the voice chosen in Settings reads" do
      Settings.put_voice(%{id: "en-gb-x-gbb-local", name: "English (UK) gbb", language: "en-GB"})
      view = AppScreen |> mount_screen()
      reply = Enum.find(assigns(view).messages, &(&1.role == :agent and &1.blocks != []))

      tap(view, {:study, {:speak, reply.id}})
      assert [_stop, {:speak, {_said, [voice: "en-gb-x-gbb-local"]}}] = Native.calls()
    end

    test "with Read replies aloud on, a finished reply is read" do
      view = AppScreen |> mount_screen() |> tap({:settings, {:read_aloud, true}})
      assert Settings.read_aloud?()

      view =
        view
        |> render_info({:change, :draft, "What does “skill” mean?"})
        |> tap({:study, :send})
        |> render_async()

      reply = List.last(assigns(view).messages)
      assert {:speak, {Study.speakable(reply), []}} in Native.calls()
    end
  end

  describe "dictation" do
    test "the platform recogniser's words land in the box after what was typed" do
      Application.put_env(:bezalel, :dictation,
        primary:
          {MobSpeech.Engine.Fake,
           script: [:listening, {:partial, "in the"}, {:partial, "in the beginning"}],
           on_stop: [{:final, "in the beginning God"}]}
      )

      view =
        AppScreen
        |> mount_screen()
        |> render_info({:change, :draft, "Note:"})
        |> tap({:attach, :mic})

      assert assigns(view).dictation != nil
      view = feed_speech(view, &match?({:speech, :partial, "in the beginning"}, &1))
      assert assigns(view).draft == "Note: in the beginning"

      view = view |> tap({:attach, :mic}) |> feed_speech(&match?({:speech, :final, _}, &1))
      assert assigns(view).draft == "Note: in the beginning God"
      assert assigns(view).dictation == nil
    end

    test "when the platform recogniser can't, Whisper takes over" do
      Application.put_env(:bezalel, :dictation,
        primary: {MobSpeech.Engine.Fake, script: [{:error, :language}]},
        fallback:
          {MobSpeech.Engine.Fake, script: [:listening], on_stop: [{:final, "on the phone"}]}
      )

      view = AppScreen |> mount_screen() |> tap({:attach, :mic})
      view = feed_speech(view, &match?({:speech, :error, _}, &1))
      assert %{engine: :fallback} = assigns(view).dictation

      view = view |> tap({:attach, :mic}) |> feed_speech(&match?({:speech, :final, _}, &1))
      assert assigns(view).draft == "on the phone"
      assert assigns(view).dictation_fallback
    end
  end

  # Feeds the recogniser's messages to the screen until `done?` holds for one.
  defp feed_speech(view, done?) do
    receive do
      {:speech, _, _} = message ->
        view = render_info(view, message)
        if done?.(message), do: view, else: feed_speech(view, done?)
    after
      2_000 -> flunk("the recogniser went quiet")
    end
  end

  describe "the Materials tab" do
    test "lists what was kept, opens one, asks about it and deletes it" do
      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments
      view = view |> tap({:attach, {:remove, photo.id}}) |> tap({:tab, :materials})

      assert assigns(view).tab == :materials
      assert [%{id: id}] = assigns(view).mat_list
      assert id == photo.id
      assert_renderable(view)

      view = tap(view, {:materials, {:open, photo.id}})
      assert %{material: %{id: ^id}} = assigns(view).mat_open
      assert text(view) =~ "Ask about this"
      assert_renderable(view)

      view = tap(view, {:materials, {:ask, photo.id}})
      assert assigns(view).tab == :study
      assert [%{id: ^id}] = assigns(view).attachments

      view =
        view
        |> tap({:tab, :materials})
        |> tap({:materials, {:open, photo.id}})
        |> tap({:materials, {:delete, photo.id}})

      assert assigns(view).sheet == {:delete_material, photo.id}
      view = tap(view, {:materials, {:confirm_delete, photo.id}})
      assert assigns(view).mat_list == []
      assert assigns(view).attachments == []
      assert MaterialStore.fetch(photo.id, %{}) == :error
    end

    test "each card's × deletes it, after the same question, and its chip goes" do
      view = AppScreen |> mount_screen() |> take_photo()
      [photo] = assigns(view).attachments
      view = tap(view, {:tab, :materials})

      x = find(view, :box, id: "delete-material-" <> photo.id)
      assert {_pid, {:materials, {:delete, id}}} = x.props.on_tap
      assert id == photo.id

      view = tap(view, {:materials, {:delete, id}})
      assert assigns(view).sheet == {:delete_material, photo.id}
      assert assigns(view).mat_open == nil

      view = tap(view, {:materials, {:confirm_delete, photo.id}})
      assert assigns(view).mat_list == []
      assert assigns(view).attachments == []
      assert MaterialStore.fetch(photo.id, %{}) == :error
    end

    test "deleting a video takes the chips of its stills with it" do
      video_bytes = "not really a video"

      {:ok, video} =
        MaterialStore.put(Materials.new(video_bytes, name: "clip.mp4"), video_bytes, %{})

      png = Png.solid(4, 4, {1, 1, 1})
      still = Materials.derive(:still, video, png, meta: %{at_ms: 0})
      {:ok, still} = MaterialStore.put(still, png, %{})

      {:ok, leaf} =
        MaterialStore.put(Materials.new(png <> "x", name: "leaf.png"), png <> "x", %{})

      view =
        AppScreen
        |> mount_screen()
        |> tap({:materials, {:ask, still.id}})
        |> tap({:materials, {:ask, leaf.id}})
        |> tap({:tab, :materials})
        |> tap({:materials, {:delete, video.id}})
        |> tap({:materials, {:confirm_delete, video.id}})

      assert MaterialStore.fetch(still.id, %{}) == :error
      assert Enum.map(assigns(view).attachments, & &1.id) == [leaf.id]
    end

    test "a drawing the agent made is kept, shown in its reply and listed" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

      Application.put_env(:bezalel_core, :draw_image,
        generate: {__MODULE__, :generate},
        credential: {__MODULE__, :openai_key}
      )

      on_exit(fn -> Application.delete_env(:bezalel_core, :draw_image) end)

      {:ok, llm} =
        FakeLLM.start([
          [{:tool_call, "d1", "draw_image", %{"prompt" => "The lampstand of Exodus 25"}}],
          [{:text, "Here it is."}]
        ])

      Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)

      view =
        AppScreen
        |> mount_screen()
        |> render_info({:change, :draft, "Draw the lampstand"})
        |> tap({:study, :send})
        |> drain_loop()

      drawing =
        Enum.find_value(
          assigns(view).messages,
          &Enum.find(&1.materials, fn m -> m.kind == :image end)
        )

      assert drawing

      assert {:ok, %{derivation: :generated, source: :received}} =
               MaterialStore.fetch(drawing.id, %{})

      assert MaterialStore.sessions(drawing.id) == [assigns(view).conversation.session_id]

      view = tap(view, {:tab, :materials})
      assert Enum.map(assigns(view).mat_list, & &1.id) == [drawing.id]
    end
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

  # Delivers the one start_async result that comes first.
  defp deliver_one(%{module: module, socket: socket} = view) do
    case Async.await(socket, 1_000) do
      {:deliver, name, outcome, socket} ->
        {:noreply, socket} = module.handle_async(name, outcome, socket)
        %{view | socket: socket}

      {:dropped, socket} ->
        deliver_one(%{view | socket: socket})
    end
  end

  @doc false
  def generate(model, _prompt, _opts) do
    message = %ReqLLM.Message{
      role: :assistant,
      content: [ContentPart.image(Png.solid(8, 8, {1, 2, 3}), "image/png")]
    }

    {:ok, %ReqLLM.Response{id: "img_1", model: model, context: nil, message: message}}
  end

  @doc false
  def openai_key(:openai), do: {:ok, %{type: :api_key, key: "sk-test"}}

  test "the conversation the material went with opens from its detail" do
    view = AppScreen |> mount_screen() |> take_photo()
    [photo] = assigns(view).attachments

    view =
      view
      |> render_info({:change, :draft, "Look"})
      |> tap({:study, :send})
      |> render_async()

    cid = assigns(view).conversation.id
    {:ok, other} = Library.create_conversation(%{name: "Other", kicker: "STUDY", kind: "Study"})
    view = view |> tap({:convs, {:open, other.id}}) |> tap({:materials, {:open, photo.id}})

    assert [%{id: ^cid}] = assigns(view).mat_open.conversations
    view = tap(view, {:materials, {:conversation, cid}})
    assert assigns(view).conversation.id == cid
    assert assigns(view).tab == :study
  end
end
