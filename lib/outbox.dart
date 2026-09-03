/// Uma fila para operações que não podem acontecer duas vezes.
///
/// A promessa é pequena e difícil: enfileire uma operação que não pode
/// duplicar, e receba um desfecho confiável — mesmo depois de timeout, morte do
/// processo, partição de rede, relógio errado e término de tarefa em
/// background.
///
/// O contrato está esboçado em `docs/ARCHITECTURE.md`, e mudar a forma dele
/// começa por lá.
library;

export 'src/core/clock.dart';
export 'src/core/decisions.dart';
export 'src/core/engine.dart';
export 'src/core/idempotency_key.dart';
export 'src/core/invariants.dart';
export 'src/core/journal.dart';
export 'src/core/lock.dart';
export 'src/core/operation.dart';
export 'src/core/outcome.dart';
export 'src/core/storage.dart';
export 'src/core/transport.dart';
export 'src/storage/sqlite_lease.dart';
export 'src/storage/sqlite_storage.dart';
