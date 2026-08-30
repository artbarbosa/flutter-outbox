import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// Cenário 2 de `docs/TESTING.md` — a primeira fatia vertical.
///
/// Uma operação é enfileirada, o journal grava antes do envio, o envio é feito,
/// **a resposta se perde**, a reconciliação não consegue perguntar, o reenvio
/// sai com a mesma chave e o servidor reconhece. Um efeito no ledger.
void main() {
  /// O roteiro está na tabela de `docs/TESTING.md`, e a ordem é a
  /// especificação: envio com resposta perdida, consulta que não sai do
  /// aparelho, reenvio com a rede boa.
  const script = [Fault.responseLost, Fault.offline, Fault.none];

  const openingBalances = {'conta-a': 100000, 'conta-b': 0};

  Operation transfer() => Operation(
        reference: 'transferencia-8f3a91',
        payload: {'from': 'conta-a', 'to': 'conta-b', 'amountInCents': 15000},
      );

  late FakeServer server;
  late ScriptedTransport transport;

  setUp(() {
    server = FakeServer(openingBalances: openingBalances);
    transport = ScriptedTransport(server: server, script: script);
  });

  group('cenário 2 — timeout, e o servidor teve sucesso', () {
    test('o cliente correto liquida com exatamente um efeito', () async {
      final outbox = buildClient(ClientKind.correct, transport: transport);

      final result = await outbox.submit(transfer());

      expect(result, isA<Settled>());
      expect((result as Settled).effectId, 'effect-1');

      // A invariante específica do cenário: zero duplicação depois de
      // reconciliar.
      expect(server.ledger.entries, hasLength(1));
      expect(server.ledger.duplications, 0);
      expect(server.ledger.balanceOf('conta-a'), 85000);
      expect(server.ledger.balanceOf('conta-b'), 15000);

      expect(
        checkInvariants(server: server, journals: [await outbox.storage.all()]),
        isEmpty,
      );
    });

    test('a chave não muda entre a tentativa perdida e o reenvio', () async {
      final outbox = buildClient(ClientKind.correct, transport: transport);

      await outbox.submit(transfer());

      final sent = transport.log.where((e) => e.kind == 'send').toList();
      expect(sent, hasLength(2), reason: 'houve o envio perdido e o reenvio');
      expect(
        sent.first.key,
        sent.last.key,
        reason: 'é a chave estável que torna o reenvio seguro',
      );
    });

    test('com a rede cooperando, um envio e nenhuma reconciliação', () async {
      final semFalha = ScriptedTransport(server: server);
      final outbox = buildClient(ClientKind.correct, transport: semFalha);

      expect(await outbox.submit(transfer()), isA<Settled>());
      expect(semFalha.sends, 1);
      expect(semFalha.lookups, 0);
      expect(server.ledger.entries, hasLength(1));
    });
  });

  group('e a ablação chave-da-tentativa reprova no mesmo cenário', () {
    test('a interna 3 aborta na tentativa em que o defeito acontece', () async {
      final outbox = buildClient(ClientKind.attemptKey, transport: transport);

      // Não é a conta que fecha errada dez passos depois: é a derivação da
      // segunda chave, no instante em que ela acontece.
      await expectLater(
        outbox.submit(transfer()),
        throwsA(
          isA<InvariantViolation>()
              .having((e) => e.invariant, 'invariante', 3)
              .having((e) => e.detail, 'detalhe', contains('mudou entre tentativas')),
        ),
      );
    });

    test('e com as invariantes desligadas, o dano é a cobrança dobrada',
        () async {
      // É assim que a medição roda: observando o dano em vez de abortar no
      // primeiro sinal dele.
      final outbox = buildClient(
        ClientKind.attemptKey,
        transport: transport,
        invariants: Invariants.off(),
      );

      final result = await outbox.submit(transfer());

      // O cliente acha que deu tudo certo. É esse o problema.
      expect(result, isA<Settled>());
      expect(server.ledger.entries, hasLength(2));
      expect(server.ledger.duplications, 1);
      expect(server.ledger.balanceOf('conta-b'), 30000);

      // E a soma continua batendo: duplicar não cria dinheiro do nada, move
      // dinheiro duas vezes. É por isso que a invariante 4 sozinha não pega
      // isto, e a 1 existe.
      expect(server.ledger.sumsUp, isTrue);

      final violations =
          checkInvariants(server: server, journals: [await outbox.storage.all()]);
      expect(violations, isNotEmpty);
      expect(violations.join('\n'), contains('externa 1'));
      expect(
        violations.join('\n'),
        contains('externa 5'),
        reason: 'o journal ficou com a última chave, e o primeiro efeito virou '
            'órfão',
      );
    });
  });
}
