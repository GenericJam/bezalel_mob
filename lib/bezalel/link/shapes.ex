defmodule Bezalel.Link.Shapes do
  @moduledoc """
  The fixed shapes a linked computer's names must have before the phone
  makes a path or a query of them: a session uid, a SHA-256, a session
  file name, an artifact name. Checked byte by byte, not with a regex: a
  `~r` compiled into a module is tied to the OTP that compiled it, and
  the phone runs another (AGENTS.md, pre-empt rule 1).
  """

  @doc "A session uid: a lowercase UUID (`8-4-4-4-12` hex digits)."
  @spec uid?(term()) :: boolean()
  def uid?(<<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>>),
    do: hex?(a) and hex?(b) and hex?(c) and hex?(d) and hex?(e)

  def uid?(_value), do: false

  @doc "A SHA-256 as 64 lowercase hex digits."
  @spec sha?(term()) :: boolean()
  def sha?(sha) when is_binary(sha) and byte_size(sha) == 64, do: hex?(sha)
  def sha?(_value), do: false

  @doc """
  rho's session file name for `uid`: `<stamp>_<uid>.jsonl`, the stamp one
  or more of `A-Z a-z 0-9 _ -`.
  """
  @spec session_file?(term(), term()) :: boolean()
  def session_file?(file, uid) when is_binary(file) do
    suffix = "_#{uid}.jsonl"
    stem = byte_size(file) - byte_size(suffix)

    uid?(uid) and stem > 0 and binary_part(file, stem, byte_size(suffix)) == suffix and
      every?(binary_part(file, 0, stem), &(word?(&1) or &1 == ?-))
  end

  def session_file?(_file, _uid), do: false

  @doc """
  rho's artifact name (`<call id>.txt`): a letter, digit or `_`, then at
  most 127 of those, `.` and `-`, then `.txt`.
  """
  @spec artifact?(term()) :: boolean()
  def artifact?(name) when is_binary(name) and byte_size(name) in 5..132 do
    stem = binary_part(name, 0, byte_size(name) - 4)
    <<first, rest::binary>> = stem

    binary_part(name, byte_size(stem), 4) == ".txt" and word?(first) and
      every?(rest, &(word?(&1) or &1 in [?., ?-]))
  end

  def artifact?(_name), do: false

  defp hex?(bytes), do: every?(bytes, &(&1 in ?0..?9 or &1 in ?a..?f))

  defp word?(c), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_

  defp every?(<<>>, _ok?), do: true
  defp every?(<<c, rest::binary>>, ok?), do: ok?.(c) and every?(rest, ok?)
end
