import 'idempotency_key.dart';

/// Em que ponto do caminho a operação está, do lado do cliente.
enum JournalState {
  /// Registrada, ainda não enviada.
  pending,

  /// Uma tentativa saiu e ainda não teve resposta interpretada.
  inFlight,

  /// Tem efeito confirmado, e o id dele está aqui.
  settled,

  /// O servidor recusou. Não houve efeito.
  rejected,

  /// A resposta se perdeu e a reconciliação ainda não fechou. **Não é falha.**
  undetermined,
}

/// O registro do cliente sobre uma intenção.
///
/// O journal registra **intenção**; o ledger registra **efeito**. Trocar um
/// pelo outro é o erro conceitual mais provável deste projeto
/// (`docs/ARCHITECTURE.md`, As fronteiras que não se cruzam).
final class JournalEntry {
  const JournalEntry({
    required this.sequence,
    required this.reference,
    required this.key,
    required this.payload,
    required this.payloadFingerprint,
    required this.state,
    required this.attempts,
    required this.recordedAt,
    this.effectId,
    this.reason,
  });

  /// Monotônica e contígua, atribuída pelo storage.
  ///
  /// A ordem sai daqui, nunca de timestamp: duas operações no mesmo
  /// milissegundo empatam, e o empate é resolvido de forma indefinida.
  final int sequence;

  final String reference;
  final IdempotencyKey key;
  final Map<String, Object?> payload;
  final String payloadFingerprint;
  final JournalState state;
  final int attempts;
  final DateTime recordedAt;
  final String? effectId;
  final String? reason;

  JournalEntry copyWith({
    IdempotencyKey? key,
    JournalState? state,
    int? attempts,
    String? effectId,
    String? reason,
  }) {
    return JournalEntry(
      sequence: sequence,
      reference: reference,
      key: key ?? this.key,
      payload: payload,
      payloadFingerprint: payloadFingerprint,
      state: state ?? this.state,
      attempts: attempts ?? this.attempts,
      recordedAt: recordedAt,
      effectId: effectId ?? this.effectId,
      reason: reason ?? this.reason,
    );
  }

  @override
  String toString() =>
      'JournalEntry(#$sequence $reference ${state.name} key=$key '
      'attempts=$attempts effect=$effectId)';
}
