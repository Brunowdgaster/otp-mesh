# Gera os vetores de bytes compartilhados pelas tres implementacoes do
# protocolo. O Elixir e a fonte: ele e o lado que define o formato.
casos = [
  {Mesh.Bridge.tipo_connect(), 1, ""},
  {Mesh.Bridge.tipo_connect(), 0, ""},
  {Mesh.Bridge.tipo_connect(), 18_446_744_073_709_551_615, ""},
  {Mesh.Bridge.tipo_disconnect(), 42, ""},
  {Mesh.Bridge.tipo_data(), 7, "oi"},
  {Mesh.Bridge.tipo_data(), 123_456_789, "payload com acentuacao: coracao"},
  {Mesh.Bridge.tipo_data(), 1, <<0, 255, 128, 1>>},
  {Mesh.Bridge.tipo_data(), 99, String.duplicate("x", 300)},
  {Mesh.Bridge.tipo_push(), 5, "de volta"},
  {Mesh.Bridge.tipo_push(), 1, ""}
]

linhas =
  for {tipo, id, payload} <- casos do
    quadro = Mesh.Bridge.frame(tipo, id, payload)
    hex_payload =
      case Base.encode16(payload, case: :lower) do
        # `-` marca payload vazio: sem isso a linha fica com dois espacos
        # seguidos e qualquer divisao por espacos produz um campo a menos,
        # quebrando os tres parsers de um jeito diferente cada.
        "" -> "-"
        h -> h
      end

    "#{tipo} #{id} #{hex_payload} #{Base.encode16(quadro, case: :lower)}"
  end

cabecalho = """
# Vetores de bytes do protocolo da ponte.
#
# Gerado por elixir/mesh -> mix run (ver tests/gera_vetores.exs). O Elixir e a
# fonte de verdade do formato; Go e Gleam sao verificados contra estes bytes.
#
# Formato de cada linha:
#   <tipo> <client_id> <payload_hex> <quadro_hex>
#
# payload_hex e `-` quando o payload e vazio.
#
# O quadro NAO inclui o prefixo de tamanho: do lado Elixir ele vem do
# `packet: 4` do inet, e do lado Go sao quatro bytes a mais na escrita.
"""

File.write!("../../protocolo/vetores.txt", cabecalho <> Enum.join(linhas, "\n") <> "\n")
IO.puts("#{length(linhas)} vetores escritos em protocolo/vetores.txt")
