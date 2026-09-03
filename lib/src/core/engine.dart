import 'clock.dart';
import 'decisions.dart';
import 'invariants.dart';
import 'journal.dart';
import 'lock.dart';
import 'operation.dart';
import 'outcome.dart';
import 'storage.dart';
import 'transport.dart';

/// O motor.
///
/// As três decisões de desenho do projeto entram por construtor, como peças
/// ([KeyDerivation], [AttemptSequence], [ResolutionPolicy]), e não como
/// condicionais no meio do fluxo. É o que permite escrever uma ablação
/// trocando **uma** peça em vez de copiar o motor — ablação copiada não prova
/// nada, porque a cópia diverge do original.
final class Outbox {
  Outbox({
    required Transport transport,
    Storage? storage,
    Clock clock = const SystemClock(),
    KeyDerivation keyDerivation = const KeyFromIntent(),
    AttemptSequence attemptSequence = const JournalBeforeSend(),
    ResolutionPolicy resolutionPolicy = const ResolveInLedger(),
    int maxAttempts = 3,
    OutboxLock lock = const NoLock(),
    AttemptNonces? nonces,
    Invariants? invariants,
  })  : _transport = transport,
        _lock = lock,
        _nonces = nonces ?? AttemptNonces(),
        _storage = storage ?? InMemoryStorage(),
        _clock = clock,
        _keyDerivation = keyDerivation,
        _attemptSequence = attemptSequence,
        _resolutionPolicy = resolutionPolicy,
        _maxAttempts = maxAttempts,
        _invariants = invariants ?? Invariants();

  final Transport _transport;
  final Storage _storage;
  final Clock _clock;
  final KeyDerivation _keyDerivation;
  final AttemptSequence _attemptSequence;
  final ResolutionPolicy _resolutionPolicy;

  /// Teto de tentativas por chamada. Sem teto, uma operação recusada de forma
  /// permanente gira para sempre e segura a fila inteira atrás dela.
  final int _maxAttempts;

  final Invariants _invariants;

  /// De onde sai a identidade de cada tentativa.
  final AttemptNonces _nonces;

  /// Protege a fila de dois motores ao mesmo tempo. Ver [OutboxLock].
  final OutboxLock _lock;

  Storage get storage => _storage;

  /// Submete uma intenção. Não uma requisição.
  Future<SubmitOutcome> submit(Operation operation) async {
    final existing = await _storage.byReference(operation.reference);
    switch (existing?.state) {
      // Duplo submit da mesma operação (cenário 1): o desfecho já é conhecido,
      // e nada sai para a rede.
      case JournalState.settled:
        return Settled(existing!.effectId!);
      case JournalState.rejected:
        return Rejected(existing!.reason!);
      case _:
        return _drive(operation, existing);
    }
  }

  /// No start do app, e na janela de background.
  ///
  /// Retoma tudo que ficou sem desfecho, **na ordem de enfileiramento**.
  ///
  /// Se outro motor já estiver com a fila, esta chamada **não faz nada e não é
  /// erro**: quem está com o lock vai terminar o trabalho, e insistir aqui só
  /// gastaria envio em dobro.
  Future<void> recover() async {
    if (!await _lock.acquire()) return;
    try {
      for (final entry in await _storage.unfinished()) {
        final operation = Operation(
          reference: entry.reference,
          payload: Map<String, Object?>.from(entry.payload),
        );
        await _drive(operation, entry);
      }
    } finally {
      // Solto mesmo se algo explodir no meio: um lease preso é um outbox
      // parado até ele expirar, e o usuário não tem como saber disso.
      await _lock.release();
    }
  }

