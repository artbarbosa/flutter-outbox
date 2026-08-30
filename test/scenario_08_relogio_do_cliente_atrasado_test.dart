import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 8 de `docs/TESTING.md` — o mais sutil: a chave expira no servidor, e
/// o cliente não sabe que horas são.
void main() {
  final scenario = layer1Scenarios.firstWhere((s) => s.number == 8);

  test('cenário 8 — relógio do cliente atrasado', () async {
    final outcome = await runScenario(scenario, ClientKind.correct);
    expect(outcome.passed, isTrue, reason: '$outcome');
  });

  test('a reconciliação termina no ledger, e o ledger não expira', () async {
    final run = ScenarioRun(kind: ClientKind.correct, invariantsEnabled: true);
    final transport = run.transport(
      script: const [Fault.responseLost, Fault.keysExpired],
    );
    final outbox = run.client(transport: transport);

    await outbox.submit(run.transfer('transferencia-8i9j', 15000));

    final asked = transport.log.map((e) => e.kind).toList();
    expect(asked, containsAllInOrder(['lookupByKey', 'lookupByReference']),
        reason: 'a chave não foi reconhecida, e o degrau de baixo respondeu');
    expect(run.server.ledger.entries, hasLength(1));
  });

  test('a ablação reenvia-na-expiracao cobra duas vezes', () async {
    final outcome = await runScenario(scenario, ClientKind.resendOnExpiry);

    expect(outcome.passed, isFalse);
    expect(outcome.violations.join('\n'), contains('externa 1'));
  });
}
