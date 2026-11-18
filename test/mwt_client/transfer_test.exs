defmodule MWTClient.TransferTest do
  use ExUnit.Case, async: true

  import MWTClient.VaultHelpers

  alias MWTClient.Accounts
  alias MWTClient.Diagrams.Diagram
  alias MWTClient.Diagrams.Library
  alias MWTClient.HttpClient.Core
  alias MWTClient.HttpClient.HistoryMetadata
  alias MWTClient.HttpClient.Resources
  alias MWTClient.Notes
  alias MWTClient.Transfer
  alias MWTClient.Transfer.Archive
  alias MWTClient.Transfer.FailingParticipant
  alias MWTClient.Transfer.Plan
  alias MWTClient.Vault.Keyring
  alias MWTClient.Vault.Store

  setup do
    identity = unlocked_identity()
    path = Path.join(Accounts.dir(identity.username), "exports/test.mwtexport")
    File.mkdir_p!(Path.dirname(path))
    Map.put(identity, :path, path)
  end

  test "the identity that exported a file opens it with nothing more", %{
    username: username,
    path: path
  } do
    record(username, "https://api.example.test/one")
    assert :ok = Transfer.export(username, path)

    assert {:ok,
            %Plan{
              username: ^username,
              sections: [
                %{summary: "1 request"},
                %{summary: "No diagrams"},
                %{summary: "No notes"},
                %{summary: "No flash cards"}
              ]
            }} = Transfer.read(username, path)
  end

  test "another identity needs the password the file was exported with", %{
    username: username,
    password: password,
    path: path
  } do
    :ok = Transfer.export(username, path)

    # Even the same password: every identity derives its key with its own salt.
    other = also_unlock("someone-else", password)

    assert Transfer.read(other, path) == {:error, :bad_password}
    assert Transfer.read(other, path, password: "wrong horse") == {:error, :bad_password}
    assert {:ok, %Plan{username: ^username}} = Transfer.read(other, path, password: password)
  end

  test "merging brings another identity's history in beside its own", %{
    username: username,
    password: password,
    path: path
  } do
    record(username, "https://api.example.test/one")
    tagged = record(username, "https://api.example.test/two")
    {:ok, _entry} = Core.add_tag(username, tagged, "smoke")
    :ok = Transfer.export(username, path)

    other = also_unlock("someone-else")
    record(other, "https://api.example.test/theirs")

    {:ok, plan} = Transfer.read(other, path, password: password)

    assert [
             %{label: "HTTP request history", summary: "2 requests"},
             %{label: "Diagrams", summary: "No diagrams"},
             %{label: "Notes", summary: "No notes"},
             %{label: "Flash cards", summary: "No flash cards"}
           ] = plan.sections

    assert :ok = Transfer.import(other, plan, :merge)

    assert paths(other) == ["/theirs", "/two", "/one"]
    # Search text is left out of the file and rebuilt on the way back in.
    assert [{_, %HistoryMetadata{tags: ["smoke"]}, _, _}] = Resources.search(other, "smoke")

    # Idempotent: the same file again changes nothing.
    assert :ok = Transfer.import(other, plan, :merge)
    assert paths(other) == ["/theirs", "/two", "/one"]
  end

  test "replacing swaps the history for the file's", %{username: username, path: path} do
    record(username, "https://api.example.test/kept")
    :ok = Transfer.export(username, path)

    old = Enum.map(Resources.all(username), &elem(&1, 0))
    record(username, "https://api.example.test/after-the-export")

    {:ok, plan} = Transfer.read(username, path)
    assert :ok = Transfer.import(username, plan, :replace)

    assert [{identifier, _, %Req.Request{url: %URI{path: "/kept"}}, _}] = Resources.all(username)

    # Fresh identifiers, so nothing held from before resolves to another entry.
    refute identifier in old
    assert record(username, "https://api.example.test/next") > identifier
  end

  test "an imported history survives a lock and unlock", %{
    username: username,
    password: password,
    path: path
  } do
    record(username, "https://api.example.test/one")
    :ok = Transfer.export(username, path)
    :ok = Resources.clear(username)

    {:ok, plan} = Transfer.read(username, path)
    :ok = Transfer.import(username, plan, :merge)
    :ok = Store.close(username)

    {:ok, _profile, key} = Accounts.sign_in(username, password)
    :ok = Store.open(username, key)

    assert paths(username) == ["/one"]
  end

  test "an empty history round trips", %{username: username, path: path} do
    :ok = Transfer.export(username, path)

    assert {:ok,
            %Plan{
              sections: [
                %{summary: "No requests"},
                %{summary: "No diagrams"},
                %{summary: "No notes"},
                %{summary: "No flash cards"}
              ]
            }} = Transfer.read(username, path)
  end

  test "diagrams travel in the same file", %{username: username, password: password, path: path} do
    {:ok, diagram} =
      Library.save(username, Diagram.new_id(), %{
        title: "Checkout",
        elements: [%{"id" => "a", "type" => "rectangle", "text" => "Payment gateway"}]
      })

    :ok = Transfer.export(username, path)

    other = also_unlock("someone-else")
    {:ok, plan} = Transfer.read(other, path, password: password)

    assert [_requests, %{label: "Diagrams", summary: "1 diagram"}, _notes, _cards] =
             plan.sections

    assert :ok = Transfer.import(other, plan, :merge)

    assert {:ok, %{title: "Checkout"}} = Library.get(other, diagram.id)
    assert [%{id: id}] = Library.list(other, "gateway")
    assert id == diagram.id
  end

  test "notes travel in the same file", %{username: username, password: password, path: path} do
    {:ok, note} =
      Notes.Library.save(username, Notes.Note.new_id(), %{
        title: "Release",
        body: "- [ ] Tag the build"
      })

    {:ok, note} = Notes.Library.set_done(username, note.id, true)
    :ok = Transfer.export(username, path)

    other = also_unlock("someone-else")
    {:ok, plan} = Transfer.read(other, path, password: password)
    assert [_requests, _diagrams, %{label: "Notes", summary: "1 note"}, _cards] = plan.sections
    assert :ok = Transfer.import(other, plan, :merge)

    assert {:ok, ^note} = Notes.Library.get(other, note.id)
    assert [%{id: id}] = Notes.Library.list(other, "tag build")
    assert id == note.id
  end

  test "an export MDT made imports, with MWT's names", %{
    username: username,
    password: password,
    path: path
  } do
    {:ok, note} =
      Notes.Library.save(username, Notes.Note.new_id(), %{title: "From MDT", body: "kept"})

    {:ok, diagram} = Library.save(username, Diagram.new_id(), %{title: "Old", elements: []})
    record(username, "https://api.example.test/from-mdt")
    :ok = Transfer.export(username, path)

    # The same contents, as MDT wrote its exports.
    {:ok, contents} = Archive.decode(File.read!(path), {:password, password})
    mdt_path = Path.rootname(path) <> ".mdtexport"
    File.write!(mdt_path, mdt_export(to_mdt(contents), password))

    other = also_unlock("someone-else")
    assert {:ok, plan} = Transfer.read(other, mdt_path, password: password)
    assert :ok = Transfer.import(other, plan, :merge)

    assert {:ok, ^note} = Notes.Library.get(other, note.id)
    assert paths(other) == ["/from-mdt"]
    assert {:ok, %{title: "Old"}} = Library.get(other, diagram.id)
  end

  defp to_mdt(term) when is_atom(term) do
    case Atom.to_string(term) do
      "Elixir.MWTClient" <> rest -> String.to_atom("Elixir.MDTClient" <> rest)
      _ -> term
    end
  end

  defp to_mdt([head | tail]), do: [to_mdt(head) | to_mdt(tail)]

  defp to_mdt(map) when is_map(map),
    do: map |> :maps.to_list() |> Map.new(fn {k, v} -> {to_mdt(k), to_mdt(v)} end)

  defp to_mdt(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&to_mdt/1) |> List.to_tuple()

  defp to_mdt(other), do: other

  defp mdt_export(contents, password) do
    salt = MWTClient.Vault.salt()
    key = MWTClient.Vault.derive(password, salt)
    kdf = Map.put(MWTClient.Vault.kdf_params(), "salt", Base.encode64(salt))
    verifier = Base.encode64(MWTClient.Vault.seal(key, "mdt:export:verifier:v1"))
    header = Jason.encode!(%{"kdf" => kdf, "verifier" => verifier})
    payload = MWTClient.Vault.seal(key, :erlang.term_to_binary(contents, compressed: 6))
    <<"MDTEXPORT", 1, byte_size(header)::32, header::binary, payload::binary>>
  end

  test "reports a missing file, a file that is not an export and a blank password", %{
    username: username,
    path: path
  } do
    assert Transfer.read(username, path <> ".missing") == {:error, {:file, :enoent}}

    File.write!(path, "not an export")
    assert Transfer.read(username, path) == {:error, :not_an_export}
    assert Transfer.read(username, path, password: "") == {:error, :blank_password}
  end

  test "offers a file name that names the identity" do
    date = ~D[2026-09-22]

    assert Transfer.filename("oliveigah", date) == "mwt-export-oliveigah-2026-09-22.mwtexport"
    assert Transfer.filename("ana.silva@acme.io", date) =~ "mwt-export-ana.silva@acme.io-2026"

    assert Transfer.filename("../etc passwd", date) ==
             "mwt-export-..-etc-passwd-2026-09-22.mwtexport"

    assert Transfer.filename("///", date) == "mwt-export-2026-09-22.mwtexport"
  end

  test "a failed export leaves an earlier one where it was", %{username: username, path: path} do
    :ok = Transfer.export(username, path)
    before = File.read!(path)

    assert {:error, {:file, _reason}} =
             Transfer.export(username, Path.join(path, "not-a-folder.mwtexport"))

    assert File.read!(path) == before
    assert path |> Path.dirname() |> File.ls!() == ["test.mwtexport"]
  end

  test "sections no participant recognises are skipped and reported", %{
    username: username,
    path: path
  } do
    record(username, "https://api.example.test/one")
    {:ok, %{entries: entries}} = MWTClient.HttpClient.Transfer.export(username)

    write_archive(username, path, %{
      "http_client.history" => %{version: 1, data: %{entries: entries}},
      "someday.feature" => %{version: 3, data: :whatever}
    })

    assert {:ok, %Plan{skipped: ["someday.feature"], sections: [%{summary: "1 request"}]}} =
             Transfer.read(username, path)
  end

  test "a section newer than this build is refused whole", %{username: username, path: path} do
    write_archive(username, path, %{"http_client.history" => %{version: 2, data: %{entries: []}}})

    assert Transfer.read(username, path) == {:error, {:newer_section, "HTTP request history"}}
  end

  test "a damaged section is refused before anything changes", %{
    username: username,
    path: path
  } do
    record(username, "https://api.example.test/one")

    write_archive(username, path, %{
      "http_client.history" => %{version: 1, data: %{entries: [:junk]}}
    })

    assert {:error, {:invalid_section, "HTTP request history", _reason}} =
             Transfer.read(username, path)

    assert paths(username) == ["/one"]
  end

  for mode <- [:merge, :replace] do
    test "an import that fails partway puts back what it had already written (#{mode})", %{
      username: username,
      path: path
    } do
      participants = [MWTClient.HttpClient.Transfer, FailingParticipant]

      record(username, "https://api.example.test/in-the-file")
      :ok = Transfer.export(username, path, participants: participants)

      :ok = Resources.clear(username)
      record(username, "https://api.example.test/current")

      {:ok, plan} = Transfer.read(username, path, participants: participants)

      assert Transfer.import(username, plan, unquote(mode)) ==
               {:error, {:import_failed, "Failing section", "the disk is full"}}

      assert paths(username) == ["/current"]
    end
  end

  test "a plan keeps the decrypted history out of inspect", %{username: username, path: path} do
    record(username, "https://api.example.test/secret-path")
    :ok = Transfer.export(username, path)
    {:ok, plan} = Transfer.read(username, path)

    refute inspect(plan) =~ "secret-path"
  end

  defp write_archive(username, path, sections) do
    contents = %{
      created_at: DateTime.utc_now(),
      username: username,
      app_version: "0.0.0",
      sections: sections
    }

    archive = Archive.encode(contents, Keyring.kdf(username), &Keyring.seal(username, &1))
    File.write!(path, archive)
  end

  # Newest first, as the history panel lists them.
  defp paths(username) do
    Enum.map(Resources.all(username), fn {_id, _metadata, request, _response} ->
      request.url.path
    end)
  end

  defp record(username, url) do
    Resources.record(
      username,
      HistoryMetadata.new(%{}),
      Req.new(url: url),
      %Req.Response{status: 200, body: "ok"}
    )
  end
end
