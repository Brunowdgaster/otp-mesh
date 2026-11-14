//// Testes do codec, incluindo a verificação contra os vetores de bytes
//// compartilhados com as implementações em Elixir e em Go.
////
//// A leitura do arquivo usa `@external` para chamar `file:read_file/1` do OTP
//// direto, em vez de trazer uma dependência de I/O. Não é economia de
//// dependência: é a demonstração de que Gleam **é** BEAM — chamar um módulo do
//// OTP não é interoperação, é chamada de função.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import gleeunit
import gleeunit/should
import mesh_codec.{Connect, Data, Disconnect, Push}

pub fn main() {
  gleeunit.main()
}

// --------------------------------------------------------------- ida e volta

pub fn roundtrip_connect_test() {
  Connect(1)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Connect(1)))
}

pub fn roundtrip_disconnect_test() {
  Disconnect(42)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Disconnect(42)))
}

pub fn roundtrip_data_test() {
  Data(7, <<"oi":utf8>>)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Data(7, <<"oi":utf8>>)))
}

pub fn roundtrip_push_test() {
  Push(5, <<"de volta":utf8>>)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Push(5, <<"de volta":utf8>>)))
}

/// 0 e 2^64-1 são as fronteiras do campo de 64 bits. Errar o sinal ou o
/// tamanho aqui produz um id diferente do que o outro lado enviou -- e o
/// sintoma seria "conexão não encontrada" num cliente que existe.
pub fn roundtrip_fronteiras_de_id_test() {
  Connect(0)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Connect(0)))

  Connect(18_446_744_073_709_551_615)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Connect(18_446_744_073_709_551_615)))
}

pub fn payload_binario_cru_test() {
  let payload = <<0, 255, 128, 1>>
  Data(1, payload)
  |> mesh_codec.roundtrip
  |> should.equal(Ok(Data(1, payload)))
}

// ------------------------------------------------------------------- erros

pub fn quadro_curto_e_erro_test() {
  // 8 bytes: um a menos que o cabeçalho. O `Result` obriga quem chama a
  // tratar; do lado Elixir isso é um `case` que alguém pode esquecer.
  <<1, 2, 3, 4, 5, 6, 7, 8>>
  |> mesh_codec.decode
  |> should.equal(Error(mesh_codec.CurtoDemais(8)))
}

pub fn quadro_vazio_e_erro_test() {
  <<>>
  |> mesh_codec.decode
  |> should.equal(Error(mesh_codec.CurtoDemais(0)))
}

pub fn tipo_desconhecido_e_erro_test() {
  <<9:8, 1:big-size(64)>>
  |> mesh_codec.decode
  |> should.equal(Error(mesh_codec.TipoDesconhecido(9)))
}

pub fn erro_tem_mensagem_util_test() {
  mesh_codec.CurtoDemais(3)
  |> mesh_codec.erro_para_string
  |> should.equal("quadro de 3 bytes, menor que o cabecalho de 9")
}

// ------------------------------------------- vetores compartilhados

/// `file:read_file/1` do OTP, chamado direto. Gleam sobre a BEAM chama módulos
/// Erlang como chama os próprios -- sem FFI, sem binding, sem custo.
@external(erlang, "file", "read_file")
fn read_file(caminho: String) -> Result(BitArray, Dynamic)

type Dynamic

type Vetor {
  Vetor(tipo: Int, id: Int, payload: BitArray, quadro: BitArray)
}

fn parse_linha(linha: String) -> Result(Vetor, String) {
  case string.split(string.trim(linha), " ") {
    [t, i, p, q] -> {
      use tipo <- result.try(
        int.parse(t) |> result.replace_error("tipo invalido: " <> t),
      )
      use id <- result.try(
        int.parse(i) |> result.replace_error("id invalido: " <> i),
      )
      let payload = case p {
        "-" -> <<>>
        hex ->
          mesh_codec.from_hex(hex)
          |> result.unwrap(<<>>)
      }
      use quadro <- result.try(
        mesh_codec.from_hex(q) |> result.replace_error("quadro invalido: " <> q),
      )
      Ok(Vetor(tipo, id, payload, quadro))
    }
    _ -> Error("linha com numero de campos inesperado: " <> linha)
  }
}

fn carrega_vetores() -> List(Vetor) {
  let assert Ok(conteudo) = read_file("../../protocolo/vetores.txt")
  let assert Ok(texto) = bit_array.to_string(conteudo)

  texto
  |> string.split("\n")
  |> list.filter(fn(l) {
    let t = string.trim(l)
    t != "" && !string.starts_with(t, "#")
  })
  |> list.map(fn(l) {
    let assert Ok(v) = parse_linha(l)
    v
  })
}

fn vetor_para_frame(v: Vetor) -> Frame {
  case v.tipo {
    1 -> Connect(v.id)
    2 -> Disconnect(v.id)
    3 -> Data(v.id, v.payload)
    _ -> Push(v.id, v.payload)
  }
}

type Frame =
  mesh_codec.Frame

/// Os vetores existem: se o arquivo não for lido, os testes abaixo passariam
/// vacuamente sobre uma lista vazia -- que é o jeito mais fácil de um teste de
/// conformidade não testar nada.
pub fn vetores_foram_carregados_test() {
  carrega_vetores()
  |> list.length
  |> should.equal(10)
}

/// Codificar em Gleam tem de dar **exatamente** os bytes que o Elixir gerou.
pub fn encode_bate_com_os_vetores_test() {
  carrega_vetores()
  |> list.each(fn(v) {
    let frame = vetor_para_frame(v)
    mesh_codec.encode(frame)
    |> mesh_codec.to_hex
    |> should.equal(mesh_codec.to_hex(v.quadro))
  })
}

/// E decodificar os bytes do Elixir tem de reconstruir o quadro certo.
pub fn decode_dos_vetores_test() {
  carrega_vetores()
  |> list.each(fn(v) {
    let assert Ok(frame) = mesh_codec.decode(v.quadro)
    mesh_codec.tipo_de(frame)
    |> should.equal(v.tipo)
    mesh_codec.id_de(frame)
    |> should.equal(v.id)
  })
}
