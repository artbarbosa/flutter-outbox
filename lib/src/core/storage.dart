import 'idempotency_key.dart';
import 'journal.dart';
import 'operation.dart';

/// Onde o journal e a fila vivem.
///
/// A camada 1 usa [InMemoryStorage]; a camada 2 implementa esta mesma interface
/// em SQLite. O núcleo não sabe qual das duas está rodando, e é isso que mantém
/// `dart test` sem SDK de UI.
abstract interface class Storage {
  /// Registra que uma tentativa vai sair, e devolve a entrada resultante.
  ///
  /// Um método só, e não um `append` seguido de um `update`, porque registrar a
  /// operação e marcar o estado dela precisa ser **uma transação só**: em duas,
  /// a morte do processo no meio deixa uma operação registrada que ninguém
  /// retoma — ou pior, que alguém retoma duas vezes.
  ///
  /// Na primeira tentativa a entrada nasce, com a sequência atribuída aqui. Nas
  /// seguintes ela é atualizada, e a sequência **não muda**: a ordem de saída é
  /// a ordem de entrada.
  Future<JournalEntry> recordAttempt({
    required Operation operation,
    required IdempotencyKey key,
    required int attemptNumber,
    required DateTime at,
  });

  Future<void> update(JournalEntry entry);

  Future<JournalEntry?> byReference(String reference);

  /// Tudo que ainda não tem desfecho, **na ordem de enfileiramento**.
  Future<List<JournalEntry>> unfinished();

  Future<List<JournalEntry>> all();
}

/// Implementação da camada 1: sem durabilidade, e é de propósito.
///
/// Durabilidade de verdade é o assunto da camada 2 e dos cenários 9 a 12. Aqui
/// o que importa é a **ordem** e o fato de a interface existir.
final class InMemoryStorage implements Storage {
  final Map<String, JournalEntry> _byReference = {};
  int _sequence = 0;

  @override
  Future<JournalEntry> recordAttempt({
    required Operation operation,
    required IdempotencyKey key,
    required int attemptNumber,
    required DateTime at,
  }) async {
    final existing = _byReference[operation.reference];
    final entry = existing?.copyWith(
          key: key,
          state: JournalState.inFlight,
          attempts: attemptNumber,
        ) ??
        JournalEntry(
          sequence: ++_sequence,
          reference: operation.reference,
          key: key,
          payload: Map.unmodifiable(operation.payload),
          payloadFingerprint: operation.payloadFingerprint,
          state: JournalState.inFlight,
          attempts: attemptNumber,
          recordedAt: at,
        );
    _byReference[entry.reference] = entry;
    return entry;
  }

  @override
  Future<void> update(JournalEntry entry) async {
    if (!_byReference.containsKey(entry.reference)) {
      throw StateError('atualização de entrada inexistente: ${entry.reference}');
    }
    _byReference[entry.reference] = entry;
  }

  @override
  Future<JournalEntry?> byReference(String reference) async =>
      _byReference[reference];

  @override
  Future<List<JournalEntry>> unfinished() async => (await all())
      .where((e) =>
          e.state != JournalState.settled && e.state != JournalState.rejected)
      .toList();

  @override
  Future<List<JournalEntry>> all() async {
    final entries = _byReference.values.toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return entries;
  }
}
