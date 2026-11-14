//! Codec do protocolo da ponte, como NIF.
//!
//! # O que este NIF existe para medir
//!
//! Não é para acelerar o codec — o trabalho dele é tão pequeno que acelerar
//! não faz sentido. É para **medir o custo de cruzar a fronteira** entre a
//! BEAM e código nativo, que é o número que decide se vale a pena escrever
//! qualquer NIF.
//!
//! A estratégia da medição: fazer o trabalho útil ser desprezível, de modo que
//! o tempo medido seja quase todo travessia. Depois crescer o payload até o
//! trabalho dominar, e procurar o **ponto de cruzamento** — o tamanho a partir
//! do qual o nativo compensa.
//!
//! O resultado, em `bench/nif.exs`: **não existe ponto de cruzamento** nesta
//! carga. O NIF perde de payload vazio até 1 MiB, com a razão assintotando em
//! ~0,95x sem nunca cruzar. Construir um binário concatenando três campos é
//! uma instrução da máquina virtual; não há o que o nativo otimize.
//!
//! A camada de conversão de termos do `rustler` faz parte do custo medido, e
//! isso é deliberado: é o que um projeto real paga.
//!
//! # A regra que não pode ser quebrada
//!
//! Um NIF roda **no escalonador da BEAM**, não numa thread separada. Se ele
//! bloquear por mais de ~1 ms, o escalonador não consegue preemptar e a
//! latência de **todo o nó** sofre — é o jeito mais rápido de jogar fora as
//! propriedades de tempo real da plataforma.
//!
//! As funções aqui são O(n) sobre payloads pequenos e retornam em
//! nanossegundos. Trabalho longo exigiria *dirty schedulers*
//! (`schedule = "DirtyCpu"`), e esta implementação deliberadamente **não** os
//! usa porque não precisa. Quem copiar este código para um caso que precise
//! tem de acrescentá-los.

use rustler::types::atom;
use rustler::{Binary, Encoder, Env, NifResult, OwnedBinary, Term};

const TIPO_CONNECT: u8 = 1;
const TIPO_PUSH: u8 = 4;
const CABECALHO: usize = 9;

/// Codifica um quadro: 1 byte de tipo, 8 bytes de id big-endian, resto é
/// payload.
///
/// Devolve um binário novo, e é aqui que mora a maior parte do custo: o
/// `OwnedBinary` é alocado no heap de binários da BEAM e transferido para o
/// termo de retorno. Medido, isso põe o `encode` em ~230 ns contra ~42 ns de
/// uma função que só soma — a diferença é conversão de termo mais alocação.
#[rustler::nif]
fn encode<'a>(env: Env<'a>, tipo: u8, id: u64, payload: Binary<'a>) -> NifResult<Term<'a>> {
    let total = CABECALHO + payload.len();
    let mut saida = OwnedBinary::new(total).ok_or(rustler::Error::Atom("sem_memoria"))?;

    {
        let bytes = saida.as_mut_slice();
        bytes[0] = tipo;
        bytes[1..9].copy_from_slice(&id.to_be_bytes());
        bytes[9..].copy_from_slice(payload.as_slice());
    }

    Ok(saida.release(env).to_term(env))
}

/// Decodifica um quadro nos seus campos.
///
/// Devolve `{:ok, {tipo, id, payload}}` ou `{:error, motivo}` — a mesma forma
/// que `Mesh.Codec.decode/1`, para que o teste de conformidade compare as duas
/// sem adaptador.
#[rustler::nif]
fn decode<'a>(env: Env<'a>, quadro: Binary<'a>) -> NifResult<Term<'a>> {
    let bytes = quadro.as_slice();

    if bytes.len() < CABECALHO {
        return Ok((atom::error(), "curto_demais").encode(env));
    }

    let tipo = bytes[0];
    if !(TIPO_CONNECT..=TIPO_PUSH).contains(&tipo) {
        return Ok((atom::error(), "tipo_desconhecido").encode(env));
    }

    // `unwrap` seguro: o fatiamento acima já garantiu 9 bytes, e [1..9] tem
    // exatamente os 8 que `from_be_bytes` exige.
    let id = u64::from_be_bytes(bytes[1..9].try_into().unwrap());

    let resto = &bytes[CABECALHO..];
    let mut payload = OwnedBinary::new(resto.len()).ok_or(rustler::Error::Atom("sem_memoria"))?;
    payload.as_mut_slice().copy_from_slice(resto);

    Ok((atom::ok(), (tipo, id, payload.release(env).to_term(env))).encode(env))
}

/// Função mínima: recebe e devolve um inteiro.
///
/// Serve de linha de base da travessia. O trabalho útil é uma soma; tudo o que
/// sobrar no tempo medido é o custo de entrar e sair do nativo. Sem ela, o
/// número do `encode` não teria com o que ser comparado — e a medição diria
/// "Rust é mais lento" em vez de "a travessia custa 30 ns".
#[rustler::nif]
fn travessia_vazia(n: i64) -> i64 {
    n + 1
}

rustler::init!("Elixir.Mesh.Nif");
