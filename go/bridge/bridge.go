// Package bridge fala com o núcleo em Elixir por TCP.
//
// O enquadramento é um prefixo de tamanho de 32 bits big-endian, que é
// exatamente o que a opção `packet: 4` do `inet` da BEAM consome e produz. Do
// lado Elixir ninguém escreve máquina de estado para "li metade de um quadro":
// a VM entrega quadros inteiros. Deste lado, o prefixo é escrito à mão — são
// quatro bytes, e trazer uma biblioteca para isso seria desproporcional.
//
// O protocolo está documentado em elixir/mesh/lib/mesh/bridge.ex, que é a
// fonte de verdade. Divergir dele é o tipo de erro que não dá exceção: dá
// comportamento errado silencioso, e é por isso que existe um teste de ponta a
// ponta atravessando as duas linguagens.
package bridge

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// Tipos de quadro. Têm de bater com Mesh.Bridge.
const (
	TipoConnect    byte = 1
	TipoDisconnect byte = 2
	TipoData       byte = 3
	TipoPush       byte = 4
)

// MaxQuadro limita o que aceitamos ler. Sem limite, um prefixo de tamanho
// corrompido faria o gateway alocar gigabytes a pedido de quem está do outro
// lado -- que é uma negação de serviço acidental à espera de acontecer.
const MaxQuadro = 1 << 20

// Conn é a ligação com o núcleo.
type Conn struct {
	mu   sync.Mutex // serializa escritas: vários clientes compartilham o socket
	raw  net.Conn
	push func(clientID uint64, payload []byte)
}

var ErrQuadroGrande = errors.New("bridge: quadro acima do maximo")

// Dial conecta ao núcleo. `onPush` é chamado quando o núcleo manda entregar
// algo a um cliente; pode ser nil se o gateway não suporta o caminho de volta.
func Dial(addr string, onPush func(clientID uint64, payload []byte)) (*Conn, error) {
	raw, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return nil, err
	}
	c := &Conn{raw: raw, push: onPush}
	if onPush != nil {
		go c.lerLoop()
	}
	return c, nil
}

func (c *Conn) enviar(tipo byte, clientID uint64, payload []byte) error {
	// 1 byte de tipo + 8 de id + payload, prefixado pelo tamanho.
	corpo := make([]byte, 9+len(payload))
	corpo[0] = tipo
	binary.BigEndian.PutUint64(corpo[1:9], clientID)
	copy(corpo[9:], payload)

	var cab [4]byte
	binary.BigEndian.PutUint32(cab[:], uint32(len(corpo)))

	c.mu.Lock()
	defer c.mu.Unlock()
	if _, err := c.raw.Write(cab[:]); err != nil {
		return err
	}
	_, err := c.raw.Write(corpo)
	return err
}

// Connect avisa o núcleo que um cliente abriu WebSocket.
func (c *Conn) Connect(clientID uint64) error {
	return c.enviar(TipoConnect, clientID, nil)
}

// Disconnect avisa que fechou.
func (c *Conn) Disconnect(clientID uint64) error {
	return c.enviar(TipoDisconnect, clientID, nil)
}

// Data encaminha uma mensagem do cliente.
func (c *Conn) Data(clientID uint64, payload []byte) error {
	return c.enviar(TipoData, clientID, payload)
}

// Close encerra a ligação.
func (c *Conn) Close() error { return c.raw.Close() }

// lerLoop consome os PUSH vindos do núcleo.
func (c *Conn) lerLoop() {
	for {
		tipo, id, payload, err := c.lerQuadro()
		if err != nil {
			return
		}
		if tipo == TipoPush && c.push != nil {
			c.push(id, payload)
		}
	}
}

func (c *Conn) lerQuadro() (tipo byte, clientID uint64, payload []byte, err error) {
	var cab [4]byte
	if _, err := io.ReadFull(c.raw, cab[:]); err != nil {
		return 0, 0, nil, err
	}
	n := binary.BigEndian.Uint32(cab[:])
	if n > MaxQuadro {
		return 0, 0, nil, fmt.Errorf("%w: %d bytes", ErrQuadroGrande, n)
	}
	if n < 9 {
		return 0, 0, nil, errors.New("bridge: quadro menor que o cabecalho")
	}
	corpo := make([]byte, n)
	if _, err := io.ReadFull(c.raw, corpo); err != nil {
		return 0, 0, nil, err
	}
	return corpo[0], binary.BigEndian.Uint64(corpo[1:9]), corpo[9:], nil
}
