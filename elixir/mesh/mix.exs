defmodule Mesh.MixProject do
  use Mix.Project

  def project do
    [
      app: :mesh,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Mesh.Application, []}
    ]
  end

  # ## O nucleo continua com zero dependencias
  #
  # `rustler` so entra na lista quando `MESH_BUILD_NIF=1`. Sem a variavel,
  # `deps/0` devolve `[]` e o projeto compila exatamente como antes do NIF
  # existir -- sem baixar nada, sem `mix deps.get`.
  #
  # Isto nao e purismo: a primeira versao declarava `rustler` sempre, e **dois
  # jobs do CI que passavam quebraram** com "Unchecked dependencies for
  # environment dev", porque eles nao rodam `mix deps.get` -- nunca precisaram.
  # O erro apontou para a incoerencia real: se o nucleo e o produto e o NIF e
  # uma medicao, o nucleo nao pode passar a exigir download para compilar.
  #
  # ## Por que `rustler` e nao um NIF escrito a mao
  #
  # Escrever contra a ABI do `erl_nif.h` sao dezenas de linhas de `unsafe
  # extern "C"` e conversao manual de termos. Isso nao mediria "quanto custa
  # cruzar para o nativo", mediria a qualidade do meu boilerplate. `rustler` e
  # o que se usaria de verdade, entao e com ele que o custo medido corresponde
  # ao custo real -- e a camada fina de conversao de termos dele **faz parte**
  # do que um projeto paga, o que esta declarado no README junto com o numero.
  defp deps do
    if System.get_env("MESH_BUILD_NIF") == "1" do
      [{:rustler, "~> 0.36", runtime: false}]
    else
      []
    end
  end
end
