defmodule Bezalel.UsageScreenTest do
  # Usage on the phone (Bezalel.Views.Usage): Settings → Usage, the meter
  # under Study's composer, a reply's tokens in its ⋯ menu, a used-up
  # limit stopping a question before it's sent, and failed replies
  # explained. rho's record is written as usage.json in the run's data dir;
  # the model is scripted (Bezalel.Test.FakeLLM) and the usage endpoint
  # answered by the test (`config :bezalel, :usage_fetch`).
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.Agent.{Live, Reply}
  alias Bezalel.{AppScreen, Repo}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Test.{Browser, FakeLLM, MemoryStore}

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)

    for key <- [:bezalel_conversation, :bezalel_model, :bezalel_study_preferences],
        do: Mob.State.delete(key)

    MemoryStore.clear()
    File.rm(usage_file())

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Application.delete_env(:bezalel, :usage_fetch)
      Bezalel.Agent.release_all()
      File.rm(usage_file())
    end)

    :ok
  end

  defp usage_file, do: Path.join(Rho.Config.data_dir(), "usage.json")
  defp now, do: System.os_time(:second)
  defp today, do: Date.to_iso8601(Rho.Budget.today())
  defp put_usage(usage), do: File.write!(usage_file(), Jason.encode!(usage))

  defp sign_in_claude do
    :ok =
      Rho.Auth.put(:anthropic, %{
        "type" => "oauth",
        "access" => "access-token",
        "refresh" => "refresh-token",
        "expires" => System.os_time(:millisecond) + 3_600_000,
        "email" => "pastor@example.org"
      })
  end

  defp window(label, used, resets_at),
    do: %{"label" => label, "used" => used, "resets_at" => resets_at}

  defp claude_limits(windows),
    do: %{"anthropic" => %{"windows" => windows, "source" => "endpoint", "plan" => "Max"}}

  defp settings, do: AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})

  defp usage_text(view) do
    [_, after_usage] = String.split(text(view), "USAGE", parts: 2)
    [usage | _] = String.split(after_usage, "ON THIS PHONE", parts: 2)
    usage
  end

  # The Text whose text is `text`, exactly.
  defp text_node(view, text), do: Enum.find(find_all(view, :text), &(&1.props[:text] == text))

  defp taps(view) do
    for %{props: %{on_tap: {_, tag}}} <- find_all(view, :box), do: tag
  end

  defp script(replies) do
    {:ok, llm} = FakeLLM.start(replies)
    Application.put_env(:bezalel, Live, llm: {FakeLLM, llm}, retry_base_ms: 1)
  end

  defp ask(view, text) do
    view
    |> render_info({:change, :draft, text})
    |> render_info({:tap, {:study, :send}})
  end

  defp until_end(view) do
    receive do
      {:rho, _session, %{type: :agent_end}} = message -> render_info(view, message)
      {:rho, _session, _event} = message -> view |> render_info(message) |> until_end()
    after
      2_000 -> flunk("the loop went quiet")
    end
  end

  defp stream(view), do: assigns(view).streams[assigns(view).conversation.id]

  describe "Settings → Usage" do
    test "signed out, it says where to start" do
      assert usage_text(settings()) =~ "Sign in or add an API key"
    end

    test "a Claude sign-in: each window's share used and reset, the plan, the warning colour from 80 %, tokens per model this week" do
      sign_in_claude()
      counters = fn input, output -> %{"requests" => 1, "input" => input, "output" => output} end
      yesterday = Rho.Budget.today() |> Date.add(-1) |> Date.to_iso8601()

      put_usage(%{
        "limits" =>
          claude_limits(%{
            "5h" => window("5 hours", 42, now() + 4_830),
            "7d" => window("7 days", 85, now() + 3 * 86_400 + 100)
          }),
        "days" => %{
          today() => %{"anthropic:claude-haiku-4-5-20251001" => counters.(800, 400)},
          # An alias of the catalog's dated id counts with it.
          yesterday => %{"anthropic:claude-haiku-4-5" => counters.(50, 50)}
        }
      })

      view = settings()
      t = usage_text(view)

      assert t =~ "Claude Max plan"
      assert t =~ "5-hour limit 42% Resets in 1h 20m"
      assert t =~ "Weekly limit 85% Resets in 3d 0h"
      assert t =~ "Claude Haiku 4.5 1.2k today · 1.3k this week"
      assert text_node(view, "85%").props.text_color == :secondary
      assert text_node(view, "42%").props.text_color == :muted
      assert {:settings, :refresh_usage} in taps(view)
      assert_renderable(view)
    end

    test "an API key: what it spent today and this week, and its billing page" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
      spent = fn cost -> %{"requests" => 2, "input" => 1_000, "output" => 200, "cost" => cost} end
      two_days_ago = Rho.Budget.today() |> Date.add(-2) |> Date.to_iso8601()

      put_usage(%{
        "days" => %{
          today() => %{"anthropic:claude-haiku-4-5-20251001" => spent.(0.84)},
          two_days_ago => %{"anthropic:claude-haiku-4-5-20251001" => spent.(2.26)}
        }
      })

      view = settings()
      t = usage_text(view)

      assert t =~ "Anthropic API key $0.84 today · $3.10 this week"
      assert t =~ "Claude Haiku 4.5 1.2k today · 2.4k this week · $3.10"
      # No plan figures for a key: nothing to refresh.
      refute {:settings, :refresh_usage} in taps(view)

      render_info(
        view,
        {:tap, {:settings, {:open_url, "https://console.anthropic.com/settings/billing"}}}
      )

      assert Browser.last() == "https://console.anthropic.com/settings/billing"

      assert {:settings, {:open_url, "https://console.anthropic.com/settings/billing"}} in taps(
               view
             )
    end

    test "Refresh asks Claude for its figures now; a failure says why" do
      sign_in_claude()
      resets = DateTime.utc_now() |> DateTime.add(7_230) |> DateTime.to_iso8601()

      answer = fn status, body ->
        Application.put_env(:bezalel, :usage_fetch,
          respond: fn _req -> Req.Response.new(status: status, body: Jason.encode!(body)) end
        )
      end

      answer.(200, %{"five_hour" => %{"utilization" => 30, "resets_at" => resets}})
      view = settings()
      assert usage_text(view) =~ "No figures yet"

      view = render_info(view, {:tap, {:settings, :refresh_usage}})
      assert text_node(view, "Checking…")
      view = render_async(view)
      assert_receive {:rho_usage, :changed} = changed
      view = render_info(view, changed)

      assert usage_text(view) =~ "5-hour limit 30% Resets in 2h 0m"
      assert usage_text(view) =~ "Checked just now"
      refute text_node(view, "Checking…")

      answer.(429, %{"error" => %{"message" => "Too many requests"}})
      view = view |> render_info({:tap, {:settings, :refresh_usage}}) |> render_async()

      assert assigns(view).toast.text ==
               "Couldn't check usage (Claude: HTTP 429: Too many requests)."
    end
  end

  describe "Study" do
    test "the meter above the composer field: the model and its fullest window, warning near the limit, red when used up" do
      sign_in_claude()
      view = AppScreen |> mount_screen()
      # No figures yet: no meter.
      refute find(view, :row, id: "usage-meter")

      put_usage(%{"limits" => claude_limits(%{"5h" => window("5 hours", 86, now() + 630)})})
      view = render_info(view, {:rho_usage, :changed})
      line = text_node(view, "· Claude · 5-hour limit 86% · resets in 10m")
      assert line.props.text_color == :secondary
      assert find(view, :row, id: "usage-meter").props.on_tap |> elem(1) == {:tab, :settings}

      put_usage(%{"limits" => claude_limits(%{"5h" => window("5 hours", 100, now() + 630)})})
      view = render_info(view, {:rho_usage, :changed})
      line = text_node(view, "· Claude · 5-hour limit used up · resets in 10m")
      assert line.props.text_color == :error
    end

    test "a used-up limit stops the question before it's sent, saying when it resets, with Choose a model" do
      sign_in_claude()
      script([[{:text, "Never sent."}]])

      put_usage(%{
        "limits" => claude_limits(%{"5h" => window("5 hours", 100, now() + 5_430)})
      })

      view = AppScreen |> mount_screen() |> ask("Who is Bezalel?")

      assert %Reply{status: :error} = stream(view)
      refute_receive {:llm_request, _}
      t = text(view)
      assert t =~ "USAGE LIMIT REACHED"
      assert t =~ "Claude's 5-hour limit is used up. It resets at"
      assert t =~ "(in 1h 30m)"
      assert {:study, :retry} in taps(view)
      assert {:settings, :models} in taps(view)

      # The question waits for Try again.
      assert List.last(assigns(view).messages).text == "Who is Bezalel?"

      # Once the limit lifts, the card says so instead of a stale countdown.
      put_usage(%{"limits" => claude_limits(%{"5h" => window("5 hours", 100, now() - 1)})})
      view = render_info(view, {:rho_usage, :changed})

      assert text(view) =~
               "READY TO TRY AGAIN That limit no longer holds this model back. Tap Try again."

      refute {:settings, :models} in taps(view)
    end

    test "out of API credit is explained, with the billing page" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")

      script([
        [{:error, {:http, 400, "Your credit balance is too low to access the Anthropic API."}}]
      ])

      view = AppScreen |> mount_screen() |> ask("Who is Bezalel?") |> until_end()

      assert %Reply{status: :error} = stream(view)
      t = text(view)
      assert t =~ "OUT OF API CREDIT"
      assert t =~ "Your Anthropic account has run out of credit"
      # The provider's own words stay, smaller.
      assert t =~ "credit balance is too low"
      billing = {:settings, {:open_url, "https://console.anthropic.com/settings/billing"}}
      assert billing in taps(view)
      assert {:settings, :models} in taps(view)
    end

    test "a reply's ⋯ shows the tokens it used" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
      script([[{:text, "Bezalel was filled with the Spirit."}]])

      view = AppScreen |> mount_screen() |> ask("Who is Bezalel?") |> until_end()
      reply = List.last(assigns(view).messages)
      assert reply.role == :agent
      refute find(view, :text, id: "reply-usage")

      view = render_info(view, {:tap, {:study, {:menu, reply.id}}})
      assert find(view, :text, id: "reply-usage").props.text =~ "Used in 10 · out 5"

      # The user's own message has no usage line.
      question = Enum.at(assigns(view).messages, -2)
      view = render_info(view, {:tap, {:study, {:menu, question.id}}})
      refute find(view, :text, id: "reply-usage")
    end
  end
end
