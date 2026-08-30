import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 5 de `docs/TESTING.md` — três operações sem rede nenhuma.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 5);

  test('cenário 5 — partição com fila offline', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('nenhuma ablação reprova aqui, e isso é informação', () async {
    // A fila e a ordem não dependem de nenhuma das três decisões. Um cenário
    // em que todos passam não é um cenário fraco: é a delimitação do que cada
    // decisão sustenta.
    for (final kind in ClientKind.values) {
      final outcome = await runScenario(scenario, kind);
      expect(outcome.passed, isTrue, reason: '${kind.label}: $outcome');
    }
  });
}
