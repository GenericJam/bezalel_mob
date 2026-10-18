defmodule Bezalel.Views.Usage do
  @moduledoc """
  Usage on the phone, laid out from bezalel_core's `Bezalel.Usage` over
  rho's record (`usage`, `Bezalel.Account.usage/0`, re-read on every
  `{:rho_usage, :changed}`), so running out is never a mystery:

    * Settings → Usage: per signed-in provider, a subscription's limit
      windows (percent used, when each resets) with Refresh (its usage
      endpoint), an API key's spend today and this week with its billing
      page, and the tokens per model today and this week.
    * The meter above Study's composer field: the chosen model and its
      provider's fullest window (or an API key's spend today), coloured as
      it nears its limit (80 %) and when it's used up.
    * A reply's tokens and cost, in its ⋯ menu.
    * The card of a failed reply: what went wrong in plain words
      (`Bezalel.Usage.explain/2`) and the button for what to do. A question
      that can't go (no credential, a limit used up: `Bezalel.Usage.preflight/3`)
      fails before it's sent, explained the same way (`explained`, keyed by
      the reply's error text; a used-up limit's countdown is worked out
      again at every render).
  """
  import Mob.Sigil

  alias Bezalel.{Account, Models}
  alias Bezalel.Agent.Reply
  alias Bezalel.Usage
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.UI
  alias Rho.Auth

  @doc "The screen's usage assigns."
  def assigns, do: [usage: Account.usage(), usage_refreshing: false, explained: %{}]

  # ── Settings → Usage ─────────────────────────────────────────────────────

  @doc "Settings → Usage: a card per signed-in provider, and Refresh."
  def settings(assigns) do
    case Usage.summary(assigns.usage, auth: assigns.account) do
      [] ->
        [
          UI.card(
            [
              note(
                "Sign in or add an API key (Account, above) to see here how much of your plan is left, or what your key has spent."
              )
            ],
            padding: 16,
            gap: 8
          )
        ]

      summaries ->
        Enum.map(summaries, &provider_card/1) ++ refresh(summaries, assigns)
    end
  end

  defp provider_card(%{kind: :subscription} = s) do
    windows =
      case s.windows do
        [] ->
          [note("No figures yet: they come with the next reply, or tap Refresh.")]

        windows ->
          Enum.map(windows, &window/1)
      end

    UI.card(
      [header(s.name, s.plan && "#{String.capitalize(s.plan)} plan") | windows] ++
        checked(s.checked_at) ++ models(s.models, :subscription),
      padding: 16,
      gap: 12
    )
  end

  defp provider_card(%{kind: :api_key} = s) do
    billing = {self(), {:settings, {:open_url, s.billing_url}}}

    spend = ~MOB"""
    <Row gap={8} align={:end}>
      <Text
        text={Usage.money(s.spend.today.cost)}
        font={:display}
        text_size={30}
        text_color={:on_surface}
      />
      <Text
        text={"today · " <> Usage.money(s.spend.week.cost) <> " this week"}
        text_size={12}
        text_color={:muted}
      />
    </Row>
    """

    link =
      if s.billing_url,
        do: [
          UI.pill_button("Billing page", billing, :outline,
            height: 36,
            fill: false,
            text_size: 13
          )
        ],
        else: []

    UI.card(
      [
        header(s.name, nil),
        spend,
        note(
          "The provider doesn't tell apps a key's balance: this is what its tokens cost at the provider's prices. Your credit and limits are on its billing page."
        )
        | link
      ] ++ models(s.models, :api_key),
      padding: 16,
      gap: 12
    )
  end

  defp header(name, plan) do
    sub = if plan, do: [note(plan)], else: []

    ~MOB"""
    <Column gap={2} fill_width={true}>
      <Text text={name} font={:ui_medium} text_size={15} text_color={:on_surface} />
      {sub}
    </Column>
    """
  end

  defp window(w) do
    resets =
      cond do
        w.level == :exhausted and w.resets_in -> "Used up · resets in #{w.resets_in}"
        w.level == :exhausted -> "Used up"
        w.resets_in -> "Resets in #{w.resets_in}"
        true -> nil
      end

    ~MOB"""
    <Column gap={5} fill_width={true}>
      <Row fill_width={true}>
        <Text text={w.label} font={:ui_medium} text_size={13} text_color={:on_surface} weight={1} />
        <Text
          text={"#{w.percent}%"}
          font={:ui_medium}
          text_size={13}
          text_color={text_color(w.level)}
        />
      </Row>
      {UI.meter(w.percent / 100, bar_color(w.level))}
      {note(resets)}
    </Column>
    """
  end

  defp checked(nil), do: []

  defp checked(at) do
    ago = System.os_time(:second) - at
    [note("Checked " <> if(ago < 60, do: "just now", else: "#{Rho.Usage.duration(ago)} ago"))]
  end

  # Tokens per model today and this week (the cost too, for a key); a
  # model's aliases and dated snapshots count as the catalog's model.
  defp models([], _kind), do: []

  defp models(models, kind) do
    rows =
      models
      |> Enum.group_by(&label(&1.model), &{&1.today, &1.week})
      |> Enum.map(fn {{name, dot}, figures} ->
        {name, dot, add(Enum.map(figures, &elem(&1, 0))), add(Enum.map(figures, &elem(&1, 1)))}
      end)
      |> Enum.sort_by(fn {name, _dot, _today, week} -> {-week.tokens, name} end)

    top = rows |> Enum.map(fn {_, _, _, week} -> week.tokens end) |> Enum.max()

    lines =
      for {name, dot, today, week} <- rows do
        figures =
          case kind do
            :api_key ->
              "#{Usage.tokens(today.tokens)} today · #{Usage.tokens(week.tokens)} this week · #{Usage.money(week.cost)}"

            :subscription ->
              "#{Usage.tokens(today.tokens)} today · #{Usage.tokens(week.tokens)} this week"
          end

        ~MOB"""
        <Column gap={5} fill_width={true}>
          <Row gap={8} fill_width={true}>
            <Text text={name} font={:ui_medium} text_size={13} text_color={:on_surface} weight={1} />
            <Text text={figures} text_size={12} text_color={:muted} />
          </Row>
          {UI.meter(if(top > 0, do: week.tokens / top, else: 0.0), dot)}
        </Column>
        """
      end

    [UI.kicker("Tokens per model") | lines]
  end

  defp add(totals), do: Enum.reduce(totals, &Map.merge(&1, &2, fn _k, a, b -> a + b end))

  # Usage is kept under the spec a call used: the catalog's name for it, or
  # the spec itself for a model the catalog no longer lists.
  defp label(spec) do
    case Models.lookup(spec) do
      %{name: name, dot: dot} ->
        {name, dot}

      nil ->
        provider =
          case Auth.provider_for_model(spec) do
            {:ok, provider} -> provider
            :error -> nil
          end

        {spec, Models.dot(provider) || :muted}
    end
  end

  defp refresh(summaries, assigns) do
    if Enum.any?(summaries, &(&1.kind == :subscription)) do
      label = if assigns.usage_refreshing, do: "Checking…", else: "Refresh"
      tap = {self(), {:settings, :refresh_usage}}

      [
        UI.pill_button(label, tap, :outline, height: 40, fill: false, text_size: 13),
        note(
          "Your plan's figures update with every reply; Refresh asks Claude or ChatGPT for them now."
        )
      ]
    else
      []
    end
  end

  @doc "Refresh: asks the subscriptions' usage endpoints, off the screen's process."
  def refresh_usage(%{assigns: %{usage_refreshing: true}} = socket), do: socket

  def refresh_usage(socket) do
    status = socket.assigns.account

    socket
    |> Socket.assign(:usage_refreshing, true)
    |> Socket.start_async(:usage_refresh, fn -> Account.refresh_usage(status) end)
  end

  @doc "Refresh answered: the figures (re-read) and, for any that didn't, why."
  def refreshed(result, socket) do
    socket = socket |> Socket.assign(:usage_refreshing, false) |> reload()

    case result do
      {:ok, []} ->
        socket

      {:ok, failures} ->
        why =
          Enum.map_join(failures, "; ", fn {provider, reason} ->
            "#{Account.subscription_name(provider)}: #{reason}"
          end)

        Helpers.toast(socket, "Couldn't check usage (#{why}).")

      {:exit, _reason} ->
        Helpers.toast(socket, "Couldn't check usage. Try again.")
    end
  end

  @doc "Re-reads rho's usage record."
  def reload(socket), do: Socket.assign(socket, :usage, Account.usage())

  # ── Study ────────────────────────────────────────────────────────────────

  @doc """
  The line above Study's composer field: the chosen model and its usage.
  Nothing without a credential for it, or for a subscription before
  there are figures; an API key always has its spend today. Tapping it
  opens Settings.
  """
  def meter(assigns) do
    model = Models.get(assigns.model_id)

    case Usage.meter(assigns.usage, model.id, auth: assigns.account) do
      nil ->
        []

      m ->
        tap = {self(), {:tab, :settings}}

        [
          ~MOB"""
          <Row id="usage-meter" gap={6} align={:center} fill_width={true} on_tap={tap}>
            <Box width={7} height={7} corner_radius={4} background={model.dot} fill_width={false} />
            <Text text={model.name} font={:ui_medium} text_size={11} text_color={:muted} />
            <Text
              text={"· " <> m.text}
              font={:ui_medium}
              text_size={11}
              text_color={text_color(m.level)}
              weight={1}
            />
          </Row>
          """
        ]
    end
  end

  @doc """
  Can a question go to the chosen model now? `:ok`, or `{:error, socket,
  text}`: the reply's error text, its explanation kept for the card.
  """
  def preflight(socket, model) do
    assigns = socket.assigns

    if Models.available?(model, assigns.account) do
      case Usage.preflight(assigns.usage, model.id, auth: assigns.account) do
        :ok -> :ok
        {:exhausted, e} -> explained(socket, e.message, e)
      end
    else
      text =
        "#{model.name} needs a #{Models.needs(model.provider)}. Add one in Settings → " <>
          "Account, or choose a model you have access to."

      explained(socket, text, %{
        kind: :signed_out,
        title: "Not signed in",
        message: text,
        action: :sign_in,
        provider: model.provider,
        until: nil,
        billing_url: nil,
        detail: text
      })
    end
  end

  # Kept only for the failed replies still shown, so the map doesn't grow.
  defp explained(socket, text, explanation) do
    shown = for {_cid, %Reply{status: :error, error: e}} <- socket.assigns.streams, do: e

    explained =
      socket.assigns.explained
      |> Map.take(shown)
      |> Map.put(text, explanation)

    {:error, Socket.assign(socket, :explained, explained), text}
  end

  @doc """
  A failed reply's card: what happened, what to do, and the buttons for
  it (Try again always; choose a model, the billing page or Settings as the
  explanation says).
  """
  def failure(%Reply{status: :error} = r, assigns) do
    error = r.error || "The reply failed."

    e =
      case assigns.explained[error] do
        nil -> Usage.explain(error, state: assigns.usage, model: r.model, auth: assigns.account)
        stored -> current(stored, r.model, assigns)
      end

    buttons = [button("Try again", {self(), {:study, :retry}}) | actions(e)]

    UI.card(
      [
        UI.kicker(e.title, :error),
        ~MOB(<Text text={e.message} text_size={14} line_height={1.5} text_color={:on_surface} />)
        | detail(e)
      ] ++
        [
          ~MOB(<Wrap spacing={10} run_spacing={10} fill_width={true}>
  {buttons}
</Wrap>)
        ],
      padding: 16,
      gap: 10
    )
  end

  def failure(_reply, _assigns), do: []

  # A used-up limit as it stands now: its countdown worked out again, or,
  # once the limit has lifted, a nudge to try again.
  defp current(%{kind: :limit_reached} = stored, model, assigns) do
    case Usage.preflight(assigns.usage, model, auth: assigns.account) do
      {:exhausted, e} ->
        e

      :ok ->
        %{
          stored
          | title: "Ready to try again",
            message: "That limit no longer holds this model back. Tap Try again.",
            action: :retry,
            until: nil
        }
    end
  end

  defp current(stored, _model, _assigns), do: stored

  defp button(label, tap),
    do: UI.pill_button(label, tap, :outline, height: 40, fill: false, text_size: 13)

  # What the explanation says to do, as buttons beside Try again.
  defp actions(%{action: action}) when action in [:wait, :switch_model],
    do: [button("Choose a model", {self(), {:settings, :models}})]

  defp actions(%{action: :add_credit, billing_url: url}) do
    billing =
      if url, do: [button("Billing page", {self(), {:settings, {:open_url, url}}})], else: []

    billing ++ [button("Choose a model", {self(), {:settings, :models}})]
  end

  defp actions(%{action: action}) when action in [:add_key, :sign_in],
    do: [button("Open Settings", {self(), {:tab, :settings}})]

  defp actions(_retry), do: []

  # The provider's own words, smaller, where the message is Bezalel's.
  defp detail(%{kind: kind, detail: detail, message: message})
       when kind not in [:failed, :signed_out, :limit_reached] and detail not in ["", message],
       do: [~MOB(<Text text={detail} text_size={12} line_height={1.4} text_color={:muted} />)]

  defp detail(_e), do: []

  @doc "A reply's tokens and cost, under its open ⋯ menu (nothing for a scripted one)."
  def reply_line(%{usage: %{text: text}}) do
    [~MOB(<Text id="reply-usage" text={"Used " <> text} text_size={11} text_color={:muted} />)]
  end

  def reply_line(_message), do: []

  # ── Shared ───────────────────────────────────────────────────────────────

  defp note(nil), do: []

  defp note(text),
    do: ~MOB(<Text text={text} text_size={12} line_height={1.45} text_color={:muted} />)

  defp text_color(:ok), do: :muted
  defp text_color(:warn), do: :secondary
  defp text_color(:exhausted), do: :error

  defp bar_color(:ok), do: :muted
  defp bar_color(:warn), do: :secondary
  defp bar_color(:exhausted), do: :error
end
