import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../core/fingerprint.dart';
import '../core/idempotency_key.dart';
import '../core/journal.dart';
import '../core/operation.dart';
import '../core/storage.dart';
import 'sqlite_lease.dart';

/// O journal em SQLite: a camada 2 **implementando a interface que a camada 1
/// define**, e não reescrevendo o núcleo.
///
/// Depende de `sqflite_common`, que é Dart puro — só o contrato. Quem traz a
/// implementação é o app: `sqflite` no aparelho, `sqflite_common_ffi` na suíte.
/// É isso que mantém `dart test` rodando sem SDK do Flutter.
final class SqliteStorage implements Storage {
  SqliteStorage(this._db);

  /// Abre (ou cria) o banco e devolve o storage pronto.
  ///
  /// [factory] vem do app: `databaseFactory` do `sqflite` no aparelho,
  /// `databaseFactoryFfi` do `sqflite_common_ffi` na suíte e no desktop.
  static Future<SqliteStorage> open(
    DatabaseFactory factory, {
    String path = 'outbox.db',
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          for (final statement in schema) {
            await db.execute(statement);
          }
        },
        onUpgrade: migrate,
      ),
    );
    return SqliteStorage(db);
  }

  /// Sobe de um em um. Quando a primeira migração real chegar, a fixture dela
  /// **nasce com fila pendente e journal em estado intermediário** — nunca com
  /// banco vazio. É a regra do cenário 11 de `docs/TESTING.md`, e o lugar dela
  /// é aqui, no código da migração, não num teste de v1 para v1.
  static Future<void> migrate(Database db, int from, int to) async {
    // ignore: prefer_final_locals — a migração real incrementa isto.
    var version = from;
    while (version < to) {
      // Enquanto existe um schema só, não há passo nenhum para dar, e a lista
      // vazia é a resposta honesta. A primeira migração real entra aqui:
      //
      //   if (version == 1) {
      //     await db.execute('ALTER TABLE journal ADD COLUMN ...');
      //     continue;
      //   }
      throw StateError(
        'sem migração de v$version para v${version + 1}: uma fila pendente '
        'seria perdida em silêncio, e perder operação é pior do que falhar ao '
        'abrir',
      );
    }
  }

  static const schemaVersion = 1;

  /// `sequence` é `INTEGER PRIMARY KEY AUTOINCREMENT`, e é a ordem.
  ///
  /// Nunca timestamp: duas operações no mesmo milissegundo empatam, e o empate
  /// é resolvido de forma indefinida. `AUTOINCREMENT` (e não o rowid puro)
  /// porque o rowid reaproveita número de linha apagada, e a invariante interna
  /// 2 exige sequência contígua **sem repetição**.
  static const schema = [
    '''
    CREATE TABLE journal (
      sequence            INTEGER PRIMARY KEY AUTOINCREMENT,
      reference           TEXT    NOT NULL UNIQUE,
      idempotency_key     TEXT    NOT NULL,
      payload             TEXT    NOT NULL,
      payload_fingerprint TEXT    NOT NULL,
      state               TEXT    NOT NULL,
      attempts            INTEGER NOT NULL,
      recorded_at         TEXT    NOT NULL,
      effect_id           TEXT,
      reason              TEXT
    )
    ''',
    // A fila é lida por estado e na ordem da sequência, e é a leitura mais
    // frequente do pacote.
    'CREATE INDEX journal_unfinished ON journal (state, sequence)',
    SqliteLease.schema,
  ];

  final Database _db;

  /// O banco por baixo, para o app montar um [SqliteLease] sobre ele.
  Database get database => _db;

  Future<void> close() => _db.close();

  @override
  Future<JournalEntry> recordAttempt({
    required Operation operation,
    required IdempotencyKey key,
    required int attemptNumber,
    required DateTime at,
  }) async {
    // **Uma transação só.** Registrar a operação e marcar o estado dela em duas
    // deixa, na morte do processo entre elas, uma operação registrada que
    // ninguém retoma — ou pior, que alguém retoma duas vezes.
    final state =
        attemptNumber == 0 ? JournalState.pending : JournalState.inFlight;
    return _db.transaction((txn) async {
      final existing = await _read(txn, operation.reference);
      if (existing == null) {
        final sequence = await txn.insert('journal', {
          'reference': operation.reference,
          'idempotency_key': key.value,
          'payload': encodePayload(operation.payload),
          'payload_fingerprint': operation.payloadFingerprint,
          'state': state.name,
          'attempts': attemptNumber,
          'recorded_at': at.toUtc().toIso8601String(),
        });
        return JournalEntry(
          sequence: sequence,
          reference: operation.reference,
          key: key,
          payload: Map.unmodifiable(operation.payload),
          payloadFingerprint: operation.payloadFingerprint,
          state: state,
          attempts: attemptNumber,
          recordedAt: at,
        );
      }

      final updated = existing.copyWith(
        key: key,
        state: state,
        attempts: attemptNumber,
      );
      await _write(txn, updated);
      return updated;
    });
  }

  @override
  Future<void> update(JournalEntry entry) async {
    final rows = await _write(_db, entry);
    if (rows == 0) {
      throw StateError('atualização de entrada inexistente: ${entry.reference}');
    }
  }

  @override
  Future<JournalEntry?> byReference(String reference) =>
      _read(_db, reference);

  @override
  Future<JournalEntry?> firstQueued() async {
    // Uma linha só, pelo índice `journal_unfinished`, que cobre
    // `(state, sequence)`.
    final rows = await _select(
      where: 'state = ?',
      arguments: [JournalState.pending.name],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single;
  }

  @override
  Future<List<JournalEntry>> unfinished({
    int limit = 50,
    int afterSequence = 0,
  }) async =>
      // O índice `journal_unfinished` cobre este `WHERE` e este `ORDER BY`, e é
      // por isso que ele existe.
      _select(
        where: 'state NOT IN (?, ?) AND sequence > ?',
        arguments: [
          JournalState.settled.name,
          JournalState.rejected.name,
          afterSequence,
        ],
        limit: limit,
      );

  @override
  Future<List<JournalEntry>> all() => _select();

  Future<List<JournalEntry>> _select({
    String? where,
    List<Object?> arguments = const [],
    int? limit,
  }) async {
    // Ordem por sequência, sempre — e nunca `SELECT *` sem `ORDER BY`, que o
    // SQLite não promete ordenar.
    final rows = await _db.query(
      'journal',
      where: where,
      whereArgs: arguments,
      orderBy: 'sequence ASC',
      limit: limit,
    );
    return [for (final row in rows) _fromRow(row)];
  }

  Future<JournalEntry?> _read(
    DatabaseExecutor executor,
    String reference,
  ) async {
    final rows = await executor.query(
      'journal',
      where: 'reference = ?',
      whereArgs: [reference],
      limit: 1,
    );
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  Future<int> _write(DatabaseExecutor executor, JournalEntry entry) =>
      executor.update(
        'journal',
        {
          'idempotency_key': entry.key.value,
          'state': entry.state.name,
          'attempts': entry.attempts,
          'effect_id': entry.effectId,
          'reason': entry.reason,
        },
        where: 'reference = ?',
        whereArgs: [entry.reference],
      );

  /// JSON canônico: chaves em ordem, sempre.
  ///
  /// A mesma intenção precisa produzir os mesmos bytes depois de uma volta pelo
  /// banco — senão a impressão digital do payload muda entre execuções, e a
  /// detecção de conflito do cenário 7 vira ruído.
  static String encodePayload(Map<String, Object?> payload) =>
      canonicalJson(payload);

  static Map<String, Object?> decodePayload(String encoded) =>
      Map<String, Object?>.from(jsonDecode(encoded) as Map);

  JournalEntry _fromRow(Map<String, Object?> row) => JournalEntry(
        sequence: row['sequence']! as int,
        reference: row['reference']! as String,
        key: IdempotencyKey(row['idempotency_key']! as String),
        payload: decodePayload(row['payload']! as String),
        payloadFingerprint: row['payload_fingerprint']! as String,
        state: JournalState.values.byName(row['state']! as String),
        attempts: row['attempts']! as int,
        recordedAt: DateTime.parse(row['recorded_at']! as String),
        effectId: row['effect_id'] as String?,
        reason: row['reason'] as String?,
      );
}
