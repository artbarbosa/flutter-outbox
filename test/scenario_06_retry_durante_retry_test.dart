import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 6 de `docs/TESTING.md` — a janela de background acorda o app
/// enquanto a tela já está aberta.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 6);

  test('cenário 6 — retry durante retry', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('três tentativas perdidas produzem um efeito, não três', () async {
    final run = ScenarioRun(kind: ClientKind.correct, invariantsEnabled: true);
    final transport = run.transport(script: const [
      Fault.responseLost, Fault.offline, //
      Fault.responseLost, Fault.offline, //
      Fault.responseLost, Fault.offline, //
    ]);
    final outbox = run.client(transport: transport);

    await outbox.submit(run.transfer('transferencia-6e7f', 15000));

    expect(transport.sends, 3, reason: 'o orçamento de tentativas foi gasto');
    expect(run.server.ledger.entries, hasLength(1),
        reason: 'os reenvios chegaram com a mesma chave e viraram replay');
  });

  test('a ablação chave-da-tentativa reprova aqui', () async {
    final outcome = await runScenario(scenario, ClientKind.attemptKey);
    expect(outcome.passed, isFalse);
  });
}
