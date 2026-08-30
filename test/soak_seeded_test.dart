import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// O soak por seed, e a promessa de reprodutibilidade que o critério de aceite
/// de `PROJECT.md` faz: mesma seed, mesmo resultado, em qualquer máquina.
void main() {
  const lossRates = [0.0, 0.10, 0.25, 0.40, 0.60, 0.80];

  test('a mesma seed produz exatamente o mesmo resultado', () async {
    for (final lossRate in lossRates) {
      final first = await runSoak(
          kind: ClientKind.correct, seed: 7, lossRate: lossRate);
      final again = await runSoak(
          kind: ClientKind.correct, seed: 7, lossRate: lossRate);

      // Incluindo a contagem de tentativas: reprovação que não reproduz não
      // vira cenário, e some na próxima execução.
      expect(again.effects, first.effects);
      expect(again.sends, first.sends, reason: 'a contagem de tentativas mudou');
      expect(again.reconciliations, first.reconciliations);
      expect(again.writes, first.writes);
      expect(again.undetermined, first.undetermined);
    }
  });

  test('o cliente correto nunca duplica, em nenhuma faixa de perda', () async {
    for (final lossRate in lossRates) {
      for (var seed = 1; seed <= 10; seed++) {
        final sample = await runSoak(
            kind: ClientKind.correct, seed: seed, lossRate: lossRate);

        expect(sample.duplications, 0,
            reason: 'seed $seed a ${(lossRate * 100).round()}% de perda');
        expect(sample.sumsUp, isTrue,
            reason: 'a soma do ledger não fechou na seed $seed');
      }
    }
  });

  test('a ablação chave-da-tentativa duplica, e o dano cresce com a perda',
      () async {
    var previous = 0;
    for (final lossRate in [0.25, 0.40, 0.60, 0.80]) {
      var duplications = 0;
      for (var seed = 1; seed <= 10; seed++) {
        duplications += (await runSoak(
                kind: ClientKind.attemptKey, seed: seed, lossRate: lossRate))
            .duplications;
      }
      // Se isto parar de crescer, ou a medição parou de medir, ou o roteiro de
      // falha mudou de forma — e nos dois casos a tabela do README mente.
      expect(duplications, greaterThan(previous),
          reason: 'a ${(lossRate * 100).round()}% de perda');
      previous = duplications;
    }
  });

  test('sem perda nenhuma, os quatro clientes acertam', () async {
    // A linha de 0% existe para provar isto. Sem ela, a tabela parece
    // manipulada.
    for (final kind in ClientKind.values) {
      final sample = await runSoak(kind: kind, seed: 3, lossRate: 0);
      expect(sample.duplications, 0, reason: kind.label);
      expect(sample.effects, 25, reason: kind.label);
    }
  });
}
