# nif.exs — quanto custa cruzar para o nativo, e a partir de quando compensa.
#
#   MESH_BUILD_NIF=1 mix run bench/nif.exs
#
# ## A pergunta
#
# "Escreve em Rust que fica mais rápido" é conselho dado sem número. O custo de
# um NIF tem duas partes:
#
#   1. a travessia -- entrar no nativo, converter os termos, voltar;
#   2. o trabalho -- o que a função de fato faz.
#
# Se (1) for maior que a economia em (2), o NIF PERDE. Este benchmark mede as
# duas separadamente e procura o **ponto de cruzamento**: o tamanho de payload
# a partir do qual vale a pena.
#
# A estratégia: o codec é trabalho desprezível, então o tempo dele é quase todo
# travessia. Crescendo o payload, o trabalho (copiar bytes) passa a dominar.
#
# ## A primeira versão disto estava errada, e do jeito que eu já sabia
#
# Ela media as 7 repetições do Elixir e **depois** as 7 do Rust. Duas execuções
# seguidas deram conclusões opostas: "nenhum ponto de cruzamento, travessia de
# 30 ns" e "cruzamento em 64 B, travessia de 66 ns".
#
# É exatamente o erro que o p01-metal-vm documenta: medir A em bloco e B em
# bloco atribui a B qualquer deriva de frequência que ocorra no meio. Em laptop,
# com escalonamento térmico, a deriva é da ordem da diferença medida.
#
# Esta versão:
#
#   * **alterna A e B a cada repetição**, para que a deriva atinja os dois;
#   * **reporta a dispersão** de cada lado -- número sem dispersão ao lado não
#     é medição, é anedota;
#   * **aquece** antes de medir e coleta lixo entre repetições, porque os
#     binários produzidos são lixo e a coleta deles cairia na medição seguinte;
#   * **recusa-se a concluir** quando a diferença não supera o ruído. Um
#     benchmark que sempre conclui algo é um benchmark que mente em máquina
#     ruidosa.

unless Mesh.Codec.nif_disponivel?() do
  IO.puts("""

  O NIF nao esta compilado. Rode:

      MESH_BUILD_NIF=1 mix run bench/nif.exs --force

  (o --force e necessario porque System.get_env em tempo de compilacao nao e
  rastreado pelo mix; ver lib/mesh/nif.ex)
  """)

  System.halt(1)
end

reps = 9
base_iters = 200_000

# Dispersao como (max-min)/min em porcentagem.
disp = fn amostras ->
  mn = Enum.min(amostras)
  mx = Enum.max(amostras)
  if mn == 0, do: 0.0, else: Float.round((mx - mn) / mn * 100, 1)
end

# Mede A e B ALTERNANDO, repeticao por repeticao. Esta e a correcao.
medir_par = fn fa, fb, iters ->
  roda = fn f -> elem(:timer.tc(fn -> Enum.each(1..iters, fn _ -> f.() end) end), 0) end

  # Aquecimento: a primeira passagem paga o JIT do Erlang, o faulting das
  # paginas do .so e o crescimento inicial do heap de binarios.
  roda.(fa)
  roda.(fb)

  pares =
    Enum.map(1..reps, fn _ ->
      :erlang.garbage_collect()
      ua = roda.(fa)
      :erlang.garbage_collect()
      ub = roda.(fb)
      {ua, ub}
    end)

  as = Enum.map(pares, &elem(&1, 0))
  bs = Enum.map(pares, &elem(&1, 1))

  ns = fn us -> Float.round(Enum.min(us) * 1000 / iters, 1) end

  %{a: ns.(as), b: ns.(bs), disp_a: disp.(as), disp_b: disp.(bs)}
end

IO.puts("""

=== Custo da travessia BEAM <-> Rust ===

repeticoes   : #{reps}, ALTERNADAS entre as duas implementacoes
estatistica  : minimo (estavel em maquina ruidosa; o maximo varia 3x)
dispersao    : (max-min)/min, reportada ao lado de cada numero
rustler      : a camada de conversao de termos dele FAZ PARTE do custo
""")

# ------------------------------------------------- 1. a travessia, isolada
soma_elixir = fn n -> n + 1 end

t =
  medir_par.(
    fn -> soma_elixir.(1) end,
    fn -> Mesh.Nif.travessia_vazia(1) end,
    base_iters
  )

IO.puts("1. Travessia isolada (somar 1)")
IO.puts("   Elixir : #{t.a} ns/op  (disp #{t.disp_a}%)")
IO.puts("   Rust   : #{t.b} ns/op  (disp #{t.disp_b}%)")

custo_travessia = Float.round(t.b - t.a, 1)
disp_travessia = max(t.disp_a, t.disp_b)

IO.puts("   custo da travessia: ~#{custo_travessia} ns por chamada")

if disp_travessia > 15.0 do
  IO.puts("   AVISO: dispersao de #{disp_travessia}% -- trate como ordem de grandeza")
