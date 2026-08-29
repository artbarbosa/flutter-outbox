import '../core/idempotency_key.dart';
import '../core/transport.dart';
import 'fake_server.dart';

/// O que a rede faz com uma interação.
enum Fault {
  /// A rede coopera.
  none,

  /// Não sai do aparelho. Nada acontece do outro lado.
  offline,

  /// **Sai, chega, é processado — e a resposta se perde na volta.**
  ///
  /// É o problema inteiro deste projeto em um valor de enum. Do lado do
  /// cliente é indistinguível de [offline], e essa indistinguibilidade é o que
  /// torna a decisão difícil.
  responseLost,
}

/// Uma interação de rede que aconteceu, para a suíte poder contar.
final class NetworkEvent {
  const NetworkEvent(this.kind, this.fault, this.detail);

  final String kind;
  final Fault fault;
  final String detail;

  @override
  String toString() => '$kind[${fault.name}] $detail';
}

/// O transporte da suíte: **o único lugar onde falha é injetada**.
///
/// O roteiro é uma lista consumida em ordem, uma posição por interação de rede
/// — envio ou consulta. Mesmo roteiro, mesmo resultado, em qualquer máquina.
final class ScriptedTransport implements Transport {
  ScriptedTransport({required this.server, List<Fault> script = const []})
      : _script = List<Fault>.unmodifiable(script);

  final FakeServer server;
  final List<Fault> _script;
  int _cursor = 0;

  /// Tudo que passou pela rede. É daqui que saem as colunas de custo da
  /// medição: envios e reconciliações não são de graça.
  final List<NetworkEvent> log = [];

  int get sends => log.where((e) => e.kind == 'send').length;
  int get lookups => log.where((e) => e.kind.startsWith('lookup')).length;

  Fault _nextFault() => _cursor < _script.length ? _script[_cursor++] : Fault.none;

  @override
  Future<SendResult> send(OutboundRequest request) async {
    final fault = _nextFault();
    log.add(NetworkEvent('send', fault, request.key.value));

    if (fault == Fault.offline) {
      return const SendUnreachable();
    }

    // Passou deste ponto, o servidor **processa**. Se a resposta se perder
    // depois, o efeito já existe — e o cliente não tem como saber disso.
    final response = server.apply(request);
    if (fault == Fault.responseLost) {
      return const SendLost();
    }
    return switch (response) {
      ServerApplied(:final effectId) => SendApplied(effectId),
      ServerReplayed(:final effectId) => SendReplayed(effectId),
      ServerRefused(:final reason) => SendRefused(reason),
    };
  }

  @override
  Future<KeyLookup> lookupByKey(IdempotencyKey key) async {
    final fault = _nextFault();
    log.add(NetworkEvent('lookupByKey', fault, key.value));
    if (fault != Fault.none) {
      // Uma consulta sem resposta é uma consulta que não respondeu, tenha ela
      // saído do aparelho ou não.
      return const KeyLookupFailed();
    }
    final effectId = server.effectForKey(key);
    return effectId == null ? const KeyUnknown() : KeyKnown(effectId);
  }

  @override
  Future<ReferenceLookup> lookupByReference(String reference) async {
    final fault = _nextFault();
    log.add(NetworkEvent('lookupByReference', fault, reference));
    if (fault != Fault.none) {
      return const ReferenceLookupFailed();
    }
    final effectId = server.effectForReference(reference);
    return effectId == null
        ? const ReferenceUntouched()
        : ReferenceSettled(effectId);
  }
}
