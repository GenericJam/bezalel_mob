defmodule Bezalel.MaterialStore do
  @moduledoc """
  Where the phone keeps materials (bezalel_core's `Bezalel.Materials`): the
  photos, recordings, videos and files sent to the agent, the drawings it
  made, and what Bezalel made from them (transcripts, stills). bezalel_core
  reaches it as its `Bezalel.Materials.Store` (`config :bezalel_core,
  :materials`), rho through `Bezalel.Materials.resolve/2` (`config :rho,
  :resolve_attachment`).

  The bytes are files under `materials` in the app support directory
  (`Bezalel.Materials.relative_path/1`: `ab/<sha256>.<ext>`), **backed up**
  with the phone (they are the user's own, unlike the study packs); the
  records are rows of the `materials` table, and `material_links` says
  which conversations (rho session ids) each went with or came from.

  One user owns everything on the phone, so every ctx is that user's: a
  ctx's `:session_id` (nil from the Materials tab) only links a material
  to the conversation it was put with. `put/3` of bytes already kept keeps
  `Bezalel.Materials.merge/2` of the two, as the behaviour asks.

  Models get pictures through `for_model/2`: a photo larger than providers
  take (`@model_px` on its longest side, `@model_bytes`) is sent as a
  downscaled JPEG, made once by the platform (`Bezalel.Native.thumbnail/2`,
  mob_photos; HEIC included) and cached under the cache directory (not
  backed up: it is made again when missing).
  """
  @behaviour Bezalel.Materials.Store

  import Ecto.Query

  alias Bezalel.Images.Codec
  alias Bezalel.Link.Wire
  alias Bezalel.Materials
  alias Bezalel.Materials.Material
  alias Bezalel.{Native, Repo}

  require Logger

  # Anthropic downscales anything longer than 1568 px and refuses images over
  # 5 MB (base64 grows bytes by a third): what every provider takes.
  @model_px 1568
  @model_bytes 3_750_000
  @model_images ["image/jpeg", "image/png", "image/webp"]

  defmodule Row do
    @moduledoc "A material's record (`Bezalel.Materials.Material`) as a row."
    use Ecto.Schema

    @primary_key {:id, :string, autogenerate: false}
    schema "materials" do
      field :kind, :string
      field :mime, :string
      field :name, :string
      field :size, :integer
      field :source, :string
      field :derivation, :string
      field :derived_from, {:array, :string}, default: []
      field :meta, :map, default: %{}
      field :inserted_at, :utc_datetime
    end
  end

  defmodule Link do
    @moduledoc "A material and a conversation (rho session id) it went with or came from."
    use Ecto.Schema

    @primary_key false
    schema "material_links" do
      field :material_id, :string
      field :session_id, :string
      field :inserted_at, :utc_datetime
    end
  end

  # ── Where ────────────────────────────────────────────────────────────────

  @doc """
  The materials directory: `config :bezalel, :materials_dir` when set
  (tests), else `materials` under the app support directory
  (`Bezalel.Packs.Storage.root/0`).
  """
  @spec dir() :: Path.t()
  def dir do
    Application.get_env(:bezalel, :materials_dir) ||
      Path.join(Bezalel.Packs.Storage.root(), "materials")
  end

  @doc """
  What's made from materials and can be made again (the models' copies of
  pictures, `for_model/2`; the chat's and the tab's thumbnails,
  `Bezalel.Images`): `config :bezalel, :materials_cache_dir`, else
  `materials` under the cache directory (not backed up).
  """
  @spec cache_dir() :: Path.t()
  def cache_dir do
    Application.get_env(:bezalel, :materials_cache_dir) ||
      :persistent_term.get({__MODULE__, :cache_dir}, nil) ||
      resolve_cache_dir()
  end

  # Resolved once per run: on Android the resolution needs the activity,
  # which a model call made while the app is in the background may not have
  # (as `Bezalel.Packs.Storage.root/0`).
  defp resolve_cache_dir do
    dir = Path.join(Mob.Storage.dir(:cache), "materials")
    :persistent_term.put({__MODULE__, :cache_dir}, dir)
    dir
  end

  @doc "A material's file on the phone."
  @spec path(Material.t()) :: Path.t()
  def path(%Material{} = m), do: Materials.path(dir(), m)

  @doc """
  The file of the material `id` of media type `mime` (what a message's
  materials list says), without reading its record.
  """
  @spec file(String.t(), String.t()) :: Path.t()
  def file(id, mime),
    do: Path.join([dir(), String.slice(id, 0, 2), "#{id}.#{Materials.extension(mime || "")}"])

  # ── Bezalel.Materials.Store ──────────────────────────────────────────────

  @impl true
  def put(%Material{} = material, bytes, ctx) when is_binary(bytes) do
    with {:ok, _path} <- Materials.write_file(dir(), material, bytes) do
      kept =
        case Repo.get(Row, material.id) do
          nil -> material
          row -> Materials.merge(to_material(row), material)
        end

      Repo.insert!(to_row(kept),
        on_conflict: {:replace, [:derived_from, :derivation]},
        conflict_target: :id
      )

      link(kept.id, ctx[:session_id])
      {:ok, kept}
    end
  end

  @doc "Imports a verified staged upload without loading its bytes into the BEAM."
  def put_file(%Material{} = material, source, ctx) do
    dest = path(material)

    with {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(source),
         true <- size == material.size,
         {:ok, digest} <- file_digest(source),
         true <- digest == material.id,
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- install_file(source, dest, material.id) do
      kept =
        case Repo.get(Row, material.id) do
          nil -> material
          row -> Materials.merge(to_material(row), material)
        end

      Repo.insert!(to_row(kept),
        on_conflict: {:replace, [:derived_from, :derivation]},
        conflict_target: :id
      )

      link(kept.id, ctx[:session_id])
      {:ok, kept}
    else
      _ -> {:error, :id_mismatch}
    end
  end

  defp install_file(source, dest, id) do
    case File.lstat(dest) do
      {:ok, %File.Stat{type: :regular}} ->
        case file_digest(dest) do
          {:ok, ^id} -> :ok
          _ -> {:error, :id_mismatch}
        end

      {:error, :enoent} ->
        File.rename(source, dest)

      _ ->
        {:error, :id_mismatch}
    end
  end

  defp file_digest(path) do
    case File.open(path, [:read, :raw, :binary]) do
      {:ok, io} ->
        try do
          digest_chunks(io, :crypto.hash_init(:sha256))
        after
          File.close(io)
        end

      error ->
        error
    end
  end

  defp digest_chunks(io, state) do
    case :file.read(io, 262_144) do
      {:ok, bytes} -> digest_chunks(io, :crypto.hash_update(state, bytes))
      :eof -> {:ok, Base.encode16(:crypto.hash_final(state), case: :lower)}
      {:error, _} = error -> error
    end
  end

  @impl true
  def fetch(id, _ctx) when is_binary(id) do
    case Repo.get(Row, id) do
      nil -> :error
      row -> {:ok, to_material(row)}
    end
  end

  def fetch(_id, _ctx), do: :error

  @impl true
  def read(%Material{id: id} = m, _ctx) do
    if Repo.exists?(from(r in Row, where: r.id == ^id)),
      do: File.read(path(m)),
      else: {:error, :not_found}
  end

  @doc "Reads one bounded chunk of a stored material, refusing symlinks in its path."
  @spec read_chunk(Material.t(), non_neg_integer(), map()) ::
          {:ok, binary(), boolean()} | {:error, :not_found | :bad_request | :read_failed}
  def read_chunk(%Material{} = material, from, _ctx)
      when is_integer(from) and from >= 0 do
    file = path(material)
    folder = Path.dirname(file)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(dir()),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(folder),
         {:ok, %File.Stat{type: :regular} = before} <- File.lstat(file),
         true <- before.size == material.size,
         {:ok, io} <- File.open(file, [:read, :raw, :binary]) do
      try do
        with {:ok, record} <- :file.read_file_info(io),
             %File.Stat{type: :regular} = opened <- File.Stat.from_record(record),
             true <- same_file?(before, opened) and from <= opened.size,
             {:ok, ^from} <- :file.position(io, from),
             {:ok, bytes} <- material_chunk(:file.read(io, Wire.chunk_size())) do
          {:ok, bytes, from + byte_size(bytes) == opened.size}
        else
          false -> {:error, :bad_request}
          _ -> {:error, :read_failed}
        end
      after
        File.close(io)
      end
    else
      {:error, :enoent} -> {:error, :not_found}
      {:ok, _} -> {:error, :not_found}
      false -> {:error, :read_failed}
      _ -> {:error, :read_failed}
    end
  end

  def read_chunk(%Material{}, _from, _ctx), do: {:error, :bad_request}

  defp material_chunk({:ok, bytes}), do: {:ok, bytes}
  defp material_chunk(:eof), do: {:ok, ""}
  defp material_chunk(_), do: {:error, :read_failed}

  defp same_file?(first, second),
    do:
      first.inode == second.inode and first.major_device == second.major_device and
        first.minor_device == second.minor_device and first.size == second.size

  @impl true
  def derivatives(id, _ctx) do
    from(r in Row,
      where: fragment("EXISTS (SELECT 1 FROM json_each(?) WHERE value = ?)", r.derived_from, ^id),
      order_by: [asc: r.inserted_at, asc: r.id]
    )
    |> Repo.all()
    |> Enum.map(&to_material/1)
  end

  @impl true
  def for_model(%Material{kind: :image} = m, ctx) do
    cached = Path.join([cache_dir(), "model", m.id <> ".jpg"])

    case File.read(cached) do
      {:ok, bytes} -> {:ok, {"image/jpeg", bytes}}
      {:error, _} -> with({:ok, bytes} <- read(m, ctx), do: model_picture(m, bytes, cached))
    end
  end

  def for_model(%Material{} = m, ctx) do
    with {:ok, bytes} <- read(m, ctx), do: {:ok, {m.mime, bytes}}
  end

  # A picture providers take as it is goes as it is; a larger one (or a
  # HEIC) as the platform's downscaled JPEG, kept for the next request (rho
  # resolves every picture of the conversation for each call); without the
  # platform's (the host), a PNG thumbnail.
  defp model_picture(m, bytes, cached) do
    if fits?(m, bytes) do
      {:ok, {m.mime, bytes}}
    else
      case Native.thumbnail(path(m), max_size: @model_px, quality: 85) do
        {:ok, %{path: thumb}} ->
          copy = File.read!(thumb)
          File.rm(thumb)
          File.mkdir_p!(Path.dirname(cached))
          File.write!(cached, copy)
          {:ok, {"image/jpeg", copy}}

        {:error, reason} ->
          Logger.info("[materials] no platform thumbnail for #{m.id}: #{inspect(reason)}")
          codec_picture(bytes)
      end
    end
  end

  defp fits?(m, bytes) do
    m.mime in @model_images and byte_size(bytes) <= @model_bytes and
      match?(
        {:ok, %{width: w, height: h}} when w <= @model_px and h <= @model_px,
        Codec.info(bytes)
      )
  end

  defp codec_picture(bytes) do
    case Codec.thumbnail(bytes, @model_px, @model_px) do
      {:ok, %{data: data, mime: mime}} when byte_size(data) <= @model_bytes -> {:ok, {mime, data}}
      {:ok, _too_big} -> {:error, :too_large}
      {:original, _dims} when byte_size(bytes) <= @model_bytes -> {:ok, {mime_of(bytes), bytes}}
      {:original, _dims} -> {:error, :too_large}
      {:error, _} = error -> error
    end
  end

  defp mime_of(bytes) do
    case Codec.info(bytes) do
      {:ok, %{format: :png}} -> "image/png"
      {:ok, %{format: :webp}} -> "image/webp"
      _ -> "image/jpeg"
    end
  end

  # ── The app's own ────────────────────────────────────────────────────────

  @doc """
  The materials the Materials tab shows, newest first: what was sent and
  what the agent drew (derivatives show with what they came from).
  `opts`: `:kind` (one kind, or nil for all), `:session_id` (only those of
  that conversation), `:limit`, `:offset`.
  """
  @spec list(keyword()) :: [Material.t()]
  def list(opts \\ []) do
    from(r in Row,
      where: is_nil(r.derivation) or r.derivation == "generated",
      order_by: [desc: r.inserted_at, desc: r.id]
    )
    |> by_kind(opts[:kind])
    |> by_session(opts[:session_id])
    |> limit(^Keyword.get(opts, :limit, -1))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
    |> Enum.map(&to_material/1)
  end

  @doc "Forgets that any material went with the conversation of `session_id` (it was deleted)."
  @spec unlink_session(String.t()) :: :ok
  def unlink_session(session_id) do
    Repo.delete_all(from(l in Link, where: l.session_id == ^session_id))
    :ok
  end

  @doc "How many materials the tab shows (`list/1`'s)."
  @spec count() :: non_neg_integer()
  def count do
    Repo.aggregate(
      from(r in Row, where: is_nil(r.derivation) or r.derivation == "generated"),
      :count
    )
  end

  defp by_kind(query, nil), do: query
  defp by_kind(query, kind), do: where(query, [r], r.kind == ^Atom.to_string(kind))

  defp by_session(query, nil), do: query

  defp by_session(query, session_id) do
    where(
      query,
      [r],
      r.id in subquery(from(l in Link, where: l.session_id == ^session_id, select: l.material_id))
    )
  end

  @doc "The rho session ids of the conversations `id` went with or came from, first first."
  @spec sessions(String.t()) :: [String.t()]
  def sessions(id) do
    Repo.all(
      from(l in Link,
        where: l.material_id == ^id,
        order_by: [asc: l.inserted_at],
        select: l.session_id
      )
    )
  end

  @doc "Records that material `id` went with the conversation of `session_id` (nil: none)."
  @spec link(String.t(), String.t() | nil) :: :ok
  def link(_id, nil), do: :ok

  def link(id, session_id) do
    Repo.insert_all(
      Link,
      [%{material_id: id, session_id: session_id, inserted_at: now()}],
      on_conflict: :nothing
    )

    :ok
  end

  @doc """
  Deletes a material, its file, and what was made from it alone (its
  transcripts, audio tracks and stills; a drawing from it as a reference
  stays, as the agent's own). A conversation that sent it says, from then
  on, that it couldn't be loaded.
  """
  @spec delete(String.t()) :: :ok
  def delete(id) do
    case fetch(id, %{}) do
      :error ->
        :ok

      {:ok, m} ->
        made =
          for d <- derivatives(id, %{}),
              d.derivation in [:transcript, :audio_track, :still],
              d.derived_from == [id],
              do: d

        Enum.each(made, &delete(&1.id))
        File.rm(path(m))
        File.rm(Path.join([cache_dir(), "model", id <> ".jpg"]))
        for file <- Path.wildcard(Path.join([cache_dir(), "chat", id <> "-*"])), do: File.rm(file)
        Repo.delete_all(from(r in Row, where: r.id == ^id))
        :ok
    end
  end

  defp to_row(%Material{} = m) do
    map = Materials.to_map(m)

    %Row{
      id: m.id,
      kind: map["kind"],
      mime: m.mime,
      name: m.name,
      size: m.size,
      source: map["source"],
      derivation: map["derivation"],
      derived_from: m.derived_from,
      meta: map["meta"],
      inserted_at: DateTime.truncate(m.inserted_at, :second)
    }
  end

  defp to_material(%Row{} = r) do
    Materials.from_map(%{
      "id" => r.id,
      "kind" => r.kind,
      "mime" => r.mime,
      "name" => r.name,
      "size" => r.size,
      "source" => r.source,
      "derivation" => r.derivation,
      "derived_from" => r.derived_from,
      "meta" => r.meta,
      "inserted_at" => DateTime.to_iso8601(r.inserted_at)
    })
  end

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
