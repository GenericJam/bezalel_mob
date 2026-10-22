defmodule Bezalel.ArtifactsTest do
  use ExUnit.Case, async: false
  alias Bezalel.Link.{Artifacts, Wire}

  test "an artifact becomes readable only after all chunks verify, and rejects a forged digest" do
    uid = Ecto.UUID.generate()
    name = "toolu_123.txt"
    bytes = String.duplicate("tool result\n", 22_000)
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
    folder = Path.join([Rho.Config.data_dir(), "artifacts", uid])
    on_exit(fn -> File.rm_rf(folder) end)

    first = binary_part(bytes, 0, Wire.chunk_size())
    second = binary_part(bytes, Wire.chunk_size(), byte_size(bytes) - Wire.chunk_size())
    base = %{"uid" => uid, "name" => name, "sha" => sha, "total" => byte_size(bytes)}

    assert {:more, stage, next} =
             Artifacts.put(
               Map.merge(
                 base,
                 %{"from" => 0, "bytes" => Wire.b64(first)}
               ),
               nil
             )

    assert next == byte_size(first)
    assert {:ok, []} = Artifacts.list(uid)
    assert {:error, :not_found} = Artifacts.chunk(uid, name, 0)

    assert {:error, :conflict} =
             Artifacts.put(
               Map.merge(
                 base,
                 %{"from" => 2, "bytes" => Wire.b64(second)}
               ),
               stage
             )

    assert {:ok, total} =
             Artifacts.put(
               Map.merge(
                 base,
                 %{"from" => next, "bytes" => Wire.b64(second)}
               ),
               stage
             )

    assert total == byte_size(bytes)
    assert {:ok, [%{"name" => ^name, "sha" => ^sha, "size" => size}]} = Artifacts.list(uid)
    assert size == byte_size(bytes)
    assert {:ok, %{"bytes" => encoded, "from" => 0}} = Artifacts.chunk(uid, name, 0)
    assert {:ok, ^first} = Wire.unb64(encoded)

    bad = Map.put(base, "sha", String.duplicate("0", 64))

    assert {:more, bad_stage, ^next} =
             Artifacts.put(
               Map.merge(
                 bad,
                 %{"from" => 0, "bytes" => Wire.b64(first)}
               ),
               nil
             )

    assert {:error, :id_mismatch} =
             Artifacts.put(
               Map.merge(
                 bad,
                 %{"from" => next, "bytes" => Wire.b64(second)}
               ),
               bad_stage
             )

    assert {:ok, [%{"sha" => ^sha}]} = Artifacts.list(uid)

    assert {:error, :bad_request} =
             Artifacts.put(
               Map.merge(
                 base,
                 %{"name" => "../escape.txt", "from" => 0, "bytes" => ""}
               ),
               nil
             )
  end
end
