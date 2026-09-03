import 'package:flutter/material.dart';
import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:outbox_example/demo_transport.dart';
import 'package:outbox_example/main.dart';

/// O exemplo tem um teste porque ele também é código do repositório. A prova de
/// verdade da camada 2 é o roteiro manual do README — este aqui só garante que
/// a tela monta e que os desfechos chegam nela.
void main() {
  testWidgets('a tela mostra o journal e enfileira sem rede', (tester) async {
    final transport = DemoTransport()..offline = true;
    final storage = InMemoryStorage();
    final outbox = Outbox(
      transport: transport,
      storage: storage,
      clock: FixedClock(DateTime.utc(2026, 3, 5)),
    );

    await tester.pumpWidget(MaterialApp(
      home: HomePage(outbox: outbox, transport: transport, storage: storage),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Nenhuma operação ainda'), findsOneWidget);

    await tester.tap(find.text('Pagar'));
    await tester.pumpAndSettle();

    // Sem rede, a operação fica na fila — e o app diz isso em vez de dar erro.
    expect(find.textContaining('Na fila'), findsOneWidget);
    expect(await storage.all(), hasLength(1));
  });
}
