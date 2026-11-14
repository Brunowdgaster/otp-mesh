//// Codificador e decodificador do protocolo da ponte, em Gleam.
////
//// ## Por que uma terceira implementação do mesmo protocolo
////
//// O protocolo já existe em Elixir (`Mesh.Bridge`) e em Go (`bridge`). Esta é
//// a terceira, e o ponto não é redundância — é o que a **tipagem estática
//// sobre a BEAM** muda na forma de escrever a mesma coisa.
////
//// Nas outras duas, um quadro é bytes com uma convenção na cabeça de quem
//// escreveu. Aqui ele é um tipo:
////
//// - não existe `Frame` sem `client_id`, porque o construtor exige;
//// - não existe "esqueci de tratar o tipo 4", porque o `case` sobre `Frame` é
////   verificado por exaustividade pelo compilador;
//// - `decode` devolve `Result`, e **o compilador obriga** a tratar o erro —
////   não há como ignorar um quadro malformado por descuido, que é exatamente
////   o bug que o teste `quadro malformado nao derruba o handler` cobre do lado
////   Elixir em tempo de execução.
////
//// Ou seja: o mesmo erro é pego em tempo de compilação aqui, e por teste lá. É
//// a comparação que o projeto quer, e ela só existe porque as três
//// implementações rodam sobre o mesmo protocolo e são verificadas contra os
//// mesmos vetores de bytes, em `protocolo/vetores.txt`.

import gleam/bit_array
import gleam/int
import gleam/result
import gleam/string

/// Um quadro da ponte. O tipo torna impossível construir um quadro
/// incompleto — o que, nas versões em Elixir e Go, depende de disciplina.
pub type Frame {
  Connect(client_id: Int)
  Disconnect(client_id: Int)
  Data(client_id: Int, payload: BitArray)
  /// Único quadro que vai do núcleo para o gateway.
  Push(client_id: Int, payload: BitArray)
}

/// Por que um tipo de erro em vez de `Nil`: "não deu" é informação inútil
/// quando o outro lado da ponte é um programa em outra linguagem. Saber *qual*
/// invariante quebrou é a diferença entre depurar e adivinhar.
pub type DecodeError {
  /// Menor que o cabeçalho de 9 bytes.
  CurtoDemais(tamanho: Int)
  /// Primeiro byte fora de 1..4.
  TipoDesconhecido(tipo: Int)
}

const tipo_connect = 1

const tipo_disconnect = 2

const tipo_data = 3

const tipo_push = 4

/// Codifica um quadro: 1 byte de tipo, 8 bytes de id big-endian, resto é
/// payload.
///
/// O enquadramento por tamanho **não** entra aqui: do lado Elixir a opção
/// `packet: 4` do `inet` o adiciona na VM, e do lado Go são quatro bytes à mão.
/// Misturar as duas camadas seria duplicar o prefixo.
pub fn encode(frame: Frame) -> BitArray {
  case frame {
    Connect(id) -> <<tipo_connect:8, id:big-size(64)>>
    Disconnect(id) -> <<tipo_disconnect:8, id:big-size(64)>>
    Data(id, payload) -> <<tipo_data:8, id:big-size(64), payload:bits>>
    Push(id, payload) -> <<tipo_push:8, id:big-size(64), payload:bits>>
  }
}

/// Decodifica um quadro já sem o prefixo de tamanho.
pub fn decode(bits: BitArray) -> Result(Frame, DecodeError) {
  case bits {
    <<t:8, id:big-size(64), resto:bits>> ->
      case t {
        1 -> Ok(Connect(id))
        2 -> Ok(Disconnect(id))
        3 -> Ok(Data(id, resto))
        4 -> Ok(Push(id, resto))
        outro -> Error(TipoDesconhecido(outro))
      }
    _ -> Error(CurtoDemais(bit_array.byte_size(bits)))
  }
}

/// Ida e volta, usado pelos testes de propriedade.
pub fn roundtrip(frame: Frame) -> Result(Frame, DecodeError) {
  frame
  |> encode
  |> decode
}

/// Hexadecimal minúsculo, para comparar com os vetores compartilhados.
pub fn to_hex(bits: BitArray) -> String {
  bits
  |> bit_array.base16_encode
  |> string.lowercase
}

/// Converte hexadecimal de volta em bytes.
pub fn from_hex(hex: String) -> Result(BitArray, Nil) {
  hex
  |> string.uppercase
  |> bit_array.base16_decode
  |> result.replace_error(Nil)
}

/// O tipo numérico de um quadro, para checar contra os vetores sem casar sobre
/// o construtor.
pub fn tipo_de(frame: Frame) -> Int {
  case frame {
    Connect(_) -> tipo_connect
    Disconnect(_) -> tipo_disconnect
    Data(_, _) -> tipo_data
    Push(_, _) -> tipo_push
  }
}

/// O id do cliente, qualquer que seja o quadro.
pub fn id_de(frame: Frame) -> Int {
  case frame {
    Connect(id) -> id
    Disconnect(id) -> id
    Data(id, _) -> id
    Push(id, _) -> id
  }
}

/// Descrição legível de um erro de decodificação.
pub fn erro_para_string(erro: DecodeError) -> String {
  case erro {
    CurtoDemais(n) ->
      "quadro de " <> int.to_string(n) <> " bytes, menor que o cabecalho de 9"
    TipoDesconhecido(t) -> "tipo de quadro desconhecido: " <> int.to_string(t)
  }
}
