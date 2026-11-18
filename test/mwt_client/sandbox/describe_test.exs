defmodule MWTClient.Sandbox.DescribeTest do
  use ExUnit.Case, async: true

  alias MWTClient.Sandbox.Describe

  defp pkt(line),
    do: ((byte_size(line) + 4) |> Integer.to_string(16) |> String.pad_leading(4, "0")) <> line

  defp request(attrs) do
    Map.merge(%{host: "github.com", method: "GET", path: "/", headers: [], body: ""}, attrs)
  end

  test "a push names its repository and ref updates, from the start of the pack" do
    zero = String.duplicate("0", 40)
    new = "8bd04e2" <> String.duplicate("a", 33)
    body = pkt("#{zero} #{new} refs/heads/fix\0report-status\n") <> "0000PACK..."

    described =
      Describe.request(
        request(%{
          method: "POST",
          path: "/oliveigah/klife.git/git-receive-pack",
          headers: [{"user-agent", "git/2.39.5"}, {"content-length", "#{byte_size(body)}"}],
          body: body
        })
      )

    assert described.title == "Push fix to oliveigah/klife"
    assert {"Ref", "refs/heads/fix  new at 8bd04e2"} in described.facts
    assert {"Client", "git/2.39.5"} in described.facts
    assert described.pattern == "POST github.com/oliveigah/klife.git/git-receive-pack"
  end

  describe "a push's refs are read from the body as the host reads it" do
    @old String.duplicate("a", 40)
    @new String.duplicate("b", 40)

    defp push(headers, body) do
      Describe.request(
        request(%{
          method: "POST",
          path: "/o/r.git/git-receive-pack",
          headers: headers,
          body: body
        })
      )
    end

    defp chunked(body), do: push([{"transfer-encoding", "chunked"}], body)
    defp refs(described), do: for({"Ref", ref} <- described.facts, do: ref)

    # One ref update to refs/heads/main, then the pack: what git sends.
    defp stream,
      do: pkt("#{@old} #{@new} refs/heads/main\0 report-status side-band-64k\n") <> "0000PACK"

    test "sent chunked, as git sends a push over 1 MiB, the card shows its refs" do
      size = Integer.to_string(byte_size(stream()), 16)
      described = chunked(size <> "\r\n" <> stream() <> "\r\n0\r\n\r\n")

      assert described.title == "Push main to o/r"
      assert refs(described) == ["refs/heads/main  aaaaaaa → bbbbbbb"]

      # Split across chunks, a pkt-line is read whole.
      {a, b} = String.split_at(stream(), 30)

      split =
        Enum.map_join([a, b], fn part ->
          Integer.to_string(byte_size(part), 16) <> "\r\n" <> part <> "\r\n"
        end) <> "0\r\n\r\n"

      assert refs(chunked(split)) == ["refs/heads/main  aaaaaaa → bbbbbbb"]
    end

    test "a chunk extension can't pass for a ref update (QA M11)" do
      # A size line padded to four hex digits, with an extension that reads
      # as a pkt-line updating another branch.
      ext = ~s(;x="#{String.duplicate("0", 40)} #{String.duplicate("1", 40)} refs/heads/feature")
      size = byte_size(stream()) |> Integer.to_string(16) |> String.pad_leading(4, "0")
      described = chunked(size <> ext <> "\r\n" <> stream() <> "\r\n0\r\n\r\n")

      assert refs(described) == ["refs/heads/main  aaaaaaa → bbbbbbb"]
      refute Enum.any?(described.facts, fn {_label, value} -> value =~ "feature" end)
      refute described.title =~ "feature"
    end

    test "framing a host could read another way shows no refs, and says so" do
      for body <- [
            "-5\r\n" <> stream() <> "\r\n0\r\n\r\n",
            Integer.to_string(byte_size(stream()), 16) <> "\n" <> stream() <> "\r\n0\r\n\r\n",
            Integer.to_string(byte_size(stream()) - 2, 16) <>
              "\r\n" <> stream() <> "\r\n0\r\n\r\n"
          ] do
        described = chunked(body)
        assert described.title == "Push to o/r, refs not read", inspect(body)
        assert refs(described) == []
        assert {"Refs not read", _why} = List.keyfind(described.facts, "Refs not read", 0)
      end

      gzip = push([{"content-encoding", "gzip"}, {"content-length", "8"}], :zlib.gzip(stream()))
      assert gzip.title == "Push to o/r, refs not read"
      assert {"Refs not read", "the body is gzip-encoded"} in gzip.facts
    end

    test "bytes after Content-Length are the next request, not this push's refs" do
      flush = "0000"
      next = pkt("#{@old} #{@new} refs/heads/main\n") <> "0000"
      described = push([{"content-length", "4"}], flush <> next)

      assert described.title == "Push to o/r, no ref updates"
      assert refs(described) == []
    end

    test "a ref list longer than MWT holds says that some aren't shown" do
      lines = for n <- 1..3, do: pkt("#{@old} #{@new} refs/heads/b#{n}\n")
      held = Enum.join(lines) <> binary_part(pkt("#{@old} #{@new} refs/heads/b4\n"), 0, 20)
      described = push([{"content-length", "100000"}], held)

      assert described.title == "Push 3+ refs to o/r"
      assert length(refs(described)) == 3
      assert {"Refs not read", "more than MWT holds: only the first 3 shown"} in described.facts
    end
  end

  test "GraphQL mutations and queries are told apart, and the agent's text is a claim" do
    mutation =
      Jason.encode!(%{
        query:
          "mutation CreatePR($input: CreatePullRequestInput!) { createPullRequest(input: $input) { pullRequest { url } } }",
        variables: %{input: %{title: "Fix the stall", body: "Retries per partition."}}
      })

    described =
      Describe.request(
        request(%{host: "api.github.com", method: "POST", path: "/graphql", body: mutation})
      )

    assert {"Operation", "mutation CreatePR"} in described.facts
    assert {"Title", "Fix the stall"} in described.claims
    refute Enum.any?(described.facts, fn {_, value} -> value == "Fix the stall" end)

    query = Jason.encode!(%{query: "{ viewer { login } }"})

    assert %{title: "GraphQL query viewer on github.com"} =
             Describe.request(request(%{method: "POST", path: "/graphql", body: query}))
  end

  test "REST requests name their endpoint, and similar ones share a pattern" do
    assert %{facts: [{"Endpoint", "GET /repos/o/r/pulls"}]} =
             Describe.request(request(%{path: "/repos/o/r/pulls?state=open"}))

    assert %{pattern: "DELETE api.github.com/repos/o/r"} =
             Describe.request(
               request(%{host: "api.github.com", method: "DELETE", path: "/repos/o/r"})
             )
  end
end
