//> using scala 3.10.1
//> using jvm system

// Preempcao.scala — o que os 1.323 bytes da thread virtual NÃO compram.
//
//   scala-cli run Preempcao.scala -- 4 2
//
// ## A pergunta que o número de memória esconde
//
// `Concorrencia.scala` mede a thread virtual em **1.323 bytes** contra **2.732
// bytes** do processo da BEAM. Lido sozinho, esse número diz "Loom ganhou".
//
// Ele não diz o principal: a thread virtual é mais barata porque **compra
// menos**. Este programa mede a diferença que importa.
//
// ## O experimento
//
// Threads virtuais são escalonadas **cooperativamente**: elas só cedem o
// carregador em um ponto de bloqueio (I/O, `sleep`, `lock`). Um laço que só
// calcula **não tem ponto de cedência** e prende o carregador até terminar.
//
// Então: `ocupadas` threads virtuais em laço fechado, sobre `carregadores`
// threads carregadoras. Se `ocupadas >= carregadores`, não sobra carregador — e
// uma thread que chega depois espera.
//
// A métrica é a **latência de atendimento**: quanto tempo uma thread virtual
// recém-criada demora para rodar sua primeira instrução.
//
// O equivalente na BEAM está em `elixir/mesh/bench/preempcao.exs`. Lá o
// escalonador é **preemptivo por contagem de reduções**: ele interrompe o
// processo que calcula, quer ele queira ou não. A previsão é que a latência
// fique baixa mesmo com todos os escalonadores ocupados.
//
// Isto não é defeito de Loom: é a troca que Loom fez de propósito, e é
// exatamente o que o p03 existe para mostrar — que "processo leve" e "processo
// isolado e preemptado" são promessas diferentes.

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.{CountDownLatch, TimeUnit}

object Preempcao:

  def main(args: Array[String]): Unit =
    val ocupadas = args.lift(0).map(_.toInt).getOrElse(4)
    val carregadores = args.lift(1).map(_.toInt).getOrElse(2)

    // A paralelismo do escalonador de threads virtuais tem de ser definido
    // ANTES de a primeira thread virtual existir, senao o valor e ignorado.
    System.setProperty("jdk.virtualThreadScheduler.parallelism", carregadores.toString)
    System.setProperty("jdk.virtualThreadScheduler.maxPoolSize", carregadores.toString)

    println(s"""
=== Latencia de atendimento sob carga de CPU (JVM) ===

threads virtuais em laco fechado : $ocupadas
threads carregadoras             : $carregadores
nucleos da maquina               : ${Runtime.getRuntime.availableProcessors}
jvm                              : ${System.getProperty("java.version")}

Escalonamento de threads virtuais e COOPERATIVO: um laco sem ponto de
bloqueio prende o carregador. Com $ocupadas >= $carregadores, nao sobra
carregador para quem chegar depois.
""")

    // ---------------------------------------------- 1. medicao de referencia
    // Sem carga: quanto custa criar uma thread virtual e ela rodar.
    val semCarga = mediaLatencia(5)
    println(f"  1. sem carga        : ${semCarga}%.3f ms")

    // ---------------------------------------------- 2. sob carga
    val parar = new AtomicBoolean(false)
    val emLaco = new CountDownLatch(ocupadas)

    val hogs = (1 to ocupadas).map { _ =>
      Thread.ofVirtual().start { () =>
        emLaco.countDown()
        // Laco fechado, sem I/O, sem sleep, sem lock: nenhum ponto de cedencia.
        // `x` e volatil via AtomicBoolean na condicao para o JIT nao eliminar
        // o laco inteiro -- otimizacao que faria o experimento medir nada.
        var x = 0L
        while !parar.get() do x += 1
        if x == Long.MinValue then println("")
      }
    }

    // Espera os hogs de fato entrarem no laco. Sem isto, mediriamos a latencia
    // antes da carga existir -- o erro mais facil de cometer aqui.
    emLaco.await(5, TimeUnit.SECONDS)
    Thread.sleep(300)

    val comCarga = mediaLatencia(5)
    println(f"  2. sob carga de CPU : ${comCarga}%.3f ms")

    parar.set(true)
    hogs.foreach(_.join(2000))

    // ---------------------------------------------- resultado
    val fator = if semCarga > 0 then comCarga / semCarga else Double.NaN

    println(f"""
=== Resultado (JVM, threads virtuais) ===

  latencia sem carga  : ${semCarga}%.3f ms
  latencia sob carga  : ${comCarga}%.3f ms
  **degradacao        : ${fator}%.0fx**
""")

    if comCarga > 100 then
      println("""  A thread que chegou depois esperou os hogs TERMINAREM. Nao houve
  preempcao: o escalonador de threads virtuais nao interrompe quem calcula.

  Em um servidor, isto e a diferenca entre "uma requisicao pesada deixa as
  outras lentas" e "uma requisicao pesada trava as outras".""")
    else
      println("""  A latencia aguentou. Vale desconfiar do experimento antes de
  comemorar: verifique se os hogs estavam de fato em laco (o JIT pode ter
  eliminado o laco) e se o paralelismo foi aplicado.""")

    System.exit(0)

  /** Mede quanto tempo uma thread virtual nova demora para rodar sua primeira
    * instrucao. Melhor de `n`, como no resto do portfolio.
    */
  def mediaLatencia(n: Int): Double =
    val amostras =
      (1 to n).map { _ =>
        val pronto = new CountDownLatch(1)
        val t0 = System.nanoTime()
        Thread.ofVirtual().start(() => pronto.countDown())
        // Teto de 10 s: sem ele, uma inanicao real penduraria o programa e o
        // resultado seria "travou" em vez de um numero.
        val chegou = pronto.await(10, TimeUnit.SECONDS)
        val dt = (System.nanoTime() - t0) / 1e6
        if chegou then dt else 10_000.0
      }

    amostras.min
