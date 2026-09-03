import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

/// Cenários 13, 14 e 15 de `docs/TESTING.md` — **a metade deles que é do
/// motor**.
///
/// Leia isto antes de contar com estes testes. Uma janela de background tem
/// duas partes: o sistema operacional **conceder** a janela, e o motor fazer a
/// coisa certa **dentro** dela. Estes testes cobrem a segunda, simulando a
/// janela como uma chamada a `recover()` sobre um storage que sobrevive.
///
/// A primeira parte não é testável aqui, e nem em emulador no caso do iOS:
/// `BGTaskScheduler` não roda em simulador, e um aparelho conectado ao Xcode
/// não entra em background de verdade. Passar aqui prova que o motor se
/// comporta quando a janela vem; **não prova nada sobre a janela vir**. O
/// cenário 15 só fecha em aparelho solto, ao longo de dias.
void main() {
  setUpAll(sqfliteFfiInit);

  Future<SqliteStorage> openStorage() =>
      SqliteStorage.open(databaseFactoryFfi, path: inMemoryDatabasePath);

  Operation transfer(String reference, int amountInCents) => Operation(
        reference: reference,
        payload: {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': amountInCents,
        },
      );

  /// Uma janela de background: motor novo, storage de sempre.
  Future<void> window(
    SqliteStorage storage,
    ScriptedTransport transport, {
    required Clock clock,
    required AttemptNonces nonces,
  }) =>
      buildClient(
        ClientKind.correct,
        transport: transport,
        storage: storage,
        clock: clock,
        nonces: nonces,
      ).recover();

  test('cenário 13 — SO encerra a tarefa no meio do envio', () async {
    final storage = await openStorage();
    addTearDown(storage.close);
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final nonces = AttemptNonces();
    final clock = FixedClock(DateTime.utc(2026, 3, 5));
    const enqueued = ['transferencia-13a', 'transferencia-13b'];

    // A fila nasce sem rede.
    final offline = buildClient(
      ClientKind.correct,
      transport: ScriptedTransport(
        server: server,
        script: const [Fault.offline, Fault.offline],
      ),
      storage: storage,
      clock: clock,
      nonces: nonces,
    );
    for (final reference in enqueued) {
      await offline.submit(transfer(reference, 15000));
    }

    // Primeira janela: a primeira operação sai, e o sistema encerra a tarefa no
    // meio da segunda.
    final primeira = ScriptedTransport(
      server: server,
      script: const [Fault.none, Fault.processKilled],
    );
    await expectLater(
      window(storage, primeira, clock: clock, nonces: nonces),
      throwsA(isA<ProcessKilled>()),
    );

    // Janela seguinte, dias depois. O motor é outro; o journal é o mesmo.
    clock.advance(const Duration(days: 2));
    final segunda = ScriptedTransport(server: server);
    await window(storage, segunda, clock: clock, nonces: nonces);

    expect(server.ledger.entries, hasLength(2));
    expect(server.ledger.duplications, 0,
        reason: 'a operação interrompida saiu uma vez só');
    expect(
      (await storage.all()).map((e) => e.state),
      everyElement(JournalState.settled),
    );
    expect(
      checkInvariants(server: server, journals: [await storage.all()]),
      isEmpty,
    );
  });

  test('cenário 14 — background dispara sem rede', () async {
    final storage = await openStorage();
    addTearDown(storage.close);
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final nonces = AttemptNonces();
    final clock = FixedClock(DateTime.utc(2026, 3, 5));
    const enqueued = [
      'transferencia-14a',
      'transferencia-14b',
      'transferencia-14c',
    ];

    final offline = buildClient(
      ClientKind.correct,
      transport: ScriptedTransport(
        server: server,
        script: const [Fault.offline, Fault.offline, Fault.offline],
      ),
      storage: storage,
      clock: clock,
      nonces: nonces,
    );
    for (final reference in enqueued) {
      await offline.submit(transfer(reference, 15000));
    }

    // O sistema concede a janela, e não há rede nenhuma. Isso acontece: a
    // constraint de rede do WorkManager é uma preferência, não uma garantia.
    final semRede = ScriptedTransport(
      server: server,
      script: List.filled(20, Fault.offline),
    );
    await window(storage, semRede, clock: clock, nonces: nonces);

    // Uma tentativa por operação, e não três: sem rede não se gasta o orçamento
    // de tentativas à toa. O motor devolve `Queued` no primeiro `Unreachable`
    // em vez de insistir.
    expect(semRede.sends, enqueued.length,
        reason: 'cada operação tentou uma vez, e parou ao ver que não há rede');
    expect(server.ledger.entries, isEmpty);

    // E a ordem sobreviveu à janela inútil.
    expect(semRede.referencesInSendOrder, enqueued);

    final journal = await storage.all();
    expect(journal.map((e) => e.reference), enqueued);
    expect(journal.map((e) => e.state), everyElement(JournalState.pending));
  });

  test('cenário 15 — janela negada por dias: nada expira, nada duplica',
      () async {
    final storage = await openStorage();
    addTearDown(storage.close);
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final nonces = AttemptNonces();
    final clock = FixedClock(DateTime.utc(2026, 3, 5));
    const reference = 'transferencia-15a';

    // Um envio que perde a resposta, e o app é fechado antes de reconciliar.
    final interrompido = ScriptedTransport(
      server: server,
      script: const [Fault.responseLost, Fault.offline, Fault.offline],
    );
    final result = await buildClient(
      ClientKind.correct,
      transport: interrompido,
      storage: storage,
      clock: clock,
      nonces: nonces,
      maxAttempts: 1,
    ).submit(transfer(reference, 15000));

    expect(result, isA<Undetermined>(),
        reason: 'sem desfecho não é falha, e é o estado que recover() fecha');
    expect(server.ledger.entries, hasLength(1),
        reason: 'o servidor aplicou, e o cliente não sabe disso');

    // O iOS não concede janela nenhuma por cinco dias. Nada aqui pode expirar
    // por não ter rodado — a chave é função da intenção, e não do relógio.
    clock.advance(const Duration(days: 5));

    // Pior: nesse intervalo a chave expirou no servidor. O cliente não tem
    // autoridade sobre isso e não tentou prever.
    server.expireKeys();

    final tardia = ScriptedTransport(server: server);
    await window(storage, tardia, clock: clock, nonces: nonces);

    // A reconciliação terminou no ledger, que não expira.
    expect(server.ledger.entries, hasLength(1));
    expect(server.ledger.duplications, 0);
    expect((await storage.byReference(reference))!.state, JournalState.settled);
    expect(
      tardia.log.map((e) => e.kind),
      containsAllInOrder(['lookupByKey', 'lookupByReference']),
    );
  });

  test('a ablação reenvia-na-expiracao cobra duas vezes depois da espera',
      () async {
    final storage = await openStorage();
    addTearDown(storage.close);
    final server = FakeServer(openingBalances: const {'conta-a': 1000000});
    final nonces = AttemptNonces();
    final clock = FixedClock(DateTime.utc(2026, 3, 5));
    const reference = 'transferencia-15b';

    await buildClient(
      ClientKind.resendOnExpiry,
      transport: ScriptedTransport(
        server: server,
        script: const [Fault.responseLost, Fault.offline],
      ),
      storage: storage,
      clock: clock,
      nonces: nonces,
      maxAttempts: 1,
    ).submit(transfer(reference, 15000));

    clock.advance(const Duration(days: 5));
    server.expireKeys();

    await buildClient(
      ClientKind.resendOnExpiry,
      transport: ScriptedTransport(server: server),
      storage: storage,
      clock: clock,
      nonces: nonces,
    ).recover();

    // Tratar chave desconhecida como "nada aconteceu" é exatamente o erro que
    // uma janela negada por dias transforma em cobrança dupla.
    expect(server.ledger.duplications, 1);
  });
}
