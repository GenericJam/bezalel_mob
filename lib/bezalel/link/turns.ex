defmodule Bezalel.Link.Turns do
  @moduledoc """
  Who is writing a conversation's session now, kept outside the dialers so
  no phone turn waits on a connection: the phone's turns (one per session
  uid, the process answering in it) and the websites' holds (`conv.hold`,
  one per uid and dialer). A public ETS table this process owns; it
  monitors the turns' owners and the holding dialers and drops what they
  leave when they go.

  A phone turn and a website's hold or write exclude each other: both are
  taken under the conversation's lock (`Bezalel.Link.Serve.locked/2`), and
  the website's writes check `phone?/1` under it. A dialer hears of a turn
  by message (`{:phone_turn, uid, :start | :finish}`) and reads
  `phone_turns/0` at each `welcome`, so one started mid-turn sends
  `conv.hold` too.
  """
  use GenServer

  alias Bezalel.Link
  alias Bezalel.Link.{Serve, TornTail}

  @table __MODULE__

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Whether a connected website holds this conversation (`conv.hold`)."
  @spec held?(term()) :: boolean()
  def held?(uid) when is_binary(uid),
    do: table?() and :ets.select_count(@table, [{{{:web, uid, :_}, :_}, [], [true]}]) > 0

  def held?(_uid), do: false

  @doc "Whether the phone is answering in this conversation."
  @spec phone?(term()) :: boolean()
  def phone?(uid) when is_binary(uid), do: table?() and :ets.member(@table, {:phone, uid})
  def phone?(_uid), do: false

  @doc "The uids the phone is answering in."
  @spec phone_turns() :: [String.t()]
  def phone_turns,
    do: if(table?(), do: :ets.select(@table, [{{{:phone, :"$1"}, :_}, [], [:"$1"]}]), else: [])

  @doc """
  Starts (`:start`) or ends (`:finish`) the phone's turn in a conversation.
  A start is `{:error, :held_by_web}` while a website holds it; otherwise
  the turn is the caller's until `:finish` or until the caller exits. A
  start first sets aside a website's torn last line
  (`Bezalel.Link.TornTail.repair/1`), so nothing the phone writes joins
  it.
  """
  @spec phone_turn(term(), :start | :finish) :: :ok | {:error, :held_by_web}
  def phone_turn(uid, :start) when is_binary(uid) do
    if running?(), do: Serve.locked(uid, fn -> start_locked(uid) end), else: :ok
  end

  def phone_turn(uid, :finish) when is_binary(uid) do
    if running?(), do: GenServer.call(__MODULE__, {:finish, uid}), else: :ok
  end

  def phone_turn(_uid, _action), do: :ok

  @doc """
  A website's hold, for the calling dialer: `{:error, :held_by_phone}`
  while the phone answers in the conversation.
  """
  @spec web_hold(String.t(), String.t()) :: :ok | {:error, :held_by_phone}
  def web_hold(uid, origin) do
    Serve.locked(uid, fn ->
      if phone?(uid),
        do: {:error, :held_by_phone},
        else: GenServer.call(__MODULE__, {:web, uid, self(), origin})
    end)
  end

  @doc "Drops the calling dialer's hold on `uid`."
  @spec web_release(String.t()) :: :ok
  def web_release(uid) do
    if table?(), do: :ets.delete(@table, {:web, uid, self()})
    :ok
  end

  @doc "Drops every hold of the calling dialer (its connection closed)."
  @spec web_release_all() :: :ok
  def web_release_all do
    if table?(), do: :ets.match_delete(@table, {{:web, :_, self()}, :_})
    :ok
  end

  defp running?, do: Process.whereis(__MODULE__) != nil
  defp table?, do: :ets.whereis(@table) != :undefined

  defp start_locked(uid) do
    if held?(uid) do
      {:error, :held_by_web}
    else
      :ok = TornTail.repair(uid)
      GenServer.call(__MODULE__, {:phone, uid, self()})
    end
  end

  # ── GenServer ──

  @impl true
  def init(nil) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, %{turns: %{}, dialers: %{}}}
  end

  @impl true
  def handle_call({:phone, uid, owner}, _from, state) do
    if :ets.insert_new(@table, {{:phone, uid}, owner}) do
      ref = Process.monitor(owner)
      notify({:phone_turn, uid, :start})
      {:reply, :ok, %{state | turns: Map.put(state.turns, ref, uid)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call({:finish, uid}, _from, state), do: {:reply, :ok, finish(state, uid)}

  def handle_call({:web, uid, dialer, origin}, _from, state) do
    :ets.insert(@table, {{:web, uid, dialer}, origin})

    dialers =
      Map.put_new_lazy(state.dialers, dialer, fn -> Process.monitor(dialer) end)

    {:reply, :ok, %{state | dialers: dialers}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.pop(state.turns, ref) do
      {nil, _} ->
        # A dialer that went without closing (killed): its holds go, and
        # the screens hear so.
        for {{:web, uid, ^pid}, origin} <- :ets.match_object(@table, {{:web, :_, pid}, :_}) do
          :ets.delete(@table, {:web, uid, pid})
          Link.broadcast(origin, {:conversation_hold, uid, false})
        end

        {:noreply, %{state | dialers: Map.delete(state.dialers, pid)}}

      {uid, turns} ->
        :ets.delete(@table, {:phone, uid})
        notify({:phone_turn, uid, :finish})
        {:noreply, %{state | turns: turns}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp finish(state, uid) do
    case Enum.find(state.turns, fn {_ref, turn} -> turn == uid end) do
      nil ->
        state

      {ref, ^uid} ->
        Process.demonitor(ref, [:flush])
        :ets.delete(@table, {:phone, uid})
        notify({:phone_turn, uid, :finish})
        %{state | turns: Map.delete(state.turns, ref)}
    end
  end

  # Every running dialer, without calling one (a dialer can be busy
  # connecting for seconds).
  defp notify(message) do
    for pid <- Link.dialers(), do: send(pid, message)
    :ok
  end
end
