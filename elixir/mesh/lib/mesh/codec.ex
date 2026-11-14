defmodule Mesh.Codec do
  @moduledoc """
  Codec do protocolo da ponte, em Elixir puro — e a escolha entre ele e o NIF
  em Rust.

  ## Por que existem duas implementações

  O protocolo é o mesmo que `Mesh.Bridge` usa, e já tem quatro implementações:
  Elixir (aqui), Go, Gleam e Rust (via `Mesh.Nif`). As quatro são verificadas
  contra os mesmos vetores de bytes.

  A quarta não existe para ser mais rápida. Existe para **medir quanto custa
  cruzar para o nativo**, que é a decisão que todo projeto BEAM enfrenta e
  quase ninguém mede: o trabalho do codec é tão pequeno que o tempo medido é
  quase todo travessia. Crescendo o payload até o trabalho dominar, aparece o
  **ponto de cruzamento** — e abaixo dele o NIF perde.

  O número está em `bench/nif.exs` e no README.

  ## Degradação visível

  `nif_disponivel?/0` diz se o Rust foi compilado. Quando não foi, `encode/3` e
  `decode/1` usam a versão em Elixir sem avisar — mas quem quer saber, pergunta.
  É o mesmo padrão do `nucleo_ligado` no gateway: funciona sem, degrada de forma
  observável.
  """

  @tipo_connect 1
  @tipo_push 4

  @doc """
  Codifica um quadro em Elixir puro.

  Um `<<>>` com três campos. É difícil fazer melhor que isso em qualquer
  linguagem — o que é justamente o que torna a comparação com o NIF
  interessante: não há trabalho a otimizar, só travessia a pagar.
  """
  def encode(tipo, id, payload \\ <<>>)
      when tipo >= @tipo_connect and tipo <= @tipo_push and is_integer(id) do
    <<tipo::8, id::big-64, payload::binary>>
  end

  @doc """
  Decodifica um quadro.

  Devolve `{:ok, {tipo, id, payload}}` ou `{:error, motivo}` — a mesma forma do
  NIF, para que o teste de conformidade compare os dois sem adaptador.
  """
  def decode(<<tipo::8, id::big-64, payload::binary>>)
      when tipo >= @tipo_connect and tipo <= @tipo_push do
    {:ok, {tipo, id, payload}}
  end

  def decode(<<tipo::8, _id::big-64, _::binary>>) do
    {:error, "tipo_desconhecido: #{tipo}"}
  end

  def decode(curto) when is_binary(curto) do
    {:error, "curto_demais: #{byte_size(curto)}"}
  end

  @doc """
  O NIF em Rust está compilado e carregado?

  A detecção é por tentativa, não por `Code.ensure_loaded?`: o módulo
  `Mesh.Nif` **existe** mesmo sem o NIF — o que falta é a biblioteca nativa, e
  isso só aparece ao chamar.
  """
  def nif_disponivel? do
    try do
      Mesh.Nif.travessia_vazia(1) == 2
    rescue
      # `rescue _` ja cobre o ErlangError de :nif_not_loaded; um `catch
      # :error, _` depois disto e clausula inalcancavel, e o compilador avisa.
      _ -> false
    end
  end
end
