import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 7 de `docs/TESTING.md` — a mesma referência de negócio volta com
/// outro valor, de um storage limpo.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 7);

  test('cenário 7 — chave reusada com payload diferente', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('a ablação chave-da-tentativa deixa o conflito invisível', () async {
    final outcome = await runScenario(scenario, ClientKind.attemptKey);

    // A defesa do servidor contra payload divergente **depende de a chave ser
    // estável**. Com uma chave nova a cada tentativa, o servidor nunca vê o
    // conflito, e a proteção que ele oferece fica inacessível.
    expect(outcome.passed, isFalse);
    expect(outcome.violations.join('\n'), contains('em vez de rejeitar'));
  });
}
