import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'support/sqlite_fixture.dart';

/// Cenários 9, 10 e 12 de `docs/TESTING.md` — o processo morre de verdade.
///
/// O 11 não está aqui de propósito: não existe migração enquanto existe um
/// schema só, e um teste de v1 para v1 é decoração. A regra dele mora no código
/// da migração, em `SqliteStorage.migrate`.
///
/// O contrato do storage em si está em `sqlite_storage_test.dart`.
void main() {
  setUpAll(sqfliteFfiInit);

  /// Em memória, mas SQLite de verdade: mesmo motor, mesmas transações, mesmo
  /// `AUTOINCREMENT`. O isolamento entre testes vem de `openTestStorage`.
  Future<SqliteStorage> openStorage() => openTestStorage();

  Operation transfer(String reference, int amountInCents) => Operation(
        reference: reference,
        payload: {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': amountInCents,
        },
      );

  group('cenário 9 — morte no meio da gravação local', () {
    test('a operação existe ou não existe: nada meio-gravado', () async {
      final storage = await openStorage();
      final server = FakeServer(openingBalances: const {'conta-a': 100000});
      final transport = ScriptedTransport(
        server: server,
        script: const [Fault.processKilled],
      );
      final outbox = buildClient(
        ClientKind.correct,
        transport: transport,
        storage: storage,
      );

      try {
        await outbox.submit(transfer('transferencia-9a', 15000));
      } on ProcessKilled {
        // O sistema operacional encerrou o app no meio da tentativa.
      }

      // Gravou antes de enviar, então a operação existe — inteira, com todos os
      // campos, e não pela metade.
      final entry = await storage.byReference('transferencia-9a');
      expect(entry, isNotNull);
      expect(entry!.payload['amountInCents'], 15000);
      expect(entry.key.value, isNotEmpty);
      expect(entry.state, JournalState.inFlight);
      expect(server.ledger.entries, isEmpty, reason: 'nada chegou ao servidor');
    });

    test('a ablação envia-antes-de-grava perde a operação no disco', () async {
      final storage = await openStorage();
      final server = FakeServer(openingBalances: const {'conta-a': 100000});
      final outbox = buildClient(
        ClientKind.sendBeforeJournal,
        transport: ScriptedTransport(
          server: server,
          script: const [Fault.processKilled],
        ),
        storage: storage,
      );

      try {
        await outbox.submit(transfer('transferencia-9b', 15000));
      } on ProcessKilled {
        // Esperado.
      }

      // O app achou que enfileirou, e não há registro nenhum para retomar.
      expect(await storage.all(), isEmpty);
    });
  });

  test('cenário 10 — app reaberto dias depois retoma na ordem, sem duplicar',
      () async {
    final storage = await openStorage();
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    const enqueued = ['transferencia-10a', 'transferencia-10b', 'transferencia-10c'];

    // Segunda-feira, no avião: três operações, nenhuma rede.
    final offline = buildClient(
      ClientKind.correct,
      transport: ScriptedTransport(
        server: server,
        script: const [Fault.offline, Fault.offline, Fault.offline],
      ),
      storage: storage,
      clock: FixedClock(DateTime.utc(2026, 3, 2)),
    );
    for (final (index, reference) in enqueued.indexed) {
      expect(
        await offline.submit(transfer(reference, 10000 * (index + 1))),
        isA<Queued>(),
      );
    }

    // Quinta-feira. O processo é outro, o motor é outro, e o banco é o mesmo.
    final online = ScriptedTransport(server: server);
    await buildClient(
      ClientKind.correct,
      transport: online,
      storage: storage,
      clock: FixedClock(DateTime.utc(2026, 3, 5)),
    ).recover();

    expect(online.referencesInSendOrder, enqueued,
        reason: 'a ordem de enfileiramento atravessou o restart');
    expect(server.ledger.entries, hasLength(3));
    expect(server.ledger.duplications, 0);
    expect(
      checkInvariants(server: server, journals: [await storage.all()]),
      isEmpty,
    );
  });

  group('cenário 12 — duas instâncias disputando o mesmo outbox', () {
    test('sem lease, o efeito não duplica — mas o trabalho sai dobrado',
        () async {
      final storage = await openStorage();
      final server = FakeServer(openingBalances: const {'conta-a': 1000000});
      final nonces = AttemptNonces();
      const enqueued = ['transferencia-12a', 'transferencia-12b'];

      await _fillQueue(storage, server, nonces, enqueued);

      final tela = ScriptedTransport(server: server);
      final janela = ScriptedTransport(server: server);
      await Future.wait([
        buildClient(ClientKind.correct,
                transport: tela, storage: storage, nonces: nonces)
            .recover(),
        buildClient(ClientKind.correct,
                transport: janela, storage: storage, nonces: nonces)
            .recover(),
      ]);

      // A invariante de duplicação sobrevive sozinha, e é importante saber por
      // quê: as duas instâncias mandam a **mesma** chave, e o servidor
      // deduplica. Não é o lease que está protegendo isto.
      expect(server.ledger.entries, hasLength(2));
      expect(server.ledger.duplications, 0);

      // O que se perde sem lease é orçamento: cada operação saiu duas vezes.
      expect(tela.sends + janela.sends, 4,
          reason: 'é esta a medição que justificou o lease');
    });

    test('com lease, a segunda instância não trabalha, e a ordem se mantém',
        () async {
      final storage = await openStorage();
      final server = FakeServer(openingBalances: const {'conta-a': 1000000});
      final nonces = AttemptNonces();
      const enqueued = ['transferencia-12c', 'transferencia-12d'];

      await _fillQueue(storage, server, nonces, enqueued);

      final clock = FixedClock(DateTime.utc(2026, 3, 5));
      final tela = ScriptedTransport(server: server);
      final janela = ScriptedTransport(server: server);
      await Future.wait([
        buildClient(ClientKind.correct,
                transport: tela,
                storage: storage,
                clock: clock,
                nonces: nonces,
                lock: SqliteLease(storage.database,
                    owner: 'tela', clock: clock))
            .recover(),
        buildClient(ClientKind.correct,
                transport: janela,
                storage: storage,
                clock: clock,
                nonces: nonces,
                lock: SqliteLease(storage.database,
                    owner: 'janela', clock: clock))
            .recover(),
      ]);

      expect(tela.sends + janela.sends, 2,
          reason: 'cada operação saiu uma vez só');
      expect(server.ledger.entries, hasLength(2));

      // Quem trabalhou, trabalhou na ordem. Quem não pegou o lease não enviou
      // nada, e isso não é erro.
      final worker = tela.sends > 0 ? tela : janela;
      final idle = tela.sends > 0 ? janela : tela;
      expect(worker.referencesInSendOrder, enqueued);
      expect(idle.sends, 0);

      expect(
        checkInvariants(server: server, journals: [await storage.all()]),
        isEmpty,
      );
    });

    test('um lease expirado não trava o outbox para sempre', () async {
      final storage = await openStorage();
      final clock = FixedClock(DateTime.utc(2026, 3, 5));

      // Um processo que morreu segurando o lease: ele nunca vai soltar.
      final morto = SqliteLease(storage.database,
          owner: 'processo-morto',
          clock: clock,
          duration: const Duration(minutes: 5));
      expect(await morto.acquire(), isTrue);

      final vivo = SqliteLease(storage.database, owner: 'vivo', clock: clock);
      expect(await vivo.acquire(), isFalse, reason: 'ainda dentro do prazo');

      clock.advance(const Duration(minutes: 6));
      expect(await vivo.acquire(), isTrue,
          reason: 'sem prazo, um processo morto travaria o outbox até a '
              'reinstalação do app');
    });

    test('soltar o lease é privilégio de quem o tem', () async {
      final storage = await openStorage();
      final clock = FixedClock(DateTime.utc(2026, 3, 5));

      final antigo = SqliteLease(storage.database,
          owner: 'antigo', clock: clock, duration: const Duration(minutes: 1));
      final novo = SqliteLease(storage.database, owner: 'novo', clock: clock);

      await antigo.acquire();
      clock.advance(const Duration(minutes: 2));
      await novo.acquire();

      // O antigo perdeu o lease por expiração e agora tenta soltar. Se ele
      // conseguisse, liberaria o lease de quem entrou depois dele.
      await antigo.release();

      final terceiro =
          SqliteLease(storage.database, owner: 'terceiro', clock: clock);
      expect(await terceiro.acquire(), isFalse,
          reason: 'o lease do novo continua de pé');
    });
  });
}

/// Enfileira operações sem rede, para os testes de disputa começarem com uma
/// fila de verdade.
Future<void> _fillQueue(
  SqliteStorage storage,
  FakeServer server,
  AttemptNonces nonces,
  List<String> references,
) async {
  final offline = buildClient(
    ClientKind.correct,
    transport: ScriptedTransport(
      server: server,
      script: [for (var i = 0; i < references.length; i++) Fault.offline],
    ),
    storage: storage,
    nonces: nonces,
  );
  for (final reference in references) {
    await offline.submit(Operation(
      reference: reference,
      payload: const {
        'from': 'conta-a',
        'to': 'conta-b',
        'amountInCents': 15000,
      },
    ));
  }
}
