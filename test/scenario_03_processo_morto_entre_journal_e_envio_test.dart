import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 3 de `docs/TESTING.md` — o sistema operacional encerra o app entre
/// a gravação e o envio.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 3);

  test('cenário 3 — processo morto entre journal e envio', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('a ablação envia-antes-de-grava perde a operação inteira', () async {
    final outcome = await runScenario(scenario, ClientKind.sendBeforeJournal);

    expect(outcome.passed, isFalse);
    // O dano aqui não é duplicar: é a operação **sumir**. O app acha que
    // enfileirou, e não há registro nenhum para retomar.
    expect(outcome.violations.join('\n'), contains('a operação sumiu'));
  });
}
