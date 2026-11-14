// Gateway WebSocket.
//
// Aceita conexões, mantém uma goroutine por conexão e expõe `/stats` com os
// números que interessam ao projeto: quantas conexões estão de pé e quanta
// memória elas custam.
//
// # O que este programa existe para medir
//
// O núcleo em Elixir mediu 3,8 KB por conexão — mas aquelas conexões são
// processos BEAM, sem socket. Um socket de verdade acrescenta:
//
//   - a pilha da goroutine (8 KiB mínimo no Go, cresce conforme precisa);
//   - os buffers de leitura e escrita (1 KiB cada aqui, explícitos em ws.Config);
//   - as estruturas do runtime por descritor de arquivo;
//   - **os buffers de socket no kernel**, que não aparecem em nenhuma métrica
//     do processo — nem no heap do Go, nem no RSS.
//
// O último item é o que torna a comparação honesta difícil, e está declarado
// em `/stats` e no README.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"otpmesh/bridge"
	"otpmesh/ws"
)

type registry struct {
	mu    sync.RWMutex
	conns map[uint64]*ws.Conn
	next  uint64

	// Contadores atômicos: lidos pelo /stats a qualquer momento, sem travar o
	// caminho das conexões.
	opened   atomic.Uint64
	closed   atomic.Uint64
	received atomic.Uint64
	sent     atomic.Uint64

	// Ponte com o núcleo em Elixir. Pode ser nil: o gateway funciona sozinho,
	// e é assim que ele foi medido antes de a ponte existir.
	core atomic.Pointer[bridge.Conn]
}

// byID permite ao PUSH do núcleo achar a conexão de destino.
func (r *registry) byID(id uint64) *ws.Conn {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.conns[id]
}

func newRegistry() *registry {
	return &registry{conns: make(map[uint64]*ws.Conn)}
}

func (r *registry) add(c *ws.Conn) uint64 {
	r.mu.Lock()
	r.next++
	id := r.next
	r.conns[id] = c
	r.mu.Unlock()
	r.opened.Add(1)
	return id
}

func (r *registry) remove(id uint64) {
	r.mu.Lock()
	delete(r.conns, id)
	r.mu.Unlock()
	r.closed.Add(1)
}

func (r *registry) count() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.conns)
}

// broadcast envia a todas as conexões, em paralelo.
//
// O equivalente em Elixir é `Mesh.broadcast/1`, e a comparação entre os dois é
// um dos resultados do projeto. Aqui o paralelismo é explícito: um pool de
// goroutines sobre a lista de conexões, porque Go não tem nada como o
// `Registry.dispatch` particionado da BEAM.
func (r *registry) broadcast(payload []byte, workers int) int {
	r.mu.RLock()
	targets := make([]*ws.Conn, 0, len(r.conns))
	for _, c := range r.conns {
		targets = append(targets, c)
	}
	r.mu.RUnlock()

	if workers < 1 {
		workers = 1
	}

	var wg sync.WaitGroup
	chunk := (len(targets) + workers - 1) / workers
	if chunk < 1 {
		chunk = 1
	}

	for start := 0; start < len(targets); start += chunk {
		end := start + chunk
		if end > len(targets) {
			end = len(targets)
		}
		wg.Add(1)
		go func(batch []*ws.Conn) {
			defer wg.Done()
			for _, c := range batch {
				// Erro aqui significa conexão morta; a goroutine dela vai
				// detectar e se remover. Ignorar é correto, contabilizar não
				// seria barato o suficiente no caminho quente.
				_ = c.WriteMessage(ws.OpText, payload)
			}
		}(targets[start:end])
	}

	wg.Wait()
	r.sent.Add(uint64(len(targets)))
	return len(targets)
}

// rssBytes lê o RSS do processo em /proc/self/statm.
//
// Go não expõe RSS: `runtime.MemStats` conta o heap que o runtime gerencia, e
// deixa de fora pilhas de goroutine liberadas ao SO, mmaps e o próprio binário.
// Para "quanto este processo custa de verdade", RSS é a medida mais próxima —
// e ainda assim não inclui os buffers de socket do kernel.
func rssBytes() uint64 {
	data, err := os.ReadFile("/proc/self/statm")
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(data))
	if len(fields) < 2 {
		return 0
	}
	pages, err := strconv.ParseUint(fields[1], 10, 64)
	if err != nil {
		return 0
	}
	return pages * uint64(os.Getpagesize())
}

