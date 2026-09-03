import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// A redução da seed que reprovou.
///
/// Sem ela, uma falha de soak com 25 operações é um relatório ilegível, e a
/// regra de `docs/TESTING.md` — "seed que reprovar vira um cenário nomeado" —
/// não tem como ser cumprida.
void main() {
  /// O predicado do domínio: este roteiro ainda faz o cliente duplicar?
  Future<bool> duplicates(ClientKind kind, FailingCase candidate) async {
    final sample = await runSoakScript(
      kind: kind,
      script: candidate.script,
      operations: candidate.operations,
    );
    return sample.duplications > 0;
  }

  test('reduz uma seed de 25 operações a um caso que cabe na cabeça', () async {
    const seed = 4;
    const lossRate = 0.4;
    final original = FailingCase(
      operations: 25,
      script: scriptFor(seed: seed, lossRate: lossRate),
    );

    // A premissa: sem reduzir, o relatório é grande demais para ser lido.
    expect(await duplicates(ClientKind.attemptKey, original), isTrue,
        reason: 'a seed $seed a ${lossRate * 100}% precisa reprovar');
    expect(original.faults, greaterThan(10));

    final reduced = await shrink(
      original,
      (candidate) => duplicates(ClientKind.attemptKey, candidate),
    );

    expect(reduced.operations, lessThan(original.operations));
    expect(reduced.faults, lessThan(original.faults));
    // O ponto inteiro: o caso reduzido continua reprovando.
    expect(await duplicates(ClientKind.attemptKey, reduced), isTrue);

    printOnFailure('original: $original');
    printOnFailure('reduzido: $reduced');
  });

  test('o caso reduzido é mínimo: tirar mais uma falha o faz passar', () async {
    final original = FailingCase(
      operations: 25,
      script: scriptFor(seed: 4, lossRate: 0.4),
    );
    final reduced = await shrink(
      original,
      (candidate) => duplicates(ClientKind.attemptKey, candidate),
    );

    // Se qualquer falha ainda pudesse sair sem o caso deixar de reprovar, a
    // redução parou cedo demais e o relatório continua maior do que precisa.
    for (var i = 0; i < reduced.script.length; i++) {
      if (reduced.script[i] == Fault.none) continue;
      final oneLess = List<Fault>.from(reduced.script)..[i] = Fault.none;
      final candidate = FailingCase(
        operations: reduced.operations,
        script: oneLess,
      );
      expect(await duplicates(ClientKind.attemptKey, candidate), isFalse,
          reason: 'a falha na posição $i não era necessária: $reduced');
    }
  });

  test('reduzir é determinístico: mesma entrada, mesmo caso mínimo', () async {
    final original = FailingCase(
      operations: 25,
      script: scriptFor(seed: 9, lossRate: 0.6),
    );
    StillFails predicate() =>
        (candidate) => duplicates(ClientKind.attemptKey, candidate);

    final first = await shrink(original, predicate());
    final again = await shrink(original, predicate());

    expect(again.operations, first.operations);
    expect(again.script, first.script);
  });

  test('reduzir um caso que passa é um erro, e não um resultado vazio',
      () async {
    // O cliente correto não duplica em roteiro nenhum, então não há o que
    // reduzir. Devolver um "mínimo" aqui seria mentira.
    final passing = FailingCase(
      operations: 25,
      script: scriptFor(seed: 4, lossRate: 0.4),
    );
    expect(
      shrink(passing, (candidate) => duplicates(ClientKind.correct, candidate)),
      throwsArgumentError,
    );
  });
}
