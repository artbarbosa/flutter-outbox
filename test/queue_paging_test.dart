import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'support/sqlite_fixture.dart';

/// A fila lida por página, e a ordem atravessando as páginas.
///
/// `docs/PITFALLS.md`: "Ler a fila inteira na memória funciona com três
/// operações e falha com três mil." Três mil é caro de testar; 200 com página
/// de 50 já exercita quatro voltas do cursor, que é onde os defeitos moram.
void main() {
  setUpAll(sqfliteFfiInit);

  const total = 200;
  const pageSize = 50;

  List<String> references() => [
        for (var i = 0; i < total; i++) 'pagamento-${i.toString().padLeft(3, '0')}',
      ];

  Operation transfer(String reference) => Operation(
        reference: reference,
        payload: {'from': 'conta-a', 'to': 'conta-b', 'amountInCents': 100},
      );

  Future<void> enqueueAll(Storage storage, FakeServer server,
      AttemptNonces nonces) async {
    final offline = buildClient(
      ClientKind.correct,
      transport: ScriptedTransport(
        server: server,
        script: List.filled(total * 2, Fault.offline),
      ),
      storage: storage,
      nonces: nonces,
      pageSize: pageSize,
    );
    for (final reference in references()) {
      await offline.submit(transfer(reference));
    }
  }

  for (final (name, open) in <(String, Future<Storage> Function())>[
    ('em memória', () async => InMemoryStorage()),
    ('em SQLite', openTestStorage),
  ]) {
    group('storage $name', () {
      test('$total operações saem na ordem, atravessando as páginas', () async {
        final storage = await open();
        final server =
            FakeServer(openingBalances: const {'conta-a': 100000000});
        final nonces = AttemptNonces();
        await enqueueAll(storage, server, nonces);

        final transport = ScriptedTransport(server: server);
        await buildClient(
          ClientKind.correct,
          transport: transport,
          storage: storage,
          nonces: nonces,
          pageSize: pageSize,
        ).recover();

        expect(transport.referencesInSendOrder, references(),
            reason: 'a ordem precisa sobreviver à virada de página');
        expect(server.ledger.entries, hasLength(total));
        expect(server.ledger.duplications, 0);
        expect(
          checkInvariants(
            server: server,
            journals: [await storage.all()],
            sendOrder: transport.referencesInSendOrder,
          ),
          isEmpty,
        );
      });

      test('a página é do tamanho pedido, e o cursor não pula ninguém',
          () async {
        final storage = await open();
        final server =
            FakeServer(openingBalances: const {'conta-a': 100000000});
        await enqueueAll(storage, server, AttemptNonces());

        final first = await storage.unfinished(limit: pageSize);
        expect(first, hasLength(pageSize));
        expect(first.first.sequence, 1);

        final second = await storage.unfinished(
          limit: pageSize,
          afterSequence: first.last.sequence,
        );
        expect(second.first.sequence, first.last.sequence + 1,
            reason: 'o cursor é a sequência, e não um deslocamento');

        // A última página vem curta, e a seguinte vem vazia — é assim que o
        // laço do `recover` sabe parar.
        final last = await storage.unfinished(
          limit: pageSize,
          afterSequence: total - 10,
        );
        expect(last, hasLength(10));
        expect(await storage.unfinished(afterSequence: total), isEmpty);
      });
    });
  }
}
