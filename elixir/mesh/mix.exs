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

  # `rustler` é a única dependência do projeto, e é `runtime: false`: ele serve
  # para compilar o NIF em Rust, não para executá-lo.
  #
  # Por que uma dependência aqui, depois de o resto do portfólio ter zero:
  # escrever um NIF à mão contra a ABI do `erl_nif.h` é dezenas de linhas de
  # `unsafe extern "C"` e conversão manual de termos. Isso não mediria "quanto
  # custa cruzar para o nativo", mediria a qualidade do meu boilerplate.
  # `rustler` é o que se usaria de verdade, então é com ele que o custo medido
  # corresponde ao custo real.
  #
  # Ele acrescenta uma camada fina de codificação/decodificação de termos, e
  # essa camada **faz parte** do que um projeto real paga — está declarado no
  # README junto com o número.
  defp deps do
    [
      {:rustler, "~> 0.36", runtime: false}
    ]
  end
end
