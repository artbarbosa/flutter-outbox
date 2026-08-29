import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox/testing.dart';
import 'package:test/test.dart';

/// O servidor falso não é um dublê: é uma implementação determinística de
/// verdade, e a suíte inteira depende de ele estar certo. Testar o instrumento
/// antes de medir com ele.
void main() {
  late FakeServer server;

  setUp(() => server = FakeServer(openingBalances: {'a': 100000, 'b': 0}));

  OutboundRequest request({
    String key = 'k1',
    String reference = 'ref-1',
    int amountInCents = 15000,
  }) {
    final operation = Operation(
      reference: reference,
      payload: {'from': 'a', 'to': 'b', 'amountInCents': amountInCents},
    );
    return OutboundRequest(
      key: IdempotencyKey(key),
      reference: reference,
      payload: operation.payload,
      payloadFingerprint: operation.payloadFingerprint,
    );
  }

  test('aplica uma vez e registra no ledger', () {
    expect(server.apply(request()), isA<ServerApplied>());
    expect(server.ledger.entries, hasLength(1));
    expect(server.ledger.balanceOf('b'), 15000);
  });

  test('a mesma chave com o mesmo payload é replay, e não um efeito novo', () {
    final first = server.apply(request()) as ServerApplied;
    final second = server.apply(request());

    expect(second, isA<ServerReplayed>());
    expect((second as ServerReplayed).effectId, first.effectId);
    expect(server.ledger.entries, hasLength(1));
  });

  test('a mesma chave com outro payload é recusada, e não sobrescreve', () {
    server.apply(request());
    final conflict = server.apply(request(amountInCents: 99000));

    expect(conflict, isA<ServerRefused>());
    expect(server.ledger.entries, hasLength(1));
    expect(server.ledger.balanceOf('b'), 15000);
  });

  test('o ledger não deduplica: chave nova aplica de novo', () {
    server.apply(request(key: 'k1'));
    server.apply(request(key: 'k2'));

    // É esta a regra que dá dente à suíte. Se o servidor deduplicasse por
    // referência, os cenários passariam por causa dele, e não por causa da
    // corretude do cliente.
    expect(server.ledger.entries, hasLength(2));
    expect(server.ledger.duplications, 1);
    expect(server.ledger.sumsUp, isTrue);
  });

  test('a chave expira e o ledger não', () {
    final applied = server.apply(request()) as ServerApplied;
    expect(server.effectForKey(const IdempotencyKey('k1')), applied.effectId);

    server.expireKeys();

    expect(server.effectForKey(const IdempotencyKey('k1')), isNull);
    expect(server.effectForReference('ref-1'), applied.effectId);
  });
}
