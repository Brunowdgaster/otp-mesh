defmodule Mesh.NifTest do
  @moduledoc """
  O codec em Rust como **quarta** implementação do protocolo, verificada contra
  os mesmos vetores de bytes que Elixir, Go e Gleam.

  Quatro linguagens, um formato, um arquivo de vetores. É o que garante que a
  travessia para o nativo não introduziu divergência — e divergência aqui seria
  especialmente traiçoeira, porque o NIF roda no mesmo processo e um byte
  trocado não daria erro nenhum.
  """

  use ExUnit.Case, async: true

  # Sem o NIF compilado, este módulo inteiro é excluído. Ver test_helper.exs.
  @moduletag :nif

  @vetores Path.join([__DIR__, "..", "..", "..", "protocolo", "vetores.txt"])

  defp carrega do
    @vetores
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn linha ->
      [t, i, p, q] = String.split(linha, " ", trim: true)

      payload =
        case p do
          "-" -> <<>>
          hex -> Base.decode16!(hex, case: :lower)
        end

      %{
        tipo: String.to_integer(t),
        id: String.to_integer(i),
        payload: payload,
        quadro: Base.decode16!(q, case: :lower)
      }
    end)
  end

  test "o NIF esta carregado" do
    assert Mesh.Codec.nif_disponivel?()
    assert Mesh.Nif.travessia_vazia(41) == 42
  end

  test "os vetores existem" do
    assert length(carrega()) == 10
  end

  test "encode em Rust da exatamente os bytes dos vetores" do
    for v <- carrega() do
      assert Mesh.Nif.encode(v.tipo, v.id, v.payload) == v.quadro,
             "tipo=#{v.tipo} id=#{v.id} divergiu"
    end
  end

  test "decode em Rust devolve os campos certos" do
    for v <- carrega() do
      assert {:ok, {tipo, id, payload}} = Mesh.Nif.decode(v.quadro)
      assert tipo == v.tipo
      assert id == v.id
      assert payload == v.payload
    end
  end

  test "Rust e Elixir concordam byte a byte" do
    # A verificacao mais direta: as duas implementacoes, mesmos argumentos.
    for v <- carrega() do
      assert Mesh.Nif.encode(v.tipo, v.id, v.payload) ==
               Mesh.Codec.encode(v.tipo, v.id, v.payload)

      assert Mesh.Nif.decode(v.quadro) == Mesh.Codec.decode(v.quadro)
    end
  end

  test "Rust recusa quadro curto, como o Elixir" do
    curto = <<1, 2, 3, 4, 5, 6, 7, 8>>
    assert {:error, _} = Mesh.Nif.decode(curto)
    assert {:error, _} = Mesh.Codec.decode(curto)
    assert {:error, _} = Mesh.Nif.decode(<<>>)
  end

  test "Rust recusa tipo desconhecido, como o Elixir" do
    quadro = <<9::8, 1::big-64>>
    assert {:error, _} = Mesh.Nif.decode(quadro)
    assert {:error, _} = Mesh.Codec.decode(quadro)
  end

  test "as fronteiras do campo de 64 bits atravessam o NIF intactas" do
    # A travessia converte o inteiro da BEAM para u64 e de volta. Errar o sinal
    # ou o tamanho aqui daria um id diferente do enviado -- e o sintoma seria
    # "conexao nao encontrada" num cliente que existe.
    for id <- [0, 1, 4_294_967_296, 18_446_744_073_709_551_615] do
      quadro = Mesh.Nif.encode(1, id, <<>>)
      assert {:ok, {1, ^id, <<>>}} = Mesh.Nif.decode(quadro)
      assert quadro == Mesh.Codec.encode(1, id, <<>>)
    end
  end

  test "payload grande atravessa sem corrupcao" do
    grande = :crypto.strong_rand_bytes(64 * 1024)
    quadro = Mesh.Nif.encode(3, 1, grande)
    assert {:ok, {3, 1, ^grande}} = Mesh.Nif.decode(quadro)
    assert quadro == Mesh.Codec.encode(3, 1, grande)
  end
end
