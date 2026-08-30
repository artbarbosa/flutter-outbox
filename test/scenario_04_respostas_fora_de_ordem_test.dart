import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 4 de `docs/TESTING.md` — as respostas voltam de trás para frente.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 4);

  test('cenário 4 — respostas fora de ordem', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('a ablação envia-antes-de-grava embaralha a ordem do journal', () async {
    final outcome = await runScenario(scenario, ClientKind.sendBeforeJournal);

    // Gravar depois de enviar faz o journal registrar na ordem em que a **rede
    // respondeu**, e não na ordem em que o app pediu. A ordem de enfileiramento
    // se perde sem ninguém duplicar nada.
    expect(outcome.passed, isFalse);
    expect(outcome.violations.join('\n'), contains('interna 4'));
  });
}
