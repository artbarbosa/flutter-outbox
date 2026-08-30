import 'fingerprint.dart';
import 'idempotency_key.dart';
import 'operation.dart';
import 'transport.dart';

/// De onde sai a identidade de cada tentativa.
///
/// Um contador, e não um relógio nem um `Random()` sem seed: a suíte inteira
/// depende de a mesma execução produzir a mesma sequência.
///
/// É compartilhável entre motores de propósito. Dois aparelhos — ou o mesmo app
/// depois de reinstalado — geram tentativas **diferentes**, e uma fonte por
/// instância faria dois clientes distintos produzirem o mesmo nonce, o que
/// nenhum cliente de verdade faz. A ablação `chave-da-tentativa` deixaria de
/// representar o que ela existe para representar.
final class AttemptNonces {
  int _counter = 0;

  String next() => 'attempt-${++_counter}';
}

/// Uma tentativa de envio. É o que **muda**; a intenção é o que não muda.
final class Attempt {
  const Attempt({required this.number, required this.nonce});

  /// 1-based, dentro da mesma operação.
  final int number;

  /// Único em todo o motor, e determinístico: um contador, nunca um relógio e
  /// nunca um `Random()` sem seed.
  final String nonce;
}

// --------------------------------------------------------------------------
// Decisão 1 — de onde sai a chave de idempotência
// --------------------------------------------------------------------------

/// A primeira das três decisões, e a tese do projeto em uma linha.
abstract interface class KeyDerivation {
  IdempotencyKey keyFor(Operation operation, Attempt attempt);
}

/// A chave é função da intenção, e de mais nada.
///
/// Repare que [Attempt] entra na assinatura e é **ignorado**: é assim que a
/// ablação consegue trocar só esta peça sem copiar o motor.
final class KeyFromIntent implements KeyDerivation {
  const KeyFromIntent();

  @override
  IdempotencyKey keyFor(Operation operation, Attempt attempt) =>
      IdempotencyKey('idem-${fingerprint(operation.reference)}');
}

/// **Ablação `chave-da-tentativa`.** A chave nasce no envio.
///
/// É o comportamento publicado do ecossistema, não um espantalho: chave
/// fornecida pelo app ou gerada na hora, timeout resolvido com retry, exatidão
/// delegada ao backend. Precisa reprovar nos cenários 1, 2 e 6.
final class KeyFromAttempt implements KeyDerivation {
  const KeyFromAttempt();

  @override
  IdempotencyKey keyFor(Operation operation, Attempt attempt) =>
      IdempotencyKey('idem-${fingerprint(attempt.nonce)}');
}

// --------------------------------------------------------------------------
// Decisão 2 — o que acontece antes: gravar ou enviar
// --------------------------------------------------------------------------

/// A segunda decisão, e a que passa em todos os testes felizes quando está
/// errada.
abstract interface class AttemptSequence {
  Future<void> run({
    required Future<void> Function() recordJournal,
    required Future<void> Function() send,
  });
}

/// O `await` da gravação acontece **antes** da chamada de rede.
final class JournalBeforeSend implements AttemptSequence {
  const JournalBeforeSend();

  @override
  Future<void> run({
    required Future<void> Function() recordJournal,
    required Future<void> Function() send,
  }) async {
    await recordJournal();
    await send();
  }
}

/// **Ablação `envia-antes-de-grava`.** Duas linhas invertidas.
///
/// Sem morte de processo o estado final é o mesmo, e é por isso que a suíte
/// feliz não vê nada. Precisa reprovar nos cenários 3 e 9.
final class SendBeforeJournal implements AttemptSequence {
  const SendBeforeJournal();

  @override
  Future<void> run({
    required Future<void> Function() recordJournal,
    required Future<void> Function() send,
  }) async {
    await send();
    await recordJournal();
  }
}

// --------------------------------------------------------------------------
// Decisão 3 — onde a reconciliação termina
// --------------------------------------------------------------------------

/// O que o cliente concluiu sobre uma tentativa sem desfecho.
sealed class Resolution {
  const Resolution();
}

final class ResolvedSettled extends Resolution {
  const ResolvedSettled(this.effectId);
  final String effectId;
}

/// Nenhum efeito existe. Reenviar é seguro, com **a mesma chave**.
final class ResolvedNoEffect extends Resolution {
  const ResolvedNoEffect();
}

/// Não deu para descobrir. Continua sem desfecho, e o journal guarda.
final class ResolvedUnknown extends Resolution {
  const ResolvedUnknown();
}

final class ReconciliationContext {
  const ReconciliationContext({
    required this.transport,
    required this.key,
    required this.reference,
  });

  final Transport transport;
  final IdempotencyKey key;
  final String reference;
}

/// A terceira decisão: a chave expira no servidor, o ledger não.
abstract interface class ResolutionPolicy {
  Future<Resolution> resolve(ReconciliationContext context);
}

/// Pergunta pela chave; se o servidor não a conhecer, **desce para a referência
/// de negócio** antes de concluir qualquer coisa.
final class ResolveInLedger implements ResolutionPolicy {
  const ResolveInLedger();

  @override
  Future<Resolution> resolve(ReconciliationContext context) async {
    switch (await context.transport.lookupByKey(context.key)) {
      case KeyKnown(:final effectId):
        return ResolvedSettled(effectId);
      case KeyLookupFailed():
        // Não deu para perguntar. Reenviar com a mesma chave é seguro; é
        // exatamente para este momento que ela é estável.
        return const ResolvedUnknown();
      case KeyUnknown():
        break;
    }
    switch (await context.transport.lookupByReference(context.reference)) {
      case ReferenceSettled(:final effectId):
        return ResolvedSettled(effectId);
      case ReferenceUntouched():
        return const ResolvedNoEffect();
      case ReferenceLookupFailed():
        return const ResolvedUnknown();
    }
  }
}

/// **Ablação `reenvia-na-expiracao`.** Chave desconhecida vira "nada
/// aconteceu".
///
/// A frase parece razoável e está errada: o servidor não conhecer a chave pode
/// significar que ela expirou lá, com o efeito já aplicado. Precisa reprovar no
/// cenário 8.
final class AssumeNothingHappened implements ResolutionPolicy {
  const AssumeNothingHappened();

  @override
  Future<Resolution> resolve(ReconciliationContext context) async {
    return switch (await context.transport.lookupByKey(context.key)) {
      KeyKnown(:final effectId) => ResolvedSettled(effectId),
      KeyUnknown() => const ResolvedNoEffect(),
      KeyLookupFailed() => const ResolvedUnknown(),
    };
  }
}
