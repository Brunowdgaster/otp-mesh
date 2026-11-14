package ws

import (
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// A chave e o hash vêm do exemplo da própria RFC 6455 §1.3. Se este teste
// falhar, o aperto de mão está errado e nenhum cliente real vai conectar --
// independentemente de o resto do código parecer funcionar.
func TestAcceptKeyDaRFC(t *testing.T) {
	const chave = "dGhlIHNhbXBsZSBub25jZQ=="
	const esperado = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

	if got := acceptKey(chave); got != esperado {
		t.Fatalf("acceptKey(%q) = %q, esperado %q", chave, got, esperado)
	}
}

func TestUpgradeRecusaRequisicaoComum(t *testing.T) {
	r := httptest.NewRequest(http.MethodGet, "/ws", nil)
	w := httptest.NewRecorder()

	if _, err := Upgrade(w, r, DefaultConfig()); err != ErrNotWebSocket {
		t.Fatalf("esperava ErrNotWebSocket, veio %v", err)
	}
}

// servidorEco sobe um gateway mínimo e devolve o endereço.
func servidorEco(t *testing.T, cfg Config) string {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		c, err := Upgrade(w, r, cfg)
		if err != nil {
			return
		}
		defer c.Close()
		for {
			op, p, err := c.ReadMessage()
			if err != nil {
				return
			}
			if err := c.WriteMessage(op, p); err != nil {
				return
			}
		}
	})

	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })

	return ln.Addr().String()
}

func TestIdaEVoltaTexto(t *testing.T) {
	addr := servidorEco(t, DefaultConfig())

	c, err := Dial(addr, "/ws", DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	if err := c.WriteMessage(OpText, []byte("ola")); err != nil {
		t.Fatal(err)
	}
	op, p, err := c.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if op != OpText || string(p) != "ola" {
		t.Fatalf("veio op=%d payload=%q", op, p)
	}
}

// Três tamanhos que atravessam as fronteiras de codificação do comprimento na
// RFC 6455: menos de 126 cabe no próprio byte, até 0xFFFF usa extensão de 2
// bytes, e acima disso usa 8. Errar a fronteira é o bug clássico de
// implementação de framing, e não aparece em teste com payload pequeno.
func TestFronteirasDeComprimento(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxMessageSize = 256 * 1024
	addr := servidorEco(t, cfg)

	c, err := Dial(addr, "/ws", cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	for _, n := range []int{0, 1, 125, 126, 127, 65535, 65536, 70000} {
		payload := strings.Repeat("x", n)
		if err := c.WriteMessage(OpBinary, []byte(payload)); err != nil {
			t.Fatalf("n=%d: write: %v", n, err)
		}
		_, p, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("n=%d: read: %v", n, err)
		}
		if len(p) != n {
			t.Fatalf("n=%d: voltaram %d bytes", n, len(p))
		}
	}
}

func TestMensagemAcimaDoMaximoEhRecusada(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxMessageSize = 1024
	addr := servidorEco(t, cfg)

	// O cliente usa limite maior para conseguir ENVIAR o que o servidor deve
	// recusar: o teste é do servidor, não do cliente.
	cliCfg := DefaultConfig()
	cliCfg.MaxMessageSize = 1 << 20

	c, err := Dial(addr, "/ws", cliCfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	if err := c.WriteMessage(OpBinary, make([]byte, 4096)); err != nil {
		t.Fatal(err)
	}
	// O servidor derruba a conexão ao exceder o máximo; o cliente percebe na
	// leitura seguinte.
	_ = c.raw.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := c.ReadMessage(); err == nil {
		t.Fatal("esperava erro: o servidor devia ter recusado a mensagem")
	}
}

// Ping tem de ser respondido com Pong automaticamente, sem envolver quem
// chamou ReadMessage.
func TestPingRespondeAutomaticamente(t *testing.T) {
	addr := servidorEco(t, DefaultConfig())

	c, err := Dial(addr, "/ws", DefaultConfig())
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()

	if err := c.Ping(); err != nil {
		t.Fatal(err)
	}
	// Se o servidor respondeu o ping com pong, ReadMessage o consome em
	// silêncio e a mensagem seguinte chega normalmente.
	if err := c.WriteMessage(OpText, []byte("depois-do-ping")); err != nil {
		t.Fatal(err)
	}
	_ = c.raw.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, p, err := c.ReadMessage()
	if err != nil {
		t.Fatal(err)
	}
	if string(p) != "depois-do-ping" {
		t.Fatalf("veio %q", p)
	}
}

// Quadro de cliente sem máscara viola a RFC 6455 §5.3. O servidor não valida
// isso hoje, e o teste existe para registrar a lacuna em vez de deixá-la
// implícita -- é o tipo de coisa que um fuzzer de protocolo encontraria.
func TestServidorAindaNaoExigeMascara(t *testing.T) {
	addr := servidorEco(t, DefaultConfig())

	raw, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	defer raw.Close()

	req := "GET /ws HTTP/1.1\r\nHost: " + addr + "\r\n" +
		"Upgrade: websocket\r\nConnection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"
	if _, err := raw.Write([]byte(req)); err != nil {
		t.Fatal(err)
	}

	buf := make([]byte, 256)
	_ = raw.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := raw.Read(buf); err != nil {
		t.Fatal(err)
	}

	// Quadro de texto "oi" SEM bit de máscara.
	if _, err := raw.Write([]byte{0x81, 0x02, 'o', 'i'}); err != nil {
		t.Fatal(err)
	}

	_ = raw.SetReadDeadline(time.Now().Add(2 * time.Second))
	n, err := raw.Read(buf)
	if err != nil {
		t.Skipf("servidor fechou a conexao (comportamento conforme a RFC): %v", err)
	}
	// Documenta o que o servidor faz hoje: aceita e ecoa.
	t.Logf("servidor aceitou quadro sem mascara e respondeu %d bytes — lacuna conhecida", n)
}
