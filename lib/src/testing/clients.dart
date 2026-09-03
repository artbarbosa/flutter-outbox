import '../core/clock.dart';
import '../core/decisions.dart';
import '../core/engine.dart';
import '../core/invariants.dart';
import '../core/lock.dart';
import '../core/storage.dart';
import '../core/transport.dart';

/// Os quatro clientes da suíte: o correto e as três ablações.
///
/// Cada ablação é o **mesmo** motor com exatamente uma peça trocada. Se para
/// escrever uma delas fosse preciso copiar o motor, a ablação não provaria
/// nada: a cópia diverge do original, e o teste passaria a comparar duas coisas
/// diferentes.
enum ClientKind {
  /// Nada trocado. Passa em todos os cenários.
  correct('correto'),

  /// A chave sai da tentativa, não da intenção. É o padrão publicado no
  /// ecossistema. Reprova em 1, 2 e 6.
  attemptKey('chave-da-tentativa'),

  /// O envio acontece antes do `await` do journal. Reprova em 3 e 9.
  sendBeforeJournal('envia-antes-de-grava'),

  /// Chave desconhecida pelo servidor vira "nada aconteceu". Reprova em 8.
  resendOnExpiry('reenvia-na-expiracao');

  const ClientKind(this.label);

  /// O nome que aparece na tabela de `docs/TESTING.md` e na medição.
  final String label;
}

/// Monta um dos quatro clientes sobre o mesmo motor.
Outbox buildClient(
  ClientKind kind, {
  required Transport transport,
  Storage? storage,
  Clock? clock,
  int maxAttempts = 3,
  int pageSize = 50,
  OutboxLock lock = const NoLock(),
  AttemptNonces? nonces,
  Invariants? invariants,
}) {
  return Outbox(
    transport: transport,
    storage: storage,
    clock: clock ?? FixedClock(DateTime.utc(2026, 1, 1)),
    maxAttempts: maxAttempts,
    pageSize: pageSize,
    lock: lock,
    nonces: nonces,
    invariants: invariants,
    keyDerivation: switch (kind) {
      ClientKind.attemptKey => const KeyFromAttempt(),
      _ => const KeyFromIntent(),
    },
    attemptSequence: switch (kind) {
      ClientKind.sendBeforeJournal => const SendBeforeJournal(),
      _ => const JournalBeforeSend(),
    },
    resolutionPolicy: switch (kind) {
      ClientKind.resendOnExpiry => const AssumeNothingHappened(),
      _ => const ResolveInLedger(),
    },
  );
}
