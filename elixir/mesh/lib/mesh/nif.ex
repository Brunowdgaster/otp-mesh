# Ligação com o codec em Rust.
#
# ## Compilação opcional, e por quê
#
# O NIF só é compilado quando `MESH_BUILD_NIF=1`. Sem isso, `Mesh.Nif` é um
# esqueleto cujas funções levantam `:nif_not_loaded`, e `Mesh.Codec` usa a
# implementação em Elixir puro.
#
# A alternativa seria tornar o Rust obrigatório para compilar o núcleo. Não
# vale: o núcleo em Elixir é o produto do projeto, o NIF é uma medição. Fazer
# quem clona instalar `cargo` para rodar `mix test` seria cobrar por algo que a
# maioria não vai usar — e obrigaria o job de CI do núcleo a ter toolchain Rust
# sem motivo.
#
# ## Por que o `if` em volta do módulo, e não `skip_compilation?`
#
# `use Rustler, skip_compilation?: true` evita chamar o `cargo`, mas **ainda
# gera o `@on_load`** que tenta carregar o `.so`. Sem o arquivo, o load falha e
# o compilador emite um aviso — que derruba o `--warnings-as-errors` do CI.
#
# Definir o módulo condicionalmente resolve na raiz: sem `MESH_BUILD_NIF`, não
# existe `@on_load` nenhum para falhar.
#
# ## Alternar exige `--force`, e a alternativa era pior
#
# `System.get_env` lido em tempo de compilação **não é rastreado pelo mix**:
# alternar a variável não invalida o módulo, e o `.beam` antigo fica no lugar.
# O sintoma é cruel — `MESH_BUILD_NIF=1 mix compile` não recompila nada e a
# função levanta `:nif_not_loaded` com a variável definida.
#
# A alternativa idiomática seria `Application.compile_env/3`, que o mix
# rastreia. Foi tentada e é pior aqui: a validação de `compile_env` roda
# **antes** da compilação e **aborta** com "different value set for key during
# runtime compared to compile time", exigindo recompilação manual em vez de
# fazê-la. Troca um `--force` explícito por um erro que parece bug.
#
# Então: alternar o NIF pede `--force`, e está documentado em "Como rodar".
#
#     MESH_BUILD_NIF=1 mix compile --force
#     MESH_BUILD_NIF=1 mix run bench/nif.exs

if System.get_env("MESH_BUILD_NIF") == "1" do
  defmodule Mesh.Nif do
    @moduledoc """
    Codec do protocolo em Rust, carregado como NIF.

    Compilado porque `MESH_BUILD_NIF=1` estava definido. Ver `Mesh.Codec` para
    a implementação em Elixir e para a comparação entre as duas.
    """

    use Rustler, otp_app: :mesh, crate: "mesh_nif"

    @doc "Codifica um quadro. Ver `Mesh.Codec.encode/3`."
    def encode(_tipo, _id, _payload), do: :erlang.nif_error(:nif_not_loaded)

    @doc "Decodifica um quadro. Ver `Mesh.Codec.decode/1`."
    def decode(_quadro), do: :erlang.nif_error(:nif_not_loaded)

    @doc """
    Linha de base da travessia: soma 1 e devolve.

    Existe para que o custo do `encode/3` tenha com o que ser comparado — sem
    ela, não há como separar "o trabalho é caro" de "entrar no nativo é caro".
    """
    def travessia_vazia(_n), do: :erlang.nif_error(:nif_not_loaded)
  end
else
  defmodule Mesh.Nif do
    @moduledoc """
    Esqueleto do codec em Rust. **O NIF não foi compilado.**

    Para compilá-lo: `MESH_BUILD_NIF=1 mix compile`. Enquanto isso,
    `Mesh.Codec.nif_disponivel?/0` devolve `false` e o codec em Elixir é usado.
    """

    def encode(_tipo, _id, _payload), do: :erlang.nif_error(:nif_not_loaded)
    def decode(_quadro), do: :erlang.nif_error(:nif_not_loaded)
    def travessia_vazia(_n), do: :erlang.nif_error(:nif_not_loaded)
  end
end
