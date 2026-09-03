import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

import 'support/sqlite_fixture.dart';

/// **A fila é uma fila.** Ninguém fura.
///
/// Este arquivo existe porque o mesmo defeito apareceu em três caminhos
/// diferentes, um de cada vez, e cada um passava enquanto os outros dois eram
/// corrigidos:
///
/// 1. `recover()` seguia para a próxima quando a atual não conseguia sair;
/// 2. `submit` de uma operação **nova** ia direto para a rede;
/// 3. `submit` de uma operação **que já estava na fila** também.
///
/// O dano dos três é o mesmo, e é invisível para quem só conta duplicações: a
/// conta fecha, o ledger bate, nada duplica — e a ordem de enfileiramento, que
/// é critério de aceite, foi violada.
void main() {
  Operation transfer(String reference) => Operation(
        reference: reference,
        payload: {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': 1000,
        },
      );

  /// Três operações presas sem rede, e um cliente com a rede boa por cima.
  Future<(FakeServer, Storage, Outbox, ScriptedTransport)> withQueue({
    Storage? storage,
  }) async {
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final journal = storage ?? InMemoryStorage();
    final nonces = AttemptNonces();

    final offline = buildClient(
      ClientKind.correct,
      transport: ScriptedTransport(
        server: server,
        script: List.filled(5, Fault.offline),
      ),
      storage: journal,
      nonces: nonces,
    );
    for (final reference in ['fila-1', 'fila-2', 'fila-3']) {
      expect(await offline.submit(transfer(reference)), isA<Queued>());
    }

    final transport = ScriptedTransport(server: server);
    return (
      server,
      journal,
      buildClient(ClientKind.correct,
          transport: transport, storage: journal, nonces: nonces),
      transport,
    );
  }

  test('uma operação nova não passa na frente da fila', () async {
    final (server, storage, outbox, transport) = await withQueue();

    expect(await outbox.submit(transfer('recem-chegada')), isA<Queued>());

    expect(transport.sends, 0, reason: 'nada podia sair na frente');
    expect(server.ledger.entries, isEmpty);
    // E ela **está** registrada: esperar a vez não é ser recusada.
    final entry = await storage.byReference('recem-chegada');
    expect(entry, isNotNull);
    expect(entry!.sequence, 4);
    expect(entry.state, JournalState.pending);
  });

  test('resubmeter uma que já está na fila também não dá passagem', () async {
    // O usuário toca de novo no pagamento que a tela mostra como pendente.
    final (server, storage, outbox, transport) = await withQueue();

    expect(await outbox.submit(transfer('fila-3')), isA<Queued>());

    expect(transport.sends, 0);
    expect(server.ledger.entries, isEmpty);
    // E a sequência dela não mudou: resubmeter não é reenfileirar no fim.
    expect((await storage.byReference('fila-3'))!.sequence, 3);
  });

  test('a primeira da fila pode ir, e só ela', () async {
    final (server, storage, outbox, transport) = await withQueue();

    expect(await outbox.submit(transfer('fila-1')), isA<Settled>());

    expect(transport.referencesInSendOrder, ['fila-1']);
    expect(server.ledger.entries, hasLength(1));
  });

  test('esvaziada a fila, uma operação nova sai na hora', () async {
    final (server, storage, outbox, transport) = await withQueue();
    await outbox.recover();
    expect(server.ledger.entries, hasLength(3));

    expect(await outbox.submit(transfer('depois-da-fila')), isA<Settled>());
    expect(server.ledger.entries, hasLength(4));
  });

  test('dois submits concorrentes com a fila vazia não viram fila', () async {
    // Ordem global estrita é promessa sobre a **fila**. Quem dispara dois
    // `submit` ao mesmo tempo com nada pendente pediu concorrência, e travar um
    // deles seria cobrar uma promessa que o pacote não faz.
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final storage = InMemoryStorage();
    final outbox = buildClient(ClientKind.correct,
        transport: ScriptedTransport(server: server),
        storage: storage,
        nonces: AttemptNonces());

    final results = await Future.wait([
      outbox.submit(transfer('paralela-1')),
      outbox.submit(transfer('paralela-2')),
    ]);

    expect(results, everyElement(isA<Settled>()));
    expect(server.ledger.entries, hasLength(2));
  });

  test('uma operação sem desfecho não tranca quem está atrás', () async {
    // `undetermined` é destino desconhecido, e a operação **pode** ter sido
    // aplicada. Travar a fila por causa dela seria pior do que seguir — é a
    // mesma escolha que `recover()` faz.
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final storage = InMemoryStorage();
    final nonces = AttemptNonces();

    final perdida = buildClient(
      ClientKind.correct,
      transport: ScriptedTransport(
        server: server,
        script: const [Fault.responseLost, Fault.offline, Fault.offline],
      ),
      storage: storage,
      nonces: nonces,
      maxAttempts: 1,
    );
    expect(await perdida.submit(transfer('sem-desfecho')), isA<Undetermined>());

    final seguinte = buildClient(ClientKind.correct,
        transport: ScriptedTransport(server: server),
        storage: storage,
        nonces: nonces);
    expect(await seguinte.submit(transfer('atras-dela')), isA<Settled>());
  });

  test('a disciplina vale igual sobre SQLite', () async {
    final (server, storage, outbox, transport) =
        await withQueue(storage: await openTestStorage());

    expect(await outbox.submit(transfer('recem-chegada')), isA<Queued>());
    expect(transport.sends, 0);

    await outbox.recover();
    expect(
      transport.referencesInSendOrder,
      ['fila-1', 'fila-2', 'fila-3', 'recem-chegada'],
      reason: 'a recém-chegada sai por último, que é o lugar dela',
    );
    expect(
      checkInvariants(server: server, journals: [await storage.all()]),
      isEmpty,
    );
  });
}
