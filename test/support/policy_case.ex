defmodule MWTClient.PolicyCase do
  @moduledoc """
  The small world the tests of `MWTClient.Sandbox.Policy` check every
  combination of: the times, each state a grant can be in, the grants and
  requests, every request case, and `kind/1`, an answer without its
  details. Each module that uses this gets them as if written in it, so
  the rules' modules (`MWTClient.Sandbox.PolicyTest` and those beside it)
  run side by side.

  The helpers are public: a module that calls only some of them isn't
  warned about the others.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MWTClient.Sandbox.{Allowance, Describe, Grant, Policy}

      @now ~U[2026-11-13 12:00:00Z]
      @earlier ~U[2026-11-13 11:00:00Z]
      @later ~U[2026-11-13 13:00:00Z]

      @placeholder "mwt_ghp_0123456789abcdef0123456789abcdef"
      @other_placeholder "mwt_hex_fedcba9876543210fedcba9876543210"

      # Every state a grant can be in, with whether it is on at @now.
      @states [
        {:off, nil, false},
        {:off, @later, false},
        {:on, nil, true},
        {:on, @later, true},
        {:on, @earlier, false},
        {:on, @now, false}
      ]

      def snapshot(grants, opts \\ []) do
        %{
          grants: grants,
          own: Keyword.get(opts, :own, [{192, 168, 1, 5}]),
          resolve:
            Keyword.get(opts, :resolve, fn
              "db.internal" -> [{10, 1, 2, 3}]
              "localhost" -> [{127, 0, 0, 1}]
              _other -> []
            end)
        }
      end

      def subsets([]), do: [[]]

      def subsets([first | rest]),
        do:
          for(
            set <- subsets(rest),
            with? <- [false, true],
            do: if(with?, do: [first | set], else: set)
          )

      def allowance(pattern, until),
        do: %Allowance{
          id: "allowance-#{:erlang.phash2({pattern, until})}",
          pattern: pattern,
          until: until
        }

      # Whether some allowance of `allowances` covers `pattern` at `now`, said
      # again here in the plainest way.
      def covered?(allowances, pattern, now) do
        Enum.any?(allowances, fn %Allowance{pattern: covers, until: until} ->
          (covers == :all or covers == pattern) and
            (is_nil(until) or DateTime.compare(now, until) == :lt)
        end)
      end

      def kind(:pass), do: :pass
      def kind({:allow, _grant, _allowance, _about}), do: :allow
      def kind({:ask, _grant, _about}), do: :ask
      def kind({:refuse, reason}) when is_tuple(reason), do: {:refuse, elem(reason, 0)}
      def kind({:refuse, reason}), do: {:refuse, reason}

      ## Requests

      @listed [["api.example.com"], ["*.example.com"], ["API.Example.com"]]
      @hosts ~w(api.example.com example.com deep.api.example.com API.EXAMPLE.COM evil.test example.com.evil.test notexample.com)
      @carriers [:none, :bearer, :basic, :other_header, :two]
      @calls [{"GET", "/repos/a/b"}, {"POST", "/graphql"}]

      def token_grant(state, expires_at, hosts, allowances) do
        %Grant{
          id: "github",
          name: "GitHub",
          kind: :token,
          state: state,
          expires_at: expires_at,
          placeholder: @placeholder,
          hosts: hosts,
          allowances: allowances
        }
      end

      def other_token_grant do
        %Grant{
          id: "hex",
          name: "Hex",
          kind: :token,
          state: :on,
          placeholder: @other_placeholder,
          hosts: ["hex.pm", "*.example.com"],
          allowances: [allowance(:all, nil)]
        }
      end

      def request(host, {method, path}, carrier) do
        headers =
          case carrier do
            :none ->
              [{"accept", "*/*"}]

            :bearer ->
              [{"authorization", "Bearer " <> @placeholder}]

            :basic ->
              [{"authorization", "Basic " <> Base.encode64("git:" <> @placeholder)}]

            :other_header ->
              [{"x-api-key", @placeholder}]

            :two ->
              [{"authorization", "Bearer " <> @placeholder}, {"x-other", @other_placeholder}]
          end

        body = if path == "/graphql", do: ~s({"query":"query { viewer { login } }"}), else: ""
        %{host: host, method: method, path: path, headers: headers, body: body}
      end

      def host_listed?(host, hosts) do
        host = String.downcase(host)

        Enum.any?(hosts, fn entry ->
          entry = String.downcase(entry)

          case entry do
            "*." <> suffix -> host == suffix or String.ends_with?(host, "." <> suffix)
            exact -> host == exact
          end
        end)
      end

      # Every request the world holds, with the grant it meets.
      def request_cases do
        for {state, expires_at, on?} <- @states,
            hosts <- @listed,
            host <- @hosts,
            call <- @calls,
            carrier <- @carriers do
          request = request(host, call, carrier)
          # Allow similar goes by the carrier too; the grant's is authorization.
          pattern = request |> Describe.request() |> Describe.carried_in("authorization")
          pattern = pattern.pattern

          allowance_sets =
            subsets([
              allowance(:all, nil),
              allowance(:all, @earlier),
              allowance(pattern, @later),
              allowance(pattern, @earlier),
              allowance("GET api.example.com/something/else", nil)
            ])

          for allowances <- allowance_sets do
            %{
              grant: token_grant(state, expires_at, hosts, allowances),
              on?: on?,
              listed?: host_listed?(host, hosts),
              # The other grant's placeholder rides along in :two.
              both_listed?:
                host_listed?(host, hosts) and host_listed?(host, other_token_grant().hosts),
              carrier: carrier,
              request: request,
              pattern: pattern
            }
          end
        end
        |> List.flatten()
      end

      def decide_request(one, now \\ @now, more \\ []) do
        Policy.decide(
          snapshot([one.grant, other_token_grant() | more]),
          {:request, one.request},
          now
        )
      end
    end
  end
end
