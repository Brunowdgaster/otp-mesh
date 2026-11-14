// Package ws implementa o mínimo de RFC 6455 (WebSocket) necessário para o
// gateway: aperto de mão, leitura e escrita de quadros, ping/pong e
// fechamento.
//
// # Por que não usar uma biblioteca
//
// `gorilla/websocket` e `coder/websocket` são boas, livres e seriam a escolha
// óbvia num produto. Aqui elas atrapalhariam a medição.
//
// A pergunta deste projeto é "quanto custa uma conexão real, em memória, contra
// os 3,8 KB de um processo BEAM". A resposta é dominada pelo **tamanho dos
// buffers de leitura e escrita** — e numa biblioteca esses buffers são escolha
// dela, não minha. Implementando o protocolo, os buffers ficam explícitos em
// `Conn`, configuráveis, e o número medido passa a ter significado: é o custo
// de *uma decisão de engenharia que eu tomei*, não de um padrão herdado.
//
// Efeito colateral: zero dependências, como no resto do portfólio.
//
// # O que NÃO está implementado
//
// Extensões (`permessage-deflate`), fragmentação com entrelaçamento de
// mensagens de controle no meio de uma sequência de continuação, e validação
// de UTF-8 em quadros de texto. Nenhuma delas afeta a medição; todas estão
// declaradas aqui para que ninguém confunda isto com uma implementação
// completa de RFC 6455.
package ws

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
)

// guid é a constante definida pela RFC 6455 §4.2.2, concatenada à chave do
// cliente antes do SHA-1. Não é segredo nem segurança: serve só para provar
// que o servidor entende o protocolo, e não é um proxy HTTP repetindo bytes.
const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Opcodes da RFC 6455 §5.2.
const (
	OpContinuation byte = 0x0
	OpText         byte = 0x1
	OpBinary       byte = 0x2
	OpClose        byte = 0x8
	OpPing         byte = 0x9
	OpPong         byte = 0xA
)

// Config controla os buffers, que são o que domina o custo de memória por
// conexão. Deixá-los explícitos é o motivo de este pacote existir.
type Config struct {
	ReadBufferSize  int
	WriteBufferSize int
	MaxMessageSize  int64
}

// DefaultConfig usa buffers pequenos de propósito.
//
// 1 KiB de leitura e escrita é bem menos que os 4 KiB que as bibliotecas
// populares usam por padrão. Para um gateway de presença — mensagens curtas e
// muitas conexões — buffer grande é desperdício multiplicado por N, e N aqui é
// a casa das centenas de milhares.
func DefaultConfig() Config {
	return Config{
		ReadBufferSize:  1024,
		WriteBufferSize: 1024,
		MaxMessageSize:  32 * 1024,
	}
}

// Conn é uma conexão WebSocket já estabelecida.
type Conn struct {
	raw  net.Conn
	br   *bufio.Reader
	bw   *bufio.Writer
	cfg  Config
	mask bool // true no cliente: quadros do cliente DEVEM ser mascarados
}

var (
	ErrNotWebSocket  = errors.New("ws: requisicao nao e um upgrade de websocket")
	ErrBadHandshake  = errors.New("ws: aperto de mao recusado")
	ErrMessageTooBig = errors.New("ws: mensagem maior que o maximo configurado")
	ErrClosed        = errors.New("ws: conexao fechada pelo par")
)

// acceptKey calcula o valor de Sec-WebSocket-Accept.
func acceptKey(clientKey string) string {
	h := sha1.New()
	h.Write([]byte(clientKey + guid))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// Upgrade promove uma requisição HTTP a WebSocket, do lado do servidor.
//
// Usa http.Hijacker para assumir o socket cru: a partir daqui o servidor HTTP
// do Go não participa mais, o que também elimina o custo de memória das
// estruturas dele por conexão — relevante quando a conta é por conexão.
func Upgrade(w http.ResponseWriter, r *http.Request, cfg Config) (*Conn, error) {
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") ||
		!strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade") {
		return nil, ErrNotWebSocket
	}
	key := r.Header.Get("Sec-WebSocket-Key")
	if key == "" {
		return nil, ErrNotWebSocket
	}

	hj, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("ws: ResponseWriter nao suporta Hijack")
	}
	raw, _, err := hj.Hijack()
	if err != nil {
		return nil, err
	}

	resp := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + acceptKey(key) + "\r\n\r\n"

	if _, err := raw.Write([]byte(resp)); err != nil {
		raw.Close()
		return nil, err
	}

	return &Conn{
		raw:  raw,
		br:   bufio.NewReaderSize(raw, cfg.ReadBufferSize),
		bw:   bufio.NewWriterSize(raw, cfg.WriteBufferSize),
		cfg:  cfg,
		mask: false,
	}, nil
}

