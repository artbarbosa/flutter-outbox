import 'idempotency_key.dart';

/// A fronteira injetável com o servidor do app.
///
/// Em produção o app implementa isto sobre a rede dele. No teste, o pacote traz
/// uma implementação determinística. **É o único lugar onde falha é injetada**:
/// nenhum outro componente simula falha por conta própria.
abstract interface class Transport {
  Future<SendResult> send(OutboundRequest request);

  /// "O que você fez com esta chave?"
  ///
  /// É o que transforma timeout em pergunta em vez de reenvio.
  Future<KeyLookup> lookupByKey(IdempotencyKey key);

  /// "E com esta operação de negócio?"
  ///
  /// O degrau de baixo, para quando a chave já expirou no servidor. O ledger
  /// não expira; a chave expira.
  Future<ReferenceLookup> lookupByReference(String reference);
}

final class OutboundRequest {
  const OutboundRequest({
    required this.key,
    required this.reference,
    required this.payload,
    required this.payloadFingerprint,
  });

  final IdempotencyKey key;
  final String reference;
  final Map<String, Object?> payload;
  final String payloadFingerprint;
}

/// O que o cliente conseguiu saber sobre uma tentativa.
///
/// A distinção entre [SendUnreachable] e [SendLost] é a linha divisória do
/// projeto: a primeira diz "não saiu daqui", a segunda diz "não sei". Tratar as
/// duas como falha é o erro central que este pacote existe para demonstrar.
sealed class SendResult {
  const SendResult();
}

/// O servidor aplicou agora.
final class SendApplied extends SendResult {
  const SendApplied(this.effectId);
  final String effectId;
}

/// O servidor já conhecia esta chave e devolveu o efeito original.
final class SendReplayed extends SendResult {
  const SendReplayed(this.effectId);
  final String effectId;
}

/// O servidor recusou. Não houve efeito, e não adianta reenviar.
final class SendRefused extends SendResult {
  const SendRefused(this.reason);
  final String reason;
}

/// A requisição não saiu do aparelho. Nada aconteceu do outro lado.
final class SendUnreachable extends SendResult {
  const SendUnreachable();
}

/// Saiu, e a resposta não voltou. **Destino desconhecido, não falha.**
final class SendLost extends SendResult {
  const SendLost();
}

sealed class KeyLookup {
  const KeyLookup();
}

final class KeyKnown extends KeyLookup {
  const KeyKnown(this.effectId);
  final String effectId;
}

/// O servidor não conhece esta chave.
///
/// Isto **não prova que nada aconteceu**: pode ser que a chave tenha expirado
/// lá. É exatamente aqui que a ablação `reenvia-na-expiracao` erra.
final class KeyUnknown extends KeyLookup {
  const KeyUnknown();
}

final class KeyLookupFailed extends KeyLookup {
  const KeyLookupFailed();
}

sealed class ReferenceLookup {
  const ReferenceLookup();
}

final class ReferenceSettled extends ReferenceLookup {
  const ReferenceSettled(this.effectId);
  final String effectId;
}

final class ReferenceUntouched extends ReferenceLookup {
  const ReferenceUntouched();
}

final class ReferenceLookupFailed extends ReferenceLookup {
  const ReferenceLookupFailed();
}
