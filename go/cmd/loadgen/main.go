// Gerador de carga: abre N conexões WebSocket e as mantém abertas.
//
// Existe para medir o gateway, e por isso tem uma propriedade importante: ele
// **reporta falhas em vez de desistir em silêncio**. Abrir 50 mil sockets
// esbarra em limite de descritores, em portas efêmeras e em backlog de accept,
// e cada um desses limites falha de um jeito diferente. Um gerador que
// informasse "abri as que deu" tornaria a medição do gateway inútil — é o mesmo
// modo de falha que já apareceu quatro vezes neste portfólio.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"otpmesh/ws"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "endereco do gateway")
	n := flag.Int("n", 1000, "quantas conexoes abrir")
	conc := flag.Int("conc", 64, "quantas aberturas simultaneas")
	hold := flag.Duration("hold", 10*time.Second, "quanto tempo manter abertas")
	readBuf := flag.Int("read-buf", 1024, "buffer de leitura por conexao")
	writeBuf := flag.Int("write-buf", 1024, "buffer de escrita por conexao")
	flag.Parse()

	cfg := ws.DefaultConfig()
	cfg.ReadBufferSize = *readBuf
	cfg.WriteBufferSize = *writeBuf

	var (
		abertas atomic.Int64
		falhas  atomic.Int64
		// Os erros são agrupados por mensagem: 50 mil falhas iguais não devem
		// imprimir 50 mil linhas, mas o motivo tem de aparecer.
		motivosMu sync.Mutex
		motivos   = map[string]int{}
	)

	conns := make([]*ws.Conn, 0, *n)
	var connsMu sync.Mutex

	sem := make(chan struct{}, *conc)
	var wg sync.WaitGroup

	t0 := time.Now()

	for i := 0; i < *n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func() {
			defer wg.Done()
			defer func() { <-sem }()

			c, err := ws.Dial(*addr, "/ws", cfg)
			if err != nil {
				falhas.Add(1)
				motivosMu.Lock()
				motivos[err.Error()]++
				motivosMu.Unlock()
				return
			}
			abertas.Add(1)
			connsMu.Lock()
			conns = append(conns, c)
			connsMu.Unlock()
		}()
	}
	wg.Wait()

	dur := time.Since(t0)
	fmt.Printf("abertas   : %d de %d em %.2f s (%.0f/s)\n",
		abertas.Load(), *n, dur.Seconds(), float64(abertas.Load())/dur.Seconds())

	if f := falhas.Load(); f > 0 {
		fmt.Printf("falhas    : %d\n", f)
		motivosMu.Lock()
		for msg, c := range motivos {
			fmt.Printf("  %6dx %s\n", c, msg)
		}
		motivosMu.Unlock()
		// Falha parcial invalida a medição do gateway: quem chamou pediu N
		// conexões e não recebeu N. Sair com erro é o que faz o script de
		// benchmark parar em vez de publicar um número errado.
		if abertas.Load() < int64(*n) {
			fmt.Fprintf(os.Stderr,
				"loadgen: abri %d de %d conexoes; a medicao do gateway nao vale\n",
				abertas.Load(), *n)
			defer os.Exit(1)
		}
	}

	if *hold > 0 {
		fmt.Printf("mantendo  : %s\n", *hold)
		time.Sleep(*hold)
	}

	for _, c := range conns {
		_ = c.Close()
	}
	log.Printf("fechadas %d conexoes", len(conns))
}
