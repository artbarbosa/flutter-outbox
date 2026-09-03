import 'dart:math';

import 'package:flutter_outbox/outbox.dart';

/// O transporte do exemplo: um servidor de mentira, com falha de mentira.
///
/// Em um app de verdade **isto é o único arquivo que você escreve** — ele fala
/// com o seu backend, e o resto do pacote não muda. Aqui ele simula latência e
/// perda de resposta para o roteiro manual ter o que demonstrar sem depender de
/// rede nenhuma.
final class DemoTransport implements Transport {
  DemoTransport({int seed = 1}) : _random = Random(seed);

  final Random _random;

  /// O "servidor": chave → efeito, e referência → efeito.
  final Map<String, String> _byKey = {};
  final Map<String, String> _byReference = {};
  int _effects = 0;

  /// Ligado pelo botão de modo avião da tela.
  bool offline = false;

  /// Com que frequência a resposta se perde na volta. É o caso que o pacote
  /// existe para resolver, e o exemplo precisa produzi-lo de propósito.
  double responseLossRate = 0.5;

  final List<String> log = [];

  @override
  Future<SendResult> send(OutboundRequest request) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (offline) {
      log.add('envio de ${request.reference}: sem rede');
      return const SendUnreachable();
    }

    final known = _byKey[request.key.value];
    final effectId = known ?? 'efeito-${++_effects}';
    if (known == null) {
      _byKey[request.key.value] = effectId;
      _byReference[request.reference] = effectId;
    }

    if (_random.nextDouble() < responseLossRate) {
      // O servidor **aplicou**, e a resposta não volta. O cliente não tem como
      // distinguir isto de "não chegou".
      log.add('envio de ${request.reference}: aplicado, resposta perdida');
      return const SendLost();
    }

    log.add('envio de ${request.reference}: '
        '${known == null ? "aplicado" : "replay"} $effectId');
    return known == null ? SendApplied(effectId) : SendReplayed(effectId);
  }

  @override
  Future<KeyLookup> lookupByKey(IdempotencyKey key) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (offline) {
      log.add('consulta por chave: sem rede');
      return const KeyLookupFailed();
    }
    final effectId = _byKey[key.value];
    log.add('consulta por chave: ${effectId ?? "desconhecida"}');
    return effectId == null ? const KeyUnknown() : KeyKnown(effectId);
  }

  @override
  Future<ReferenceLookup> lookupByReference(String reference) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (offline) {
      log.add('consulta por referência: sem rede');
      return const ReferenceLookupFailed();
    }
    final effectId = _byReference[reference];
    log.add('consulta por referência $reference: ${effectId ?? "nada"}');
    return effectId == null
        ? const ReferenceUntouched()
        : ReferenceSettled(effectId);
  }
}
