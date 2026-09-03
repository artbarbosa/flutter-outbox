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
    int pageSize = 50,
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
        _pageSize = pageSize,
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

  /// Quantas operações pendentes são lidas por vez.
  final int _pageSize;

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
        break;
    }

    // **Tem alguém esperando a vez na frente?**
    //
    // Perguntar **antes** de registrar, e não depois, por dois motivos que só
    // aparecem quando se tenta o contrário:
    //
    // 1. registrar primeiro cria uma janela em que a própria operação aparece
    //    como `pending` para um `submit` concorrente, e dois pagamentos
    //    disparados juntos viravam um enviado e um enfileirado;
    // 2. registrar aqui gravaria o journal **fora** da [AttemptSequence], e a
    //    ablação `envia-antes-de-grava` passaria a gravar antes de enviar sem
    //    querer — a decisão 2 deixaria de ser testada por qualquer coisa.
    //
    // [Storage.firstQueued] só enxerga `pending`, e a razão está lá: uma
    // operação em voo agora não é fila, é o app paralelizando de propósito.
    // Vale para operação nova **e** para uma que já está no journal: alguém
    // tocar de novo num pagamento que a tela mostra como pendente não dá a ele
    // passagem na fila. Foi o terceiro caminho encontrado para o mesmo defeito,
    // e o mais fácil de esquecer, porque a operação já existe e a pergunta
    // "sou nova?" não a alcança.
    final ahead = await _storage.firstQueued();
    if (ahead != null &&
        (existing == null || ahead.sequence < existing.sequence)) {
      // Entra na fila, com a sua sequência, e **sem sair para a rede**. Sem
      // isto um pagamento novo com a rede boa passa na frente de três que
      // ficaram esperando no avião, e a ordem de enfileiramento quebra sem
      // ninguém duplicar nada. É o mesmo defeito que o `recover()` tinha, no
      // caminho que ele não cobre.
      //
      // Uma que já está no journal não é registrada de novo: ela já tem a
      // sequência dela, e reescrever aqui trocaria a chave por uma derivada de
      // uma tentativa que não vai acontecer.
      if (existing == null) {
        await _storage.recordAttempt(
          operation: operation,
          key: _keyDerivation.keyFor(
            operation,
            Attempt(number: 0, nonce: _nonces.next()),
          ),
          // Zero significa "registrada, ainda não tentada".
          attemptNumber: 0,
          at: _clock.nowUtc(),
        );
      }
      return const Queued();
    }

    return _drive(operation, existing);
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
      // Por página, e não a fila inteira: ler tudo funciona com três operações
      // e falha com três mil (`docs/PITFALLS.md`, Ordem e concorrência). O
      // cursor é a sequência, que é monotônica — nunca um deslocamento, que
      // pularia linhas quando as anteriores mudam de estado no meio da volta.
      var afterSequence = 0;
      while (true) {
        final page = await _storage.unfinished(
          limit: _pageSize,
          afterSequence: afterSequence,
        );
        if (page.isEmpty) return;

        for (final entry in page) {
          final operation = Operation(
            reference: entry.reference,
            payload: Map<String, Object?>.from(entry.payload),
          );
          final outcome = await _drive(operation, entry);

          // **Ordem global estrita: quem não sai segura todo mundo atrás.**
          //
          // Seguir para a próxima aqui aplicaria a #2 com a #1 ainda pendente,
          // e a ordem de enfileiramento — que é critério de aceite, não
          // conforto — estaria quebrada sem ninguém duplicar nada. É o custo
          // declarado desta escolha, e o README a expõe como discutível: num
          // app com fila longa, uma operação problemática vira o gargalo.
          //
          // `Undetermined` não para a fila: o destino é desconhecido, mas a
          // operação **pode** ter sido aplicada, e travar tudo por causa dela
          // seria pior. `recover()` volta a ela na rodada seguinte.
          if (outcome is Queued) return;
        }
        afterSequence = page.last.sequence;
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
