defmodule Mesh.ProtocoloTest do
  @moduledoc """
  Conformidade do protocolo da ponte contra os vetores de bytes compartilhados.

  O mesmo arquivo — `protocolo/vetores.txt` — é lido por este teste, pelo
  `bridge_test.go` e pelo `mesh_codec_test.gleam`. Três linguagens, um formato.

  Por que isso é necessário e não decorativo: divergência de formato **não dá
  exceção**. Um lado escrevendo o id em little-endian e o outro em big-endian
  produz conexões "não encontradas" para clientes que existem — um bug que
  aparece longe da causa. Testes de unidade de cada lado passariam.

  O Elixir é a fonte de verdade do formato, e este teste é o que garante que a
  fonte não mudou sem os vetores serem regerados.
  """

  use ExUnit.Case, async: true

  alias Mesh.Bridge

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

  test "os vetores existem" do
    # Sem isto, os testes abaixo passariam vacuamente sobre lista vazia -- o
    # jeito mais facil de um teste de conformidade nao testar nada.
    assert length(carrega()) == 10
  end

  test "frame/3 gera exatamente os bytes dos vetores" do
    for v <- carrega() do
      assert Bridge.frame(v.tipo, v.id, v.payload) == v.quadro,
             "tipo=#{v.tipo} id=#{v.id} divergiu"
    end
  end

  test "os quadros dos vetores decodificam nos campos certos" do
    for v <- carrega() do
      <<tipo::8, id::big-64, payload::binary>> = v.quadro
      assert tipo == v.tipo
      assert id == v.id
      assert payload == v.payload
    end
  end

  test "as fronteiras do campo de 64 bits sobrevivem a ida e volta" do
    for id <- [0, 1, 4_294_967_296, 18_446_744_073_709_551_615] do
      <<_::8, lido::big-64>> = Bridge.frame(Bridge.tipo_connect(), id)
      assert lido == id, "id #{id} voltou como #{lido}"
    end
  end
end
