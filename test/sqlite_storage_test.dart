import 'package:flutter_outbox/outbox.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

import 'support/sqlite_fixture.dart';

/// O contrato do `SqliteStorage`, separado dos cenários que o usam.
///
/// A camada 2 **implementa uma interface que a camada 1 define**, e é isso que
/// este arquivo verifica: sequência contígua, payload que volta igual, ordem, e
/// os erros que precisam ser erros. Os cenários adversariais que exercitam o
/// motor sobre ele estão em `layer2_scenarios_test.dart`.
///
/// Headless por `sqflite_common_ffi`: sem aparelho, sem emulador, sem
/// contêiner.
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

  group('o storage cumpre o mesmo contrato que o núcleo espera', () {
    late SqliteStorage storage;

    setUp(() async => storage = await openStorage());
    tearDown(() async => storage.close());

    test('a sequência é contígua e sobrevive à releitura', () async {
      for (final reference in ['ref-1', 'ref-2', 'ref-3']) {
        await storage.recordAttempt(
          operation: transfer(reference, 15000),
          key: IdempotencyKey('k-$reference'),
          attemptNumber: 1,
          at: DateTime.utc(2026),
        );
      }

      final entries = await storage.all();
      expect(entries.map((e) => e.sequence), [1, 2, 3]);
      expect(entries.map((e) => e.reference), ['ref-1', 'ref-2', 'ref-3']);
    });

    test('uma tentativa nova não cria linha nova, e não muda a sequência',
        () async {
      final first = await storage.recordAttempt(
        operation: transfer('ref-1', 15000),
        key: const IdempotencyKey('k-1'),
        attemptNumber: 1,
        at: DateTime.utc(2026),
      );
      final second = await storage.recordAttempt(
        operation: transfer('ref-1', 15000),
        key: const IdempotencyKey('k-1'),
        attemptNumber: 2,
        at: DateTime.utc(2026),
      );

      expect(second.sequence, first.sequence);
      expect(second.attempts, 2);
      expect(await storage.all(), hasLength(1));
    });

    test('o payload volta igual, com as chaves na mesma ordem', () async {
      // Se a ida e a volta pelo banco mudarem os bytes, a impressão digital do
      // payload muda com eles e a detecção de conflito do cenário 7 vira ruído.
      final operation = transfer('ref-1', 15000);
      await storage.recordAttempt(
        operation: operation,
        key: const IdempotencyKey('k-1'),
        attemptNumber: 1,
        at: DateTime.utc(2026),
      );

      final read = (await storage.byReference('ref-1'))!;
      expect(read.payload, operation.payload);
      expect(
        Operation(reference: 'ref-1', payload: read.payload)
            .payloadFingerprint,
        operation.payloadFingerprint,
      );
    });

    test('unfinished traz só o que não fechou, na ordem', () async {
      for (final reference in ['ref-1', 'ref-2', 'ref-3']) {
        await storage.recordAttempt(
          operation: transfer(reference, 15000),
          key: IdempotencyKey('k-$reference'),
          attemptNumber: 1,
          at: DateTime.utc(2026),
        );
      }
      final settled = (await storage.byReference('ref-2'))!
          .copyWith(state: JournalState.settled, effectId: 'effect-9');
      await storage.update(settled);

      expect(
        (await storage.unfinished()).map((e) => e.reference),
        ['ref-1', 'ref-3'],
      );
    });

    test('atualizar entrada inexistente é erro, e não silêncio', () async {
      final orphan = JournalEntry(
        sequence: 99,
        reference: 'nunca-registrada',
        key: const IdempotencyKey('k'),
        payload: const {},
        payloadFingerprint: '',
        state: JournalState.settled,
        attempts: 1,
        recordedAt: DateTime.utc(2026),
      );
      expect(storage.update(orphan), throwsStateError);
    });
  });

}
