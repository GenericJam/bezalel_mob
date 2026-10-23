defmodule Bezalel.Packs.Manifest do
  @moduledoc """
  The published pack manifest (`data/README.md`, "Publish"; schema 1):
  `data_version` and one entry per pack with its download (`url`, `size`,
  `sha256`, zstd) and the SQLite file it decompresses to (`raw_size`,
  `raw_sha256`).

  Only the packs `Bezalel.Study.DB` reads are kept (a newer manifest may
  list packs this app doesn't know); their names become file names, so
  nothing else from the manifest reaches a path.
  """

  # The translations pack holds the NET Bible, the JPS 1917 and the adapted
  # ULT and UST (bezalel_core's `Bezalel.Study.Translations`), listed next
  # to core; every pack after core is optional. The witnesses pack (the
  # Samaritan Pentateuch, the SBLGNT and its apparatus, the HOTTP) sits
  # with the LXX it is compared with; the scrolls pack (the Dead Sea
  # Scrolls' non-biblical works and the biblical manuscripts' readings)
  # follows the ancient sources it extends, and the Apostolic Fathers after
  # them. Then the UBS dictionaries, MACULA's clause structure (syntax) and
  # people and places (graph).
  @known ~w(core translations notes lxx witnesses ancient scrolls fathers dictionaries syntax graph)

  @type entry :: %{
          name: String.t(),
          description: String.t(),
          required: boolean(),
          licence: String.t(),
          url: String.t(),
          size: pos_integer(),
          sha256: String.t(),
          raw_size: pos_integer(),
          raw_sha256: String.t()
        }

  @type t :: %{data_version: pos_integer(), sources: String.t() | nil, packs: [entry()]}

  @doc "The pack names this app installs, in the order Settings lists them."
  @spec known() :: [String.t()]
  def known, do: @known

  @doc "Parses and checks a manifest's JSON."
  @spec parse(binary()) :: {:ok, t()} | {:error, String.t()}
  def parse(json) do
    with {:ok, %{"schema" => 1, "data_version" => version, "packs" => packs} = map}
         when is_integer(version) and version > 0 and is_list(packs) <- decode(json),
         {:ok, entries} <- entries(packs) do
      {:ok, %{data_version: version, sources: map["sources"], packs: entries}}
    else
      {:ok, %{"schema" => schema}} when schema != 1 ->
        {:error, "the library uses a newer format (schema #{inspect(schema)}); update Bezalel"}

      {:error, _} = error ->
        error

      _ ->
        {:error, "the library's manifest isn't valid"}
    end
  end

  @doc "The entry for `name`, or nil."
  @spec entry(t() | nil, String.t()) :: entry() | nil
  def entry(nil, _name), do: nil
  def entry(manifest, name), do: Enum.find(manifest.packs, &(&1.name == name))

  defp decode(json) do
    case JSON.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, "the library's manifest isn't valid JSON"}
    end
  end

  defp entries(packs) do
    entries = for %{"name" => name} = pack <- packs, name in @known, do: entry(pack)

    if Enum.all?(entries, &match?(%{}, &1)) and entries != [],
      do: {:ok, Enum.sort_by(entries, &Enum.find_index(@known, fn n -> n == &1.name end))},
      else: {:error, "the library's manifest isn't valid"}
  end

  defp entry(
         %{
           "name" => name,
           "url" => url,
           "compression" => "zstd",
           "size" => size,
           "sha256" => sha,
           "raw_size" => raw_size,
           "raw_sha256" => raw_sha
         } = pack
       )
       when is_binary(url) and is_integer(size) and size > 0 and is_integer(raw_size) and
              raw_size > 0 do
    with true <- sha256?(sha) and sha256?(raw_sha),
         %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) <-
           URI.parse(url) do
      %{
        name: name,
        description: string(pack["description"]),
        required: pack["required"] == true,
        licence: string(pack["licence"]),
        url: url,
        size: size,
        sha256: String.downcase(sha),
        raw_size: raw_size,
        raw_sha256: String.downcase(raw_sha)
      }
    else
      _ -> nil
    end
  end

  defp entry(_pack), do: nil

  defp sha256?(hex),
    do:
      is_binary(hex) and byte_size(hex) == 64 and
        match?({:ok, _}, Base.decode16(hex, case: :mixed))

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: ""
end
