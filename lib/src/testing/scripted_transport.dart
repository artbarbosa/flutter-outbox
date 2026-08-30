import 'dart:async';

import '../core/idempotency_key.dart';
import '../core/transport.dart';
import 'fake_server.dart';

/// O que a rede — ou o sistema operacional — faz com uma interação.
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

  /// O processo morre no meio da interação, antes de o servidor ver qualquer
  /// coisa. É o sistema operacional matando o app, não a rede falhando.
  ///
  /// Onde exatamente isso cai depende da [AttemptSequence] do cliente, e é essa
  /// a graça: para quem grava antes, a morte pega o journal já escrito; para
  /// quem envia antes, pega a operação sem registro nenhum.
  processKilled,

  /// O servidor esquece as chaves **antes** de responder esta interação.
  ///
  /// O TTL é do servidor, e o cliente não tem autoridade nenhuma sobre este
  /// momento — nem como prevê-lo, já que o relógio do aparelho está errado.
  keysExpired,
}

/// O processo morreu. Não é exceção de rede, e ninguém deve tratá-la como tal.
final class ProcessKilled implements Exception {
  const ProcessKilled();

  @override
  String toString() => 'ProcessKilled: o sistema operacional encerrou o app';
}

/// Uma interação de rede que aconteceu, para a suíte poder contar e ordenar.
final class NetworkEvent {
  NetworkEvent(this.kind, this.fault, this.reference, this.key);

  final String kind;

  /// Preenchido quando a interação é **processada**, que com [reorderWindow]
  /// pode ser depois de ela ter sido registrada.
  Fault fault;
  final String reference;
  final String key;

  @override
  String toString() => '$kind[${fault.name}] $reference $key';
}

/// O transporte da suíte: **o único lugar onde falha é injetada**.
///
/// O roteiro é uma lista consumida em ordem, uma posição por interação de rede
/// — envio ou consulta. Mesmo roteiro, mesmo resultado, em qualquer máquina.
final class ScriptedTransport implements Transport {
  ScriptedTransport({
    required this.server,
    List<Fault> script = const [],
    this.reorderWindow = 1,
  }) : _script = List<Fault>.unmodifiable(script);

  final FakeServer server;
  final List<Fault> _script;

  /// Quantos envios segurar antes de responder **na ordem inversa**.
  ///
  /// É o cenário 4. Com 1 (o padrão) cada envio responde na hora. Com N, os N
  /// primeiros ficam pendentes e são resolvidos de trás para frente — e o
  /// cliente precisa continuar casando cada desfecho com a sua operação.
  ///
  /// Cuidado ao usar: se chegarem menos de N envios, eles nunca completam.
  final int reorderWindow;

  final List<_Pending> _held = [];
  int _cursor = 0;

  /// Tudo que passou pela rede. É daqui que saem as colunas de custo da
  /// medição: envios e reconciliações não são de graça.
  final List<NetworkEvent> log = [];

  int get sends => log.where((e) => e.kind == 'send').length;
  int get lookups => log.where((e) => e.kind.startsWith('lookup')).length;

  /// A ordem em que cada referência apareceu na rede pela primeira vez.
  ///
  /// Comparada com a ordem das sequências do journal, é a invariante interna 4.
  List<String> get referencesInSendOrder {
    final seen = <String>[];
    for (final event in log.where((e) => e.kind == 'send')) {
      if (!seen.contains(event.reference)) seen.add(event.reference);
    }
    return seen;
  }

  Fault _nextFault() =>
      _cursor < _script.length ? _script[_cursor++] : Fault.none;

  @override
  Future<SendResult> send(OutboundRequest request) {
    // Registrado aqui, e não na entrega: esta é a ordem em que o **cliente**
    // decidiu enviar, e é ela que a invariante interna 4 cobra. Reordenação da
    // rede não é desordem do cliente.
    final event = NetworkEvent('send', Fault.none, request.reference,
        request.key.value);
    log.add(event);

    if (reorderWindow <= 1) {
      return Future.value(_deliver(request, event));
    }
    final pending = _Pending(request, Completer<SendResult>(), event);
    _held.add(pending);
    if (_held.length >= reorderWindow) {
      // De trás para frente, de propósito.
      final batch = _held.reversed.toList();
      _held.clear();
      for (final held in batch) {
        held.completer.complete(_deliver(held.request, held.event));
      }
    }
    return pending.completer.future;
  }

  SendResult _deliver(OutboundRequest request, NetworkEvent event) {
    final fault = _nextFault();
    event.fault = fault;

    if (fault == Fault.keysExpired) server.expireKeys();

    switch (fault) {
      case Fault.offline:
        return const SendUnreachable();
      case Fault.processKilled:
        throw const ProcessKilled();
      case Fault.none || Fault.responseLost || Fault.keysExpired:
        break;
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
    log.add(NetworkEvent('lookupByKey', fault, '', key.value));
    if (fault == Fault.keysExpired) server.expireKeys();
    if (fault == Fault.processKilled) throw const ProcessKilled();
    if (fault == Fault.offline || fault == Fault.responseLost) {
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
    log.add(NetworkEvent('lookupByReference', fault, reference, ''));
    if (fault == Fault.keysExpired) server.expireKeys();
    if (fault == Fault.processKilled) throw const ProcessKilled();
    if (fault == Fault.offline || fault == Fault.responseLost) {
      return const ReferenceLookupFailed();
    }
    final effectId = server.effectForReference(reference);
    return effectId == null
        ? const ReferenceUntouched()
        : ReferenceSettled(effectId);
  }
}

final class _Pending {
  _Pending(this.request, this.completer, this.event);
  final OutboundRequest request;
  final Completer<SendResult> completer;
  final NetworkEvent event;
}
