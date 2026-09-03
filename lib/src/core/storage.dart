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
  ///
  /// [attemptNumber] igual a zero significa **registrar sem tentar**: a
  /// operação entra na fila, ganha a sua sequência e fica `pending`. É como uma
  /// operação nova espera a vez quando há fila à frente dela.
  Future<JournalEntry> recordAttempt({
    required Operation operation,
    required IdempotencyKey key,
    required int attemptNumber,
    required DateTime at,
  });

  Future<void> update(JournalEntry entry);

  Future<JournalEntry?> byReference(String reference);

  /// A primeira operação **esperando a vez** — `pending`, e não em voo.
  ///
  /// A distinção é o que separa fila de concorrência. Uma operação `pending`
  /// tentou e não conseguiu sair, ou nem chegou a tentar: tudo atrás dela
  /// espera. Uma `inFlight` está saindo agora, e se o app disparou outra ao
  /// lado foi porque quis paralelismo — o pacote não promete ordem entre duas
  /// chamadas concorrentes de `submit`, e cobrar isso seria cobrar uma promessa
  /// que ele não faz.
  ///
  /// `undetermined` também não segura a fila: o destino é desconhecido, mas a
  /// operação **pode** ter sido aplicada, e travar tudo por causa dela seria
  /// pior do que seguir. É a mesma escolha que `recover()` faz.
  Future<JournalEntry?> firstQueued();

  /// O que ainda não tem desfecho, **na ordem de enfileiramento**, por página.
  ///
  /// Paginado porque ler a fila inteira funciona com três operações e falha com
  /// três mil. O cursor é [afterSequence] — a sequência da última entrada da
  /// página anterior — e não um deslocamento: entradas mudam de estado enquanto
  /// a fila é percorrida, e um `OFFSET` pularia linhas por causa disso.
  Future<List<JournalEntry>> unfinished({int limit, int afterSequence});

  Future<List<JournalEntry>> all();
}

/// Implementação da camada 1: sem durabilidade, e é de propósito.
///
/// Durabilidade de verdade é o assunto da camada 2 e dos cenários 9 a 12. Aqui
/// o que importa é a **ordem** e o fato de a interface existir.
final class InMemoryStorage implements Storage {
  final Map<String, JournalEntry> _byReference = {};
  int _sequence = 0;

  /// Quantas gravações duráveis a corretude custou.
  ///
  /// A medição mostra esta coluna de propósito: o preço de não duplicar não é
  /// zero, e esconder isso tornaria a tabela suspeita.
  int writes = 0;

  @override
  Future<JournalEntry> recordAttempt({
    required Operation operation,
    required IdempotencyKey key,
    required int attemptNumber,
    required DateTime at,
  }) async {
    final state =
        attemptNumber == 0 ? JournalState.pending : JournalState.inFlight;
    final existing = _byReference[operation.reference];
    final entry = existing?.copyWith(
          key: key,
          state: state,
          attempts: attemptNumber,
        ) ??
        JournalEntry(
          sequence: ++_sequence,
          reference: operation.reference,
          key: key,
          payload: Map.unmodifiable(operation.payload),
          payloadFingerprint: operation.payloadFingerprint,
          state: state,
          attempts: attemptNumber,
          recordedAt: at,
        );
    _byReference[entry.reference] = entry;
    writes++;
    return entry;
  }

  @override
  Future<void> update(JournalEntry entry) async {
    if (!_byReference.containsKey(entry.reference)) {
      throw StateError('atualização de entrada inexistente: ${entry.reference}');
    }
    _byReference[entry.reference] = entry;
    writes++;
  }

  @override
  Future<JournalEntry?> byReference(String reference) async =>
      _byReference[reference];

  @override
  Future<JournalEntry?> firstQueued() async {
    for (final entry in await all()) {
      if (entry.state == JournalState.pending) return entry;
    }
    return null;
  }

  @override
  Future<List<JournalEntry>> unfinished({
    int limit = 50,
    int afterSequence = 0,
  }) async =>
      (await all())
          .where((e) =>
              e.sequence > afterSequence &&
              e.state != JournalState.settled &&
              e.state != JournalState.rejected)
          .take(limit)
          .toList();

  @override
  Future<List<JournalEntry>> all() async {
    final entries = _byReference.values.toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return entries;
  }
}
