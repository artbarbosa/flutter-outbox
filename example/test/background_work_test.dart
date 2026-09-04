import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outbox_example/background_work.dart';

/// O que a janela de background faz quando o sistema operacional concede uma.
///
/// **Isto não prova que a janela vem.** Prova que, quando ela vem, o app faz a
/// coisa certa e responde ao sistema o que deveria. A outra metade só fecha em
/// aparelho solto — `docs/TESTING.md`, camada 3.
void main() {
  Operation transfer(String reference) => Operation(
        reference: reference,
        payload: const {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': 15000,
        },
      );

  /// Enfileira sem rede, do jeito que o usuário faz no avião.
  Future<(FakeServer, Storage)> withQueue(int quantas) async {
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final storage = InMemoryStorage();
    final offline = Outbox(
      transport: ScriptedTransport(
        server: server,
        script: List.filled(quantas, Fault.offline),
      ),
      storage: storage,
    );
    for (var i = 0; i < quantas; i++) {
      await offline.submit(transfer('pagamento-$i'));
    }
    return (server, storage);
  }

  test('esvaziou a fila → true, e o sistema não reagenda à toa', () async {
    final (server, storage) = await withQueue(3);
    final outbox =
        Outbox(transport: ScriptedTransport(server: server), storage: storage);

    expect(await drainQueue(outbox, storage), isTrue);
    expect(server.ledger.entries, hasLength(3));
    expect(server.ledger.duplications, 0);
  });

  test('sobrou fila → false, que no Android vira Result.retry()', () async {
    final (server, storage) = await withQueue(3);
    // A janela veio, e a rede continua fora.
    final outbox = Outbox(
      transport: ScriptedTransport(
        server: server,
        script: List.filled(5, Fault.offline),
      ),
      storage: storage,
    );

    expect(await drainQueue(outbox, storage), isFalse,
        reason: 'uma fila que não esvaziou não é uma fila perdida');
    expect(server.ledger.entries, isEmpty);
    expect(await storage.unfinished(), hasLength(3),
        reason: 'nada foi descartado');
  });

  test('a ordem sobrevive a uma janela que esvaziou pela metade', () async {
    final (server, storage) = await withQueue(3);
    // Só a primeira consegue sair.
    final transport = ScriptedTransport(
      server: server,
      script: const [Fault.none, Fault.offline],
    );

    expect(
      await drainQueue(Outbox(transport: transport, storage: storage), storage),
      isFalse,
    );
    // Duas **tentativas**: a segunda esbarrou na rede e parou a fila ali. É a
    // ordem de tentativa que este log registra, não a de sucesso.
    expect(transport.referencesInSendOrder, ['pagamento-0', 'pagamento-1']);
    expect(server.ledger.entries.map((e) => e.reference), ['pagamento-0'],
        reason: 'só a primeira chegou ao servidor');

    // A janela seguinte continua de onde parou, na ordem.
    final proxima = ScriptedTransport(server: server);
    expect(
      await drainQueue(Outbox(transport: proxima, storage: storage), storage),
      isTrue,
    );
    expect(proxima.referencesInSendOrder, ['pagamento-1', 'pagamento-2']);
    expect(server.ledger.duplications, 0);
  });

  test('fila vazia → true, sem tocar na rede', () async {
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final storage = InMemoryStorage();
    final transport = ScriptedTransport(server: server);

    expect(
      await drainQueue(Outbox(transport: transport, storage: storage), storage),
      isTrue,
    );
    expect(transport.sends, 0, reason: 'uma janela sem trabalho não custa nada');
  });
}