type stats struct {
	Conexoes        int    `json:"conexoes"`
	Abertas         uint64 `json:"abertas_total"`
	Fechadas        uint64 `json:"fechadas_total"`
	Recebidas       uint64 `json:"mensagens_recebidas"`
	Enviadas        uint64 `json:"mensagens_enviadas"`
	Goroutines      int    `json:"goroutines"`
	HeapAllocBytes  uint64 `json:"heap_alloc_bytes"`
	StackInuseBytes uint64 `json:"stack_inuse_bytes"`
	RSSBytes        uint64 `json:"rss_bytes"`
	BytesPorConexao uint64 `json:"bytes_por_conexao_rss"`
	NucleoLigado    bool   `json:"nucleo_ligado"`
	Aviso           string `json:"aviso"`
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8080", "endereco de escuta")
	readBuf := flag.Int("read-buf", 1024, "buffer de leitura por conexao, em bytes")
	writeBuf := flag.Int("write-buf", 1024, "buffer de escrita por conexao, em bytes")
	quiet := flag.Bool("quiet", false, "nao registra cada conexao")
	coreAddr := flag.String("core", "", "endereco da ponte com o nucleo em Elixir (vazio = sem nucleo)")
	flag.Parse()

	cfg := ws.DefaultConfig()
	cfg.ReadBufferSize = *readBuf
	cfg.WriteBufferSize = *writeBuf

	reg := newRegistry()
	baseRSS := rssBytes()

	if *coreAddr != "" {
		// O PUSH vem do núcleo e vai para o WebSocket do cliente. É o caminho
		// de volta, o que torna a ponte bidirecional em vez de só telemetria.
		conn, err := bridge.Dial(*coreAddr, func(clientID uint64, payload []byte) {
			if c := reg.byID(clientID); c != nil {
				_ = c.WriteMessage(ws.OpText, payload)
				reg.sent.Add(1)
			}
		})
		if err != nil {
			// Falhar alto: quem passou -core quer o núcleo. Subir sem ele e
			// seguir em silêncio seria a sexta ocorrência do modo de falha que
			// este projeto já tratou cinco vezes.
			log.Fatalf("nao consegui conectar ao nucleo em %s: %v", *coreAddr, err)
		}
		reg.core.Store(conn)
		log.Printf("ponte com o nucleo em %s", *coreAddr)
	}

	mux := http.NewServeMux()

	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		c, err := ws.Upgrade(w, r, cfg)
		if err != nil {
			if !*quiet {
				log.Printf("upgrade falhou: %v", err)
			}
			return
		}
		id := reg.add(c)
		if core := reg.core.Load(); core != nil {
			// Erro aqui não derruba o cliente: o gateway continua servindo
			// WebSocket sem o núcleo. Degradar é melhor que recusar, e o
			// /stats mostra `nucleo_ligado: false` para que a degradação seja
			// visível em vez de silenciosa.
			_ = core.Connect(id)
		}

		// Uma goroutine por conexão. É o modelo que o projeto quer comparar
		// com um processo BEAM por conexão.
		go func() {
			defer func() {
				if core := reg.core.Load(); core != nil {
					_ = core.Disconnect(id)
				}
				reg.remove(id)
				_ = c.Close()
			}()
			for {
				op, payload, err := c.ReadMessage()
				if err != nil {
					return
				}
				reg.received.Add(1)
				if core := reg.core.Load(); core != nil {
					_ = core.Data(id, payload)
				}
				// Eco: a carga do projeto é presença, não transformação.
				if op == ws.OpText || op == ws.OpBinary {
					if err := c.WriteMessage(op, payload); err != nil {
						return
					}
					reg.sent.Add(1)
				}
			}
		}()
	})

	mux.HandleFunc("/stats", func(w http.ResponseWriter, r *http.Request) {
		var ms runtime.MemStats
		runtime.ReadMemStats(&ms)

		rss := rssBytes()
		n := reg.count()
		var porConn uint64
		if n > 0 && rss > baseRSS {
			porConn = (rss - baseRSS) / uint64(n)
		}

		s := stats{
			Conexoes:        n,
			Abertas:         reg.opened.Load(),
			Fechadas:        reg.closed.Load(),
			Recebidas:       reg.received.Load(),
			Enviadas:        reg.sent.Load(),
			Goroutines:      runtime.NumGoroutine(),
			HeapAllocBytes:  ms.HeapAlloc,
			StackInuseBytes: ms.StackInuse,
			NucleoLigado:    reg.core.Load() != nil,
			RSSBytes:        rss,
			BytesPorConexao: porConn,
			Aviso: "bytes_por_conexao_rss NAO inclui os buffers de socket do kernel, " +
				"que ficam fora do RSS do processo",
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(s)
	})

	mux.HandleFunc("/broadcast", func(w http.ResponseWriter, r *http.Request) {
		workers := runtime.NumCPU()
		if v := r.URL.Query().Get("workers"); v != "" {
			if k, err := strconv.Atoi(v); err == nil && k > 0 {
				workers = k
			}
		}
		msg := r.URL.Query().Get("msg")
		if msg == "" {
			msg = "ping"
		}
		t0 := time.Now()
		n := reg.broadcast([]byte(msg), workers)
		fmt.Fprintf(w, "%d conexoes em %.3f ms com %d workers\n",
			n, float64(time.Since(t0).Microseconds())/1000, workers)
	})

	srv := &http.Server{
		Addr:    *addr,
		Handler: mux,
		// Sem timeout de leitura: as conexões ficam ociosas de propósito, que é
		// o cenário de presença. Um gateway de produção teria ping/pong com
		// prazo, e isso está nos limites conhecidos do README.
	}

	log.Printf("gateway em %s (read-buf=%d write-buf=%d)", *addr, *readBuf, *writeBuf)
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(err)
	}
}
