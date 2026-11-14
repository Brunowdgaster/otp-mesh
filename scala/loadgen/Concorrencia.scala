//> using scala 3.10.1
//> using jvm system

// Concorrencia.scala — quanto custa UMA unidade de concorrência, na JVM e na BEAM.
//
//   scala-cli run Concorrencia.scala -- platform 20000
//   scala-cli run Concorrencia.scala -- virtual  500000
//
// ## A pergunta
//
// O p03 mede 3.534 bytes por conexão na BEAM, e esse número só significa algo
// contra outra coisa. A JVM oferece duas respostas para "uma unidade de
// concorrência bloqueada":
//
//   * **thread de plataforma** -- uma thread do sistema operacional, com pilha
//     própria reservada (1 MiB por padrão no Linux x64);
//   * **thread virtual** (Loom, JDK 21+) -- multiplexada sobre um punhado de
//     threads carregadoras, com a pilha vivendo no heap e crescendo sob demanda.
//
// A segunda é o análogo direto do processo da BEAM, e é a comparação que
// interessa: dois runtimes que prometem a mesma coisa — "crie um por conexão,
// bloquear é de graça" — medidos na mesma máquina.
//
// ## Um processo JVM por modo, e por quê
//
// Este programa mede UM modo por execução. Criar 20 mil threads de plataforma e
// depois medir as virtuais no mesmo processo mediria o heap já crescido, as
// pilhas já faultadas e o GC já aquecido pelo primeiro modo.
//
// É a mesma disciplina que `bench/capacity.exs` usa do lado do Elixir: o A/B
// limpo exige processos separados. A diferença entre os dois é comparada pelo
// script que os invoca, não dentro de um deles.
//
// ## Duas métricas, porque uma sozinha mente
//
// **Reservado** = threads x tamanho da pilha. É o que o sistema promete e o que
// limita quantas threads cabem num espaço de endereçamento.
//
// **RSS** = páginas de fato tocadas. Uma thread de plataforma bloqueada toca
// talvez 16 KiB da sua pilha de 1 MiB, então o RSS **subestima por 60x** o que
// a thread custa em espaço reservado.
//
// Reportar só RSS faria a thread de plataforma parecer barata; reportar só o
// reservado faria parecer catastrófica. As duas, lado a lado, é o que permite
// comparar com os 3.534 bytes da BEAM — que são medidos no heap da BEAM, isto é,
// memória de fato usada, e portanto comparáveis ao RSS.

import com.sun.management.HotSpotDiagnosticMXBean
import java.lang.management.ManagementFactory
import java.util.concurrent.{CountDownLatch, LinkedBlockingQueue}
import scala.io.Source
import scala.util.Using

