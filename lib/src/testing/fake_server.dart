import '../core/idempotency_key.dart';
import '../core/transport.dart';
import 'ledger.dart';

/// O que o servidor respondeu, antes de a rede ter chance de perder isso.
sealed class ServerResponse {
  const ServerResponse();
}

final class ServerApplied extends ServerResponse {
  const ServerApplied(this.effectId);
  final String effectId;
}

final class ServerReplayed extends ServerResponse {
  const ServerReplayed(this.effectId);
  final String effectId;
}

final class ServerRefused extends ServerResponse {
  const ServerRefused(this.reason);
  final String reason;
}

/// Um servidor com contrato de idempotência, em processo.
///
/// Não é um dublê: é uma implementação determinística de verdade, e a contagem
/// de efeitos dela precisa ser observável — que é justamente o que um framework
/// de mock esconderia.
final class FakeServer {
  FakeServer({Map<String, int> openingBalances = const {}})
      : ledger = Ledger(openingBalances: openingBalances);

  final Ledger ledger;

  /// A janela de idempotência do servidor: chave → efeito. **Finita**, e é isso
  /// que o cenário 8 explora.
  final Map<String, _KeyRecord> _keys = {};

  int _effects = 0;

  ServerResponse apply(OutboundRequest request) {
    final known = _keys[request.key.value];
    if (known != null) {
      if (known.payloadFingerprint != request.payloadFingerprint) {
        // Cenário 7: rejeita, e **não sobrescreve** o efeito original.
        return const ServerRefused('a mesma chave chegou com outro payload');
      }
      return ServerReplayed(known.effectId);
    }

    final effectId = 'effect-${++_effects}';
    ledger.apply(LedgerEntry(
      effectId: effectId,
      key: request.key,
      reference: request.reference,
      from: request.payload['from']! as String,
      to: request.payload['to']! as String,
      amountInCents: request.payload['amountInCents']! as int,
    ));
    _keys[request.key.value] = _KeyRecord(effectId, request.payloadFingerprint);
    return ServerApplied(effectId);
  }

  /// "O que você fez com esta chave?"
  String? effectForKey(IdempotencyKey key) => _keys[key.value]?.effectId;

  /// "E com esta operação de negócio?" — a consulta que não expira.
  String? effectForReference(String reference) {
    final applied = ledger.forReference(reference);
    return applied.isEmpty ? null : applied.first.effectId;
  }

  /// O servidor esquece as chaves, e o ledger não esquece nada.
  ///
  /// Cenário 8. Repare que o cliente não tem autoridade nenhuma sobre este
  /// momento e não deve tentar prever quando ele acontece: o TTL é do servidor,
  /// e o relógio do aparelho está errado.
  void expireKeys() => _keys.clear();
}

final class _KeyRecord {
  const _KeyRecord(this.effectId, this.payloadFingerprint);
  final String effectId;
  final String payloadFingerprint;
}
