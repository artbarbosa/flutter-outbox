import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 1 de `docs/TESTING.md` — o usuário toca duas vezes no botão.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 1);

  test('cenário 1 — duplo submit da mesma operação', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('os dois submits mandam a mesma chave, e o segundo vira replay',
      () async {
    final run = ScenarioRun(kind: ClientKind.correct, invariantsEnabled: true);
    final transport = run.transport();
    final outbox = run.client(transport: transport);
    final operation = run.transfer('transferencia-1a2b', 15000);

    await Future.wait([outbox.submit(operation), outbox.submit(operation)]);

    final keys = transport.log.map((e) => e.key).toSet();
    expect(keys, hasLength(1), reason: 'a chave é função da intenção');
    expect(transport.sends, 2, reason: 'os dois submits saíram mesmo');
    expect(run.server.ledger.entries, hasLength(1));
  });

  test('a ablação chave-da-tentativa reprova aqui', () async {
    final outcome = await runScenario(scenario, ClientKind.attemptKey);
    expect(outcome.passed, isFalse);
  });
}