object Concorrencia:

  /** Lê VmRSS de /proc/self/status, em bytes.
    *
    * Por que /proc e não `Runtime.totalMemory`: as pilhas das threads de
    * plataforma **não estão no heap da JVM**. Medir só o heap daria ~0 bytes
    * por thread de plataforma, que é exatamente a conclusão errada.
    */
  def rssBytes(): Long =
    Using(Source.fromFile("/proc/self/status")) { f =>
      f.getLines()
        .find(_.startsWith("VmRSS:"))
        .map(_.split("\\s+")(1).toLong * 1024)
        .getOrElse(0L)
    }.getOrElse(0L)

  /** Heap em uso, depois de pedir coleta. */
  def heapBytes(): Long =
    System.gc()
    Thread.sleep(80)
    val r = Runtime.getRuntime
    r.totalMemory - r.freeMemory

  /** Tamanho da pilha de uma thread de plataforma, LIDO da JVM.
    *
    * Nao assumido: `-XX:ThreadStackSize` e configuravel e o padrao varia por
    * plataforma. Assumir 1 MiB e publicar "reservado = N x 1 MiB" seria
    * inventar o numero mais importante da tabela.
    *
    * O valor vem em KiB. Se o MXBean nao existir (JVM que nao seja HotSpot), a
    * funcao **falha alto** em vez de devolver um palpite.
    */
  lazy val tamanhoPilhaPlataforma: Long =
    val bean = ManagementFactory.getPlatformMXBean(classOf[HotSpotDiagnosticMXBean])
    val kib = bean.getVMOption("ThreadStackSize").getValue.toLong
    require(kib > 0, s"ThreadStackSize invalido: $kib")
    kib * 1024

  def fmt(b: Long): String =
    if math.abs(b) >= 1024L * 1024 then f"${b / 1024.0 / 1024.0}%.1f MiB"
    else if math.abs(b) >= 1024 then f"${b / 1024.0}%.1f KiB"
    else s"$b B"

  def main(args: Array[String]): Unit =
    val modo = args.headOption.getOrElse("virtual")
    val alvo = args.lift(1).map(_.toInt).getOrElse(100_000)

    require(modo == "platform" || modo == "virtual", s"modo invalido: $modo")

    val virtuais = modo == "virtual"

    println(s"""
=== Custo de uma unidade de concorrencia bloqueada ===

modo        : $modo
alvo        : $alvo
jvm         : ${System.getProperty("java.version")}
heap max    : ${fmt(Runtime.getRuntime.maxMemory)}
nucleos     : ${Runtime.getRuntime.availableProcessors}
""")

    // Cada "conexao" bloqueia em take() numa fila propria. Bloqueada de
    // verdade: nao consome CPU, e e o estado em que uma conexao ociosa de fato
    // fica. Uma fila por thread, porque uma fila compartilhada faria N-1
    // threads esperarem no mesmo monitor e mediria contencao, nao custo.
    val filas = scala.collection.mutable.ArrayBuffer.empty[LinkedBlockingQueue[Int]]
    val prontas = new CountDownLatch(alvo)
    val threads = scala.collection.mutable.ArrayBuffer.empty[Thread]

    val rss0 = rssBytes()
    val heap0 = heapBytes()

    println(f"  base: RSS ${fmt(rss0)}%s, heap ${fmt(heap0)}%s")
    println()
    println(
      "%-10s %12s %12s %14s %14s".format("criadas", "RSS", "heap", "RSS/unid", "reserv/unid")
    )
    println("-" * 66)

    val t0 = System.nanoTime()
    var criadas = 0
    var falhou: Option[String] = None

    // Marcos em escala logaritmica: a curva interessa mais que os pontos.
    val marcos = Iterator
      .iterate(1000)(_ * 2)
      .takeWhile(_ <= alvo)
      .toList
      .appended(alvo)
      .distinct
      .sorted

    var proximoMarco = marcos

    try
      while criadas < alvo && falhou.isEmpty do
        val fila = new LinkedBlockingQueue[Int]()
        filas += fila

        val corpo: Runnable = () =>
          prontas.countDown()
          // take() bloqueia para sempre; o processo termina matando a JVM.
          try fila.take()
          catch case _: InterruptedException => ()

        val t =
          try
            if virtuais then Thread.ofVirtual().start(corpo)
            else Thread.ofPlatform().start(corpo)
          catch
            // Captura so o limite ESPERADO. "unable to create native thread" e
            // o fim da rampa de threads de plataforma, e e o dado que queremos.
            // Qualquer outra falha derruba o processo de proposito: o portfolio
            // ja perdeu tempo cinco vezes com harness que engoliu erro.
            case e: OutOfMemoryError =>
              falhou = Some(s"OutOfMemoryError em $criadas: ${e.getMessage}")
              null

        if t != null then
          threads += t
          criadas += 1

          if proximoMarco.nonEmpty && criadas >= proximoMarco.head then
            val marco = proximoMarco.head
            proximoMarco = proximoMarco.tail

            val rss = rssBytes()
            val heap = heapBytes()
            val porUnidRss = (rss - rss0) / criadas
            val reservPorUnid =
              if virtuais then 0L else tamanhoPilhaPlataforma

            println(
              "%-10d %12s %12s %14s %14s".format(
                criadas,
                fmt(rss),
                fmt(heap),
                fmt(porUnidRss),
                if virtuais then "(no heap)" else fmt(reservPorUnid)
              )
            )
    catch case e: OutOfMemoryError => falhou = Some(s"OutOfMemoryError em $criadas")

    val segundos = (System.nanoTime() - t0) / 1e9

    val rssFinal = rssBytes()
    val heapFinal = heapBytes()

    println()
    println(s"=== Resultado ($modo) ===\n")
    println(f"  criadas            : $criadas")
    println(f"  tempo              : $segundos%.2f s  (${criadas / segundos}%.0f por segundo)")
    println(f"  RSS total          : ${fmt(rssFinal)}%s")
    println(f"  RSS acima da base  : ${fmt(rssFinal - rss0)}%s")
    println(f"  heap acima da base : ${fmt(heapFinal - heap0)}%s")

    if criadas > 0 then
      println(f"  **RSS por unidade  : ${(rssFinal - rss0) / criadas} bytes**")
      println(f"  heap por unidade   : ${(heapFinal - heap0) / criadas} bytes")

      if !virtuais then
        val reservado = criadas * tamanhoPilhaPlataforma
        println(
          f"  reservado em pilhas: ${fmt(reservado)}%s ($criadas x ${fmt(tamanhoPilhaPlataforma)}%s)"
        )
        println(
          f"  razao reserv/RSS   : ${reservado.toDouble / math.max(1, rssFinal - rss0)}%.1fx"
        )
        println("""
  O reservado e MUITO maior que o RSS porque a pilha de 1 MiB e mapeada
  preguicosamente: a thread bloqueada toca poucas paginas. O RSS e o numero
  comparavel ao da BEAM; o reservado e o que esgota o espaco de enderecamento
  e o limite de threads do sistema antes de a memoria acabar.""")

    falhou.foreach { m =>
      println(s"\n  PAROU: $m")
      println(s"  (o alvo era $alvo; chegou a $criadas)")
    }

    // Nao faz join: as threads bloqueiam para sempre de proposito. Sair aqui
    // mata o processo, e e isso que queremos -- o objetivo era medir o custo de
    // mante-las vivas, nao encerra-las com elegancia.
    println("\n  (encerrando; as threads bloqueadas morrem com o processo)")
    System.exit(0)