// Dial abre uma conexão WebSocket como cliente. Usado pelo gerador de carga.
func Dial(addr, path string, cfg Config) (*Conn, error) {
	raw, err := net.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}

	var nonce [16]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		raw.Close()
		return nil, err
	}
	key := base64.StdEncoding.EncodeToString(nonce[:])

	req := "GET " + path + " HTTP/1.1\r\n" +
		"Host: " + addr + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: " + key + "\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"

	if _, err := raw.Write([]byte(req)); err != nil {
		raw.Close()
		return nil, err
	}

	br := bufio.NewReaderSize(raw, cfg.ReadBufferSize)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		raw.Close()
		return nil, err
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusSwitchingProtocols {
		raw.Close()
		return nil, fmt.Errorf("%w: status %d", ErrBadHandshake, resp.StatusCode)
	}
	if resp.Header.Get("Sec-WebSocket-Accept") != acceptKey(key) {
		raw.Close()
		return nil, fmt.Errorf("%w: Sec-WebSocket-Accept invalido", ErrBadHandshake)
	}

	return &Conn{
		raw:  raw,
		br:   br,
		bw:   bufio.NewWriterSize(raw, cfg.WriteBufferSize),
		cfg:  cfg,
		mask: true, // RFC 6455 §5.3: o cliente mascara, o servidor nunca
	}, nil
}

// ReadMessage lê uma mensagem completa, remontando quadros de continuação.
//
// Responde automaticamente a Ping com Pong e devolve ErrClosed em Close, para
// que quem chama lide só com mensagens de dados.
func (c *Conn) ReadMessage() (opcode byte, payload []byte, err error) {
	var acc []byte
	var firstOp byte
	var total int64

	for {
		fin, op, data, err := c.readFrame()
		if err != nil {
			return 0, nil, err
		}

		switch op {
		case OpPing:
			if err := c.writeFrame(OpPong, data); err != nil {
				return 0, nil, err
			}
			continue
		case OpPong:
			continue
		case OpClose:
			return 0, nil, ErrClosed
		}

		total += int64(len(data))
		if total > c.cfg.MaxMessageSize {
			return 0, nil, ErrMessageTooBig
		}

		if op != OpContinuation {
			firstOp = op
			acc = data
		} else {
			acc = append(acc, data...)
		}

		if fin {
			return firstOp, acc, nil
		}
	}
}

// readFrame lê um único quadro, já desmascarado.
func (c *Conn) readFrame() (fin bool, opcode byte, payload []byte, err error) {
	var h [2]byte
	if _, err := io.ReadFull(c.br, h[:]); err != nil {
		return false, 0, nil, err
	}

	fin = h[0]&0x80 != 0
	opcode = h[0] & 0x0F
	masked := h[1]&0x80 != 0
	length := int64(h[1] & 0x7F)

	switch length {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(c.br, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = int64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(c.br, ext[:]); err != nil {
			return false, 0, nil, err
		}
		length = int64(binary.BigEndian.Uint64(ext[:]))
	}

	if length > c.cfg.MaxMessageSize {
		return false, 0, nil, ErrMessageTooBig
	}

	var maskKey [4]byte
	if masked {
		if _, err := io.ReadFull(c.br, maskKey[:]); err != nil {
			return false, 0, nil, err
		}
	}

	payload = make([]byte, length)
	if _, err := io.ReadFull(c.br, payload); err != nil {
		return false, 0, nil, err
	}

	if masked {
		for i := range payload {
			payload[i] ^= maskKey[i%4]
		}
	}

	return fin, opcode, payload, nil
}

// WriteMessage envia uma mensagem num único quadro.
func (c *Conn) WriteMessage(opcode byte, payload []byte) error {
	return c.writeFrame(opcode, payload)
}

func (c *Conn) writeFrame(opcode byte, payload []byte) error {
	if err := c.bw.WriteByte(0x80 | opcode); err != nil { // FIN = 1
		return err
	}

	n := len(payload)
	maskBit := byte(0)
	if c.mask {
		maskBit = 0x80
	}

	switch {
	case n < 126:
		if err := c.bw.WriteByte(maskBit | byte(n)); err != nil {
			return err
		}
	case n <= 0xFFFF:
		if err := c.bw.WriteByte(maskBit | 126); err != nil {
			return err
		}
		var ext [2]byte
		binary.BigEndian.PutUint16(ext[:], uint16(n))
		if _, err := c.bw.Write(ext[:]); err != nil {
			return err
		}
	default:
		if err := c.bw.WriteByte(maskBit | 127); err != nil {
			return err
		}
		var ext [8]byte
		binary.BigEndian.PutUint64(ext[:], uint64(n))
		if _, err := c.bw.Write(ext[:]); err != nil {
			return err
		}
	}

	if c.mask {
		var key [4]byte
		if _, err := rand.Read(key[:]); err != nil {
			return err
		}
		if _, err := c.bw.Write(key[:]); err != nil {
			return err
		}
		// Mascara numa cópia: alterar o payload de quem chamou seria um efeito
		// colateral invisível e um bug esperando acontecer.
		masked := make([]byte, n)
		for i := range payload {
			masked[i] = payload[i] ^ key[i%4]
		}
		if _, err := c.bw.Write(masked); err != nil {
			return err
		}
	} else if n > 0 {
		if _, err := c.bw.Write(payload); err != nil {
			return err
		}
	}

	return c.bw.Flush()
}

// Ping envia um quadro de ping.
func (c *Conn) Ping() error { return c.writeFrame(OpPing, nil) }

// Close envia o quadro de fechamento e fecha o socket.
func (c *Conn) Close() error {
	_ = c.writeFrame(OpClose, nil)
	return c.raw.Close()
}

// RemoteAddr expõe o endereço do par, para registro.
func (c *Conn) RemoteAddr() net.Addr { return c.raw.RemoteAddr() }
