package bridge

import (
	"bufio"
	"bytes"
	"encoding/hex"
	"os"
	"strconv"
	"strings"
	"testing"
)

const vetores = "../../protocolo/vetores.txt"

type vetor struct {
	tipo    byte
	id      uint64
	payload []byte
	quadro  []byte
}

// carrega le os vetores compartilhados com Elixir e Gleam.
//
// O arquivo e gerado pelo Elixir, que e a fonte de verdade do formato. Se este
// teste passar e o do Gleam tambem, as tres implementacoes concordam byte a
// byte -- o que nenhum teste de unidade isolado garantiria, porque divergencia
// de formato nao da excecao: da comportamento errado silencioso.
func carrega(t *testing.T) []vetor {
	t.Helper()

	f, err := os.Open(vetores)
	if err != nil {
		t.Fatalf("nao consegui abrir %s: %v", vetores, err)
	}
	defer f.Close()

	var out []vetor
	sc := bufio.NewScanner(f)
	// Os vetores tem uma linha com payload de 300 bytes em hex: o buffer
	// padrao do Scanner (64 KiB) basta, mas deixar explicito evita um erro
	// silencioso se alguem acrescentar um caso grande.
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for sc.Scan() {
		linha := strings.TrimSpace(sc.Text())
		if linha == "" || strings.HasPrefix(linha, "#") {
			continue
		}
		campos := strings.Fields(linha)
		if len(campos) != 4 {
			t.Fatalf("linha com %d campos: %q", len(campos), linha)
		}

		tipo, err := strconv.ParseUint(campos[0], 10, 8)
		if err != nil {
			t.Fatalf("tipo invalido em %q: %v", linha, err)
		}
		id, err := strconv.ParseUint(campos[1], 10, 64)
		if err != nil {
			t.Fatalf("id invalido em %q: %v", linha, err)
		}

		var payload []byte
		if campos[2] != "-" {
			payload, err = hex.DecodeString(campos[2])
			if err != nil {
				t.Fatalf("payload invalido em %q: %v", linha, err)
			}
		}
		quadro, err := hex.DecodeString(campos[3])
		if err != nil {
			t.Fatalf("quadro invalido em %q: %v", linha, err)
		}

		out = append(out, vetor{byte(tipo), id, payload, quadro})
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	return out
}

// Se o arquivo nao for lido, os testes abaixo passariam vacuamente sobre uma
// lista vazia -- que e o jeito mais facil de um teste de conformidade nao
// testar nada.
func TestVetoresForamCarregados(t *testing.T) {
	if n := len(carrega(t)); n != 10 {
		t.Fatalf("esperava 10 vetores, veio %d", n)
	}
}

func TestEncodeBateComOsVetores(t *testing.T) {
	for _, v := range carrega(t) {
		got := Encode(v.tipo, v.id, v.payload)
		if !bytes.Equal(got, v.quadro) {
			t.Errorf("tipo=%d id=%d:\n  gerado  %x\n  esperado %x", v.tipo, v.id, got, v.quadro)
		}
	}
}

func TestDecodeDosVetores(t *testing.T) {
	for _, v := range carrega(t) {
		tipo, id, payload, err := Decode(v.quadro)
		if err != nil {
			t.Errorf("tipo=%d id=%d: %v", v.tipo, v.id, err)
			continue
		}
		if tipo != v.tipo || id != v.id || !bytes.Equal(payload, v.payload) {
			t.Errorf("tipo=%d id=%d: veio tipo=%d id=%d payload=%x", v.tipo, v.id, tipo, id, payload)
		}
	}
}

func TestDecodeRecusaQuadroCurto(t *testing.T) {
	if _, _, _, err := Decode([]byte{1, 2, 3, 4, 5, 6, 7, 8}); err == nil {
		t.Fatal("8 bytes tinham de ser recusados: o cabecalho tem 9")
	}
	if _, _, _, err := Decode(nil); err == nil {
		t.Fatal("quadro vazio tinha de ser recusado")
	}
}

func TestDecodeRecusaTipoDesconhecido(t *testing.T) {
	corpo := Encode(TipoPush, 1, nil)
	corpo[0] = 9
	if _, _, _, err := Decode(corpo); err == nil {
		t.Fatal("tipo 9 tinha de ser recusado")
	}
}

// As fronteiras do campo de 64 bits. Errar o tamanho produz um id diferente do
// que o outro lado enviou, e o sintoma seria "conexao nao encontrada" num
// cliente que existe.
func TestFronteirasDeID(t *testing.T) {
	for _, id := range []uint64{0, 1, 1 << 32, ^uint64(0)} {
		_, got, _, err := Decode(Encode(TipoConnect, id, nil))
		if err != nil {
			t.Fatalf("id=%d: %v", id, err)
		}
		if got != id {
			t.Errorf("id=%d voltou como %d", id, got)
		}
	}
}
