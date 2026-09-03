import '../core/journal.dart';
import 'fake_server.dart';
import 'ledger.dart';

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
  required List<List<JournalEntry>> journals,
  List<String>? sendOrder,
  bool strictOrder = true,
}) {
  final violations = <String>[];
  final ledger = server.ledger;
  // A união de todos os journals: um cenário pode ter mais de um storage —
  // dois aparelhos, ou o mesmo app depois de reinstalado.
  final journal = [for (final one in journals) ...one];

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
    //
    // Verificada contra o **conteúdo recusado**, e não contra a referência: no
    // cenário 7 a referência tem um efeito legítimo, aplicado antes, e o que a
    // invariante quer dizer é que a recusa não moveu dinheiro. Contar efeitos
    // por referência daria falso positivo justamente ali.
    if (entry.state == JournalState.rejected) {
      if (entry.effectId != null) {
        violations.add(
          'externa 3: ${entry.reference} foi rejeitada e mesmo assim tem o '
          'efeito ${entry.effectId} atribuído a ela',
        );
      }
      final refusedAmount = entry.payload['amountInCents'];
      final applied = ledger
          .forReference(entry.reference)
          .where((e) => e.amountInCents == refusedAmount);
      if (applied.isNotEmpty) {
        violations.add(
          'externa 3: ${entry.reference} foi rejeitada com '
          '${refusedAmount}c e existe um efeito no ledger com esse valor '
          '(${applied.first.effectId}) — a recusa sobrescreveu o original',
        );
      }
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

  // Interna 4 — a ordem de saída é a ordem de entrada, por sequência do
  // journal.
  //
  // Verificada em **duas** ordens, e a segunda é a que importa. A primeira
  // versão desta invariante comparava só a ordem em que o cliente *tentou*
  // enviar, e por isso não via o caso real: uma operação que não sai fica para
  // trás enquanto as seguintes são aplicadas. Tentar na ordem certa não é
  // entregar na ordem certa.
  if (sendOrder != null) {
    final attempted = journal.map((e) => e.reference).toList()
      ..removeWhere((r) => !sendOrder.contains(r));
    if (!_sameOrder(attempted, sendOrder)) {
      violations.add(
        'interna 4: a ordem de tentativa não é a ordem do journal — journal '
        '${attempted.join(" → ")}, rede ${sendOrder.join(" → ")}',
      );
    }
  }

  // A ordem dos **efeitos**, que é a que o mundo enxerga.
  //
  // Desligável, e a razão é uma delimitação da promessa e não uma concessão: a
  // ordem global estrita é sobre a **fila** — o que `recover()` drena. Um app
  // que chama `submit` duas vezes em paralelo pediu concorrência, e o pacote
  // não tem como saber qual das duas deveria vir primeiro. É o cenário 4, e a
  // invariante dele é outra: cada desfecho casa com a sua operação. Ordem global estrita
  // significa que uma operação que não saiu segura todas atrás dela: se a #2
  // tem efeito e a #1 não, a promessa foi quebrada, e nenhuma contagem de
  // duplicação percebe isso.
  final sequenceOf = {for (final entry in journal) entry.reference: entry.sequence};
  var previous = 0;
  final effectsInOrder =
      strictOrder ? ledger.entries : const <LedgerEntry>[];
  for (final effect in effectsInOrder) {
    final sequence = sequenceOf[effect.reference];
    if (sequence == null) continue;
    if (sequence < previous) {
      violations.add(
        'interna 4: ${effect.reference} (journal #$sequence) teve efeito '
        'depois de uma operação posterior a ela — a ordem de entrega furou',
      );
    }
    previous = sequence;
  }

  // E o buraco: uma operação sem efeito, com efeito em alguma depois dela.
  final withEffect = ledger.entries.map((e) => e.reference).toSet();
  JournalEntry? blocked;
  for (final entry in strictOrder ? journal : const <JournalEntry>[]) {
    if (entry.state == JournalState.rejected) continue;
    if (!withEffect.contains(entry.reference)) {
      blocked ??= entry;
      continue;
    }
    if (blocked != null) {
      violations.add(
        'interna 4: ${entry.reference} (journal #${entry.sequence}) foi '
        'aplicada enquanto ${blocked.reference} (#${blocked.sequence}) ficou '
        'para trás — ordem global estrita não deixa ninguém furar a fila',
      );
      break;
    }
  }

  // Interna 2, verificável de fora: a sequência do journal é contígua.
  // Por storage: sequências de storages diferentes são numerações diferentes.
  for (final one in journals) {
    for (var i = 0; i < one.length; i++) {
      if (one[i].sequence != i + 1) {
        violations.add(
          'interna 2: sequência do journal com buraco em #${i + 1} '
          '(encontrado #${one[i].sequence})',
        );
      }
    }
  }

  return violations;
}

bool _sameOrder(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
