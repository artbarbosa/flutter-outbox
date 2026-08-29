import '../core/journal.dart';
import 'fake_server.dart';

/// As invariantes que dá para observar **sem abrir o cliente**.
///
/// Verificadas em todos os cenários, e não só nos que parecem relevantes: a
/// razão de existirem é justamente pegar o dano num cenário que ninguém achava
/// que tinha a ver com ele.
///
/// Devolve a lista de violações em vez de lançar. As internas é que abortam —
/// estas aqui são o `expect` do fim, e querem mostrar **todas** as quebras de
/// uma vez em vez de parar na primeira.
List<String> checkInvariants({
  required FakeServer server,
  required List<JournalEntry> journal,
}) {
  final violations = <String>[];
  final ledger = server.ledger;

  // 1 — nenhuma referência de negócio tem mais de um efeito. A global.
  final byReference = <String, List<String>>{};
  for (final entry in ledger.entries) {
    byReference.putIfAbsent(entry.reference, () => []).add(entry.effectId);
  }
  for (final MapEntry(key: reference, value: effects) in byReference.entries) {
    if (effects.length > 1) {
      violations.add(
        'externa 1: $reference tem ${effects.length} efeitos no ledger '
        '(${effects.join(", ")}) — é uma cobrança que aconteceu duas vezes',
      );
    }
  }

  for (final entry in journal) {
    final effects = byReference[entry.reference] ?? const <String>[];

    // 2 — o que o cliente considera liquidado tem exatamente um efeito.
    if (entry.state == JournalState.settled) {
      if (effects.length != 1) {
        violations.add(
          'externa 2: ${entry.reference} está liquidada no journal com '
          '${effects.length} efeitos no ledger',
        );
      } else if (entry.effectId != effects.single) {
        violations.add(
          'externa 2: ${entry.reference} liquidou como ${entry.effectId}, '
          'mas o efeito no ledger é ${effects.single}',
        );
      }
    }

    // 3 — o que foi rejeitado não tem efeito nenhum.
    if (entry.state == JournalState.rejected && effects.isNotEmpty) {
      violations.add(
        'externa 3: ${entry.reference} foi rejeitada e mesmo assim tem '
        '${effects.length} efeito(s) no ledger',
      );
    }
  }

  // 4 — a soma bate: transferência move valor, não cria e não destrói.
  if (!ledger.sumsUp) {
    violations.add('externa 4: a soma do ledger não fecha com a de abertura');
  }

  // 5 — todo efeito é rastreável até a chave que o produziu, e essa chave
  // existe no journal do cliente. Efeito órfão significa que o servidor aplicou
  // algo que o cliente nunca registrou — é assim que a inversão de
  // `grava → envia` aparece quando o processo morre no meio.
  final knownKeys = journal.map((e) => e.key.value).toSet();
  for (final effect in ledger.entries) {
    if (!knownKeys.contains(effect.key.value)) {
      violations.add(
        'externa 5: ${effect.effectId} veio da chave ${effect.key}, que não '
        'existe no journal — efeito órfão',
      );
    }
  }

  // Interna 2, verificável de fora: a sequência do journal é contígua.
  for (var i = 0; i < journal.length; i++) {
    if (journal[i].sequence != i + 1) {
      violations.add(
        'interna 2: sequência do journal com buraco em #${i + 1} '
        '(encontrado #${journal[i].sequence})',
      );
    }
  }

  return violations;
}
