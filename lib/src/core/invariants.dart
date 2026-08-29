import 'idempotency_key.dart';
import 'journal.dart';

/// Estado impossível, morto onde nasceu.
///
/// É um [Error] e não uma [Exception] de propósito: ninguém deve capturar isto.
/// A resposta certa a uma violação é abortar, não devolver `false` e seguir —
/// senão o defeito aparece vinte passos adiante, quando já não dá para saber
/// quem o criou.
final class InvariantViolation extends Error {
  InvariantViolation(this.invariant, this.detail);

  /// O número da invariante em `docs/TESTING.md`, para o documento e o código
  /// não divergirem.
  final int invariant;
  final String detail;

  @override
  String toString() => 'InvariantViolation(interna $invariant): $detail';
}

/// As invariantes internas, verificadas **dentro** do motor, depois de cada
/// transição — e não no `expect` do fim.
///
/// Um cenário pode terminar com o número certo e ter atravessado um estado
/// impossível no meio; verificar só o resultado final deixa isso passar.
class Invariants {
  Invariants();

  /// Para a medição, que quer observar o dano em vez de abortar no primeiro
  /// sinal dele. **Nunca em teste.**
  factory Invariants.off() = _SilentInvariants;

  final Map<String, IdempotencyKey> _firstKey = {};

  /// **Interna 3** — a chave é estável ao longo das tentativas da mesma
  /// operação.
  ///
  /// A mais valiosa das cinco: ela reprova o defeito na tentativa em que ele
  /// acontece, e não na conta que fecha errada dez passos depois. Do lado de
  /// fora, uma chave que muda é invisível enquanto a rede estiver boa.
  void keyDerived(String reference, IdempotencyKey key, int attemptNumber) {
    final first = _firstKey[reference];
    if (first == null) {
      _firstKey[reference] = key;
      return;
    }
    if (first != key) {
      throw InvariantViolation(
        3,
        'a chave de $reference mudou entre tentativas: $first na primeira, '
        '$key na tentativa $attemptNumber — a identidade da operação virou '
        'função da tentativa, e o servidor vai aplicar o efeito de novo',
      );
    }
  }

  /// **Interna 1** — nada em `enviando` sem registro no journal.
  void interpretingResponse(String reference, JournalEntry? entry) {
    if (entry == null) {
      throw InvariantViolation(
        1,
        'resposta de $reference sendo interpretada sem entrada no journal: a '
        'ordem grava → envia foi invertida',
      );
    }
  }

  /// **Interna 2** — a sequência do journal é contígua.
  ///
  /// Buraco significa gravação perdida; repetição significa duas instâncias
  /// escrevendo.
  void journalIsContiguous(List<JournalEntry> entries) {
    for (var i = 0; i < entries.length; i++) {
      final expected = i + 1;
      if (entries[i].sequence != expected) {
        throw InvariantViolation(
          2,
          'sequência do journal não é contígua: esperado #$expected, '
          'encontrado #${entries[i].sequence}',
        );
      }
    }
  }
}

final class _SilentInvariants extends Invariants {
  _SilentInvariants();

  @override
  void keyDerived(String reference, IdempotencyKey key, int attemptNumber) {}

  @override
  void interpretingResponse(String reference, JournalEntry? entry) {}

  @override
  void journalIsContiguous(List<JournalEntry> entries) {}
}
