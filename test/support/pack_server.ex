defmodule Bezalel.Test.PackServer do
  @moduledoc """
  A local stand-in for https://bezalel.genericjam.com/packs/ (Bandit on a
  free loopback port): serves a manifest and `.sqlite.zst` packs built by
  `pack/2`, honours `Range` like R2, and can misbehave on request: cut a
  response off after some bytes (`cut/3`), ignore ranges, or fail.
  Records each request's path and `Range` header.
  """
  @behaviour Plug

  import Plug.Conn

  alias Exqlite.Sqlite3

  @doc "Starts a server under the calling test's supervisor; returns `{server, base_url}`."
  def start do
    agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent, fn -> %{files: %{}, cuts: %{}, ignore_range: false, requests: []} end},
        id: make_ref()
      )

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit, plug: {__MODULE__, agent}, port: 0, ip: :loopback, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    {%{agent: agent}, "http://127.0.0.1:#{port}"}
  end

  @doc """
  A small SQLite pack named `name` (a `pack_meta` row tagged `tag`, so
  versions differ), as `%{raw: bytes, zst: bytes}`; `sql` adds to it (a
  translations pack's `translations` table).
  """
  def pack(name, tag, sql \\ "") do
    file = Path.join(System.tmp_dir!(), "pack_#{System.unique_integer([:positive])}.sqlite")
    {:ok, db} = Sqlite3.open(file)

    :ok =
      Sqlite3.execute(db, """
      CREATE TABLE pack_meta (pack TEXT, description TEXT);
      INSERT INTO pack_meta VALUES ('#{name}', '#{tag}');
      CREATE TABLE filler (n INTEGER, text TEXT);
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
      INSERT INTO filler SELECT i, '#{tag} row ' || i || ' ' || hex(randomblob(16)) FROM n;
      #{sql}
      """)

    :ok = Sqlite3.close(db)
    raw = File.read!(file)
    File.rm!(file)
    %{raw: raw, zst: IO.iodata_to_binary(:zstd.compress(raw))}
  end

  @doc "A translations pack holding `keys` (its `translations` table)."
  def translations_pack(tag, keys) do
    values = Enum.map_join(keys, ", ", &"('#{&1}')")

    pack(
      "translations",
      tag,
      "CREATE TABLE translations (key TEXT PRIMARY KEY); INSERT INTO translations VALUES #{values};"
    )
  end

  @doc """
  Publishes `packs` (`[{name, pack, required?}]`) as library `version`:
  the files under `/packs/v<version>/` and the manifest.
  """
  def publish(server, base, version, packs) do
    entries =
      for {name, pack, required} <- packs do
        path = "/packs/v#{version}/#{name}.sqlite.zst"
        put_file(server, path, pack.zst)

        %{
          "name" => name,
          "description" => "The #{name} pack",
          "required" => required,
          "licence" => "CC BY 4.0",
          "url" => base <> path,
          "compression" => "zstd",
          "size" => byte_size(pack.zst),
          "sha256" => sha(pack.zst),
          "raw_size" => byte_size(pack.raw),
          "raw_sha256" => sha(pack.raw),
          "tables" => ["pack_meta", "filler"]
        }
      end

    manifest = %{"schema" => 1, "data_version" => version, "packs" => entries}
    put_file(server, "/packs/manifest.json", JSON.encode!(manifest))
    base <> "/packs/manifest.json"
  end

  def put_file(%{agent: agent}, path, body),
    do: Agent.update(agent, &put_in(&1, [:files, path], body))

  @doc "The next response for `path` stops after `bytes` bytes of body and drops the connection."
  def cut(%{agent: agent}, path, bytes),
    do: Agent.update(agent, &put_in(&1, [:cuts, path], bytes))

  def ignore_range(%{agent: agent}), do: Agent.update(agent, &%{&1 | ignore_range: true})

  @doc "`[{path, range header or nil}]`, oldest first."
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()

  def sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # ── Plug ──────────────────────────────────────────────────────────────────

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    path = conn.request_path
    range = conn |> get_req_header("range") |> List.first()

    {body, cut, ignore} =
      Agent.get_and_update(agent, fn s ->
        state = %{s | requests: [{path, range} | s.requests], cuts: Map.delete(s.cuts, path)}
        {{s.files[path], s.cuts[path], s.ignore_range}, state}
      end)

    case {body, range && !ignore && offset(range)} do
      {nil, _} ->
        send_resp(conn, 404, "not found")

      {body, offset} when is_integer(offset) and offset >= byte_size(body) ->
        send_resp(conn, 416, "")

      {body, offset} when is_integer(offset) ->
        size = byte_size(body)

        conn
        |> put_resp_header("content-range", "bytes #{offset}-#{size - 1}/#{size}")
        |> respond(206, binary_part(body, offset, size - offset), cut)

      {body, _} ->
        respond(conn, 200, body, cut)
    end
  end

  defp respond(conn, status, body, nil), do: send_resp(conn, status, body)

  # Sends `bytes` of the body, then the connection dies mid-response, as a
  # dropped network does.
  defp respond(conn, status, body, bytes) do
    conn = send_chunked(conn, status)
    {:ok, _conn} = chunk(conn, binary_part(body, 0, bytes))
    Process.exit(self(), :kill)
  end

  defp offset("bytes=" <> rest) do
    case Integer.parse(rest) do
      {n, "-"} -> n
      _ -> nil
    end
  end

  defp offset(_range), do: nil
end

defmodule Bezalel.Test.Network do
  @moduledoc "The phone's connection for host tests (`config :bezalel, :network_state`)."

  def state,
    do: Application.get_env(:bezalel, :test_network, %{transport: :wifi, expensive: false})
end
