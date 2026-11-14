// Módulo sem nenhuma dependência externa.
//
// O WebSocket é implementado em ws/ porque a medição deste projeto é dominada
// pelo tamanho dos buffers por conexão, e numa biblioteca esses buffers são
// escolha dela. Ver o comentário de pacote em ws/ws.go.
module otpmesh

go 1.24
