defmodule MWTClient.Transfer.ArchiveTest do
  use ExUnit.Case, async: true

  alias MWTClient.Transfer.Archive
  alias MWTClient.Vault

  @password "correct horse"
  @contents %{
    created_at: ~U[2026-09-22 10:00:00Z],
    sections: %{"notes" => %{version: 1, data: ["https://api.example.test/health"]}}
  }

  setup do
    salt = Vault.salt()
    key = Vault.derive(@password, salt)
    kdf = Map.put(Vault.kdf_params(), "salt", Base.encode64(salt))

    %{key: key, archive: Archive.encode(@contents, kdf, &Vault.seal(key, &1))}
  end

  test "opens with the key it was sealed under", %{key: key, archive: archive} do
    assert Archive.decode(archive, {:open, &Vault.open(key, &1)}) == {:ok, @contents}
  end

  test "opens with the password that key derives from", %{archive: archive} do
    assert Archive.decode(archive, {:password, @password}) == {:ok, @contents}
  end

  test "any other key or password is reported as the wrong one", %{archive: archive} do
    other = Vault.derive(@password, Vault.salt())

    assert Archive.decode(archive, {:open, &Vault.open(other, &1)}) == {:error, :bad_password}
    assert Archive.decode(archive, {:password, "wrong horse"}) == {:error, :bad_password}
  end

  describe "an export MDT made" do
    setup %{key: key} do
      kdf = Map.put(Vault.kdf_params(), "salt", Base.encode64(Vault.salt()))

      header =
        Jason.encode!(%{
          "kdf" => kdf,
          "verifier" => Base.encode64(Vault.seal(key, "mdt:export:verifier:v1"))
        })

      contents = %{
        sections: %{
          "cards" => [
            %{
              __struct__: :"Elixir.MDTClient.Flashcards.Card",
              id: "c1",
              kind: :mdt,
              text: "MDTClient"
            }
          ]
        }
      }

      payload = Vault.seal(key, :erlang.term_to_binary(contents))
      %{mdt: <<"MDTEXPORT", 1, byte_size(header)::32, header::binary, payload::binary>>}
    end

    test "opens with MWT's names", %{key: key, mdt: mdt} do
      assert {:ok, %{sections: %{"cards" => [card]}}} =
               Archive.decode(mdt, {:open, &Vault.open(key, &1)})

      assert card == %{
               __struct__: MWTClient.Flashcards.Card,
               id: "c1",
               kind: :mwt,
               text: "MDTClient"
             }
    end

    test "still tells a wrong password and a newer format apart", %{mdt: mdt} do
      assert Archive.decode(mdt, {:open, &Vault.open(Vault.derive(@password, Vault.salt()), &1)}) ==
               {:error, :bad_password}

      <<"MDTEXPORT", 1, rest::binary>> = mdt

      assert Archive.decode(<<"MDTEXPORT", 2, rest::binary>>, {:password, @password}) ==
               {:error, :unsupported_version}
    end

    test "is only MDT's: MWT's header with MDT's verifier is refused", %{key: key, mdt: mdt} do
      <<"MDTEXPORT", rest::binary>> = mdt

      assert Archive.decode(<<"MWTEXPORT", rest::binary>>, {:open, &Vault.open(key, &1)}) ==
               {:error, :bad_password}
    end
  end

  test "the file carries no plaintext", %{archive: archive} do
    refute String.contains?(archive, "api.example.test")
    refute String.contains?(archive, "notes")
  end

  test "a tampered payload is reported as damaged, not as a wrong password", %{
    key: key,
    archive: archive
  } do
    last = byte_size(archive) - 1
    <<head::binary-size(^last), byte>> = archive
    tampered = <<head::binary, Bitwise.bxor(byte, 1)>>

    assert Archive.decode(tampered, {:open, &Vault.open(key, &1)}) == {:error, :damaged}
  end

  test "anything else is not an export", %{key: key} do
    opener = {:open, &Vault.open(key, &1)}

    assert Archive.decode("", opener) == {:error, :not_an_export}
    assert Archive.decode("{\"kdf\": {}}", opener) == {:error, :not_an_export}
    assert Archive.decode(:crypto.strong_rand_bytes(64), opener) == {:error, :not_an_export}
  end

  test "a newer format is refused rather than misread", %{key: key, archive: archive} do
    <<"MWTEXPORT", 1, rest::binary>> = archive

    assert Archive.decode(<<"MWTEXPORT", 2, rest::binary>>, {:open, &Vault.open(key, &1)}) ==
             {:error, :unsupported_version}
  end

  test "a header asking for an unbounded key derivation is refused before deriving", %{
    archive: archive
  } do
    <<"MWTEXPORT", 1, size::32, header::binary-size(size), payload::binary>> = archive

    header =
      header
      |> Jason.decode!()
      |> put_in(["kdf", "iterations"], 1_000_000_000)
      |> Jason.encode!()

    tampered = <<"MWTEXPORT", 1, byte_size(header)::32, header::binary, payload::binary>>

    assert Archive.decode(tampered, {:password, @password}) == {:error, :damaged}
  end
end