end

# ----------------------------------------- 2. encode, variando o payload
IO.puts("""

2. Encode, por tamanho de payload

#{String.pad_trailing("payload", 10)}#{String.pad_leading("Elixir", 11)}#{String.pad_leading("disp", 8)}#{String.pad_leading("Rust", 11)}#{String.pad_leading("disp", 8)}#{String.pad_leading("razao", 9)}#{String.pad_leading("veredito", 12)}
#{String.duplicate("-", 69)}\
""")

tamanhos = [0, 16, 64, 256, 1024, 4096, 16_384, 65_536, 262_144, 1_048_576]

linhas =
  Enum.map(tamanhos, fn n ->
    payload = :crypto.strong_rand_bytes(n)

    iters =
      cond do
        n >= 262_144 -> 2_000
        n >= 4096 -> 20_000
        true -> base_iters
      end

    r =
      medir_par.(
        fn -> Mesh.Codec.encode(3, 7, payload) end,
        fn -> Mesh.Nif.encode(3, 7, payload) end,
        iters
      )

    razao = Float.round(r.a / r.b, 2)
    pior_disp = max(r.disp_a, r.disp_b)

    # O veredito so se pronuncia quando a diferenca supera o ruido. Com
    # dispersao de 30% e razao de 0,95x, dizer "Elixir ganha" e inventar.
    margem = abs(razao - 1.0) * 100

    veredito =
      cond do
        margem < pior_disp -> "no ruido"
        razao > 1.0 -> "Rust"
        true -> "Elixir"
      end

    rotulo =
      cond do
        n == 0 -> "vazio"
        n < 1024 -> "#{n} B"
        true -> "#{div(n, 1024)} KiB"
      end

    IO.puts(
      String.pad_trailing(rotulo, 10) <>
        String.pad_leading("#{r.a} ns", 11) <>
        String.pad_leading("#{r.disp_a}%", 8) <>
        String.pad_leading("#{r.b} ns", 11) <>
        String.pad_leading("#{r.disp_b}%", 8) <>
        String.pad_leading("#{razao}x", 9) <>
        String.pad_leading(veredito, 12)
    )

    %{n: n, rotulo: rotulo, razao: razao, veredito: veredito, disp: pior_disp}
  end)

IO.puts("\n=== Conclusao ===\n")

venceu_rust = Enum.filter(linhas, &(&1.veredito == "Rust"))
venceu_elixir = Enum.filter(linhas, &(&1.veredito == "Elixir"))
no_ruido = Enum.filter(linhas, &(&1.veredito == "no ruido"))

IO.puts(
  "  Rust venceu em #{length(venceu_rust)} ponto(s), Elixir em " <>
    "#{length(venceu_elixir)}, e #{length(no_ruido)} ficaram dentro do ruido.\n"
)

cond do
  venceu_rust == [] and venceu_elixir != [] ->
    IO.puts("""
      O NIF **nao venceu em nenhum tamanho medido**, de vazio a 1 MiB.

      Isso nao e falha do Rust: construir um binario concatenando tres campos e
      uma instrucao da maquina virtual. A BEAM faz isso sem sair do runtime, e
      nao ha nada para o nativo otimizar -- so travessia a pagar.
    """)

  venceu_rust != [] ->
    primeiro = hd(venceu_rust)

    IO.puts("""
      Primeiro tamanho em que o Rust venceu acima do ruido: **#{primeiro.rotulo}**.

      Abaixo disso a travessia custa mais do que o Rust economiza.
    """)

  true ->
    IO.puts("""
      **Nao determinado.** Todos os pontos ficaram dentro da dispersao desta
      maquina. Os numeros servem de ordem de grandeza, nao de comparacao.

      Esta e uma resposta legitima, e o portfolio ja a deu uma vez: no
      p01-metal-vm a comparacao entre switch e computed goto foi publicada tres
      vezes e corrigida duas antes de terminar em "nao determinado".
    """)
end

IO.puts("""
  O numero para decidir: **~#{custo_travessia} ns de travessia por chamada**
  (dispersao de #{disp_travessia}%). Qualquer funcao que faca menos trabalho que
  isso fica mais lenta em Rust.

  NIF compensa quando o trabalho e ALGORITMICAMENTE mais barato em nativo --
  compressao, criptografia, parsing com SIMD -- nao quando e movimentacao de
  dados, caso em que as duas implementacoes fazem o mesmo memcpy e o nativo
  paga a travessia por cima.

  E a regra que nao aparece em benchmark: um NIF roda NO ESCALONADOR da BEAM.
  Bloquear por mais de ~1 ms destroi a latencia de todo o no. As funcoes aqui
  retornam em nanossegundos; trabalho longo exigiria dirty schedulers, que esta
  implementacao deliberadamente nao usa porque nao precisa.
""")
