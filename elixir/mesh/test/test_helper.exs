# Os testes do NIF só rodam quando ele foi compilado (`MESH_BUILD_NIF=1`).
#
# Excluir por tag é melhor que pular dentro do teste: sem o NIF, a suíte
# informa "N excluded" em vez de passar silenciosamente como se tivesse
# verificado algo.
excluir = if Mesh.Codec.nif_disponivel?(), do: [], else: [:nif]

if excluir != [] do
  IO.puts(
    "\n(NIF em Rust nao compilado: testes :nif excluidos. " <>
      "Para incluir: MESH_BUILD_NIF=1 mix test --force)\n"
  )
end

ExUnit.start(exclude: excluir)