  Future<SubmitOutcome> _drive(Operation operation, JournalEntry? from) async {
    var entry = from;

    // **Retomar não é a mesma coisa que insistir.**
    //
    // Uma operação que ficou `undetermined` numa sessão anterior pode ter
    // ficado assim por dias, e nesse intervalo a chave dela pode ter expirado
    // no servidor. Reenviar aqui, sem perguntar, é o que faz o cliente correto
    // cobrar duas vezes no cenário 15 — e foi assim que este trecho nasceu
    // errado: o motor começava por enviar, sempre.
    //
    // Dentro de uma mesma chamada, reenviar depois de uma consulta que não
    // respondeu continua sendo seguro, e é o que o cenário 2 exercita: as
    // tentativas são consecutivas, e a chave que acabou de ser aceita não
    // expira entre uma e outra. Ao **retomar**, essa premissa não vale mais, e
    // a única saída correta é reconciliar antes.
    //
    // Repare que a diferença não é medida em tempo: é a distinção entre estar
    // no meio de uma tentativa e estar voltando a uma que ficou. O cliente não
    // tem autoridade nenhuma sobre o TTL do servidor e não tenta prevê-lo.
    if (from != null && from.state == JournalState.undetermined) {
      final resolution = await _resolutionPolicy.resolve(
        ReconciliationContext(
          transport: _transport,
          key: from.key,
          reference: from.reference,
        ),
      );
      switch (resolution) {
        case ResolvedSettled(:final effectId):
          await _write(from.copyWith(
            state: JournalState.settled,
            effectId: effectId,
          ));
          return Settled(effectId);
        case ResolvedUnknown():
          // Não deu para perguntar. A operação continua no journal, e a
          // próxima janela tenta de novo — nada expira por não ter rodado.
          return const Undetermined();
        case ResolvedNoEffect():
          // O ledger confirmou que nada aconteceu. Só agora reenviar é seguro.
          break;
      }
    }

    // O orçamento de tentativas é por chamada; `entry.attempts` acumula o
    // total histórico, que é o que o diagnóstico quer ver.
    final alreadyTried = from?.attempts ?? 0;

    for (var i = 1; i <= _maxAttempts; i++) {
      final attemptNumber = alreadyTried + i;
      final attempt = Attempt(
        number: attemptNumber,
        nonce: _nonces.next(),
      );

      final key = _keyDerivation.keyFor(operation, attempt);
      _invariants.keyDerived(operation.reference, key, attemptNumber);

      SendResult? result;
      await _attemptSequence.run(
        recordJournal: () async {
          entry = await _storage.recordAttempt(
            operation: operation,
            key: key,
            attemptNumber: attemptNumber,
            at: _clock.nowUtc(),
          );
        },
        send: () async {
          result = await _transport.send(OutboundRequest(
            key: key,
            reference: operation.reference,
            payload: operation.payload,
            payloadFingerprint: operation.payloadFingerprint,
          ));
        },
      );

      _invariants
        ..interpretingResponse(operation.reference, entry)
        ..journalIsContiguous(await _storage.all());

      final outcome = await _interpret(result!, entry!);
      if (outcome != null) return outcome;
    }

    // Acabou o orçamento sem descobrir o destino. Isto **não é falha**: o
    // registro fica no journal, e o próximo `recover()` fecha.
    await _write(entry!.copyWith(state: JournalState.undetermined));
    return const Undetermined();
  }

  /// `null` significa "tentar de novo" — e sempre com a mesma chave.
  Future<SubmitOutcome?> _interpret(SendResult result, JournalEntry entry) async {
    switch (result) {
      case SendApplied(:final effectId) || SendReplayed(:final effectId):
        await _write(entry.copyWith(
          state: JournalState.settled,
          effectId: effectId,
        ));
        return Settled(effectId);

      case SendRefused(:final reason):
        await _write(entry.copyWith(
          state: JournalState.rejected,
          reason: reason,
        ));
        return Rejected(reason);

      case SendUnreachable():
        // Não saiu do aparelho: nada aconteceu do outro lado, e a operação
        // continua na fila, na ordem.
        await _write(entry.copyWith(state: JournalState.pending));
        return const Queued();

      case SendLost():
        // O ponto do projeto: timeout é pergunta, nunca reenvio às cegas.
        await _write(entry.copyWith(state: JournalState.undetermined));
        final resolution = await _resolutionPolicy.resolve(
          ReconciliationContext(
            transport: _transport,
            key: entry.key,
            reference: entry.reference,
          ),
        );
        switch (resolution) {
          case ResolvedSettled(:final effectId):
            await _write(entry.copyWith(
              state: JournalState.settled,
              effectId: effectId,
            ));
            return Settled(effectId);
          case ResolvedNoEffect() || ResolvedUnknown():
            // Reenviar é seguro **porque a chave não mudou**. É este o momento
            // para o qual a decisão 1 existe.
            return null;
        }
    }
  }

  Future<void> _write(JournalEntry entry) => _storage.update(entry);
}
