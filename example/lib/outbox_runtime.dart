import 'package:flutter_outbox/outbox.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show databaseFactory;

import 'demo_transport.dart';

/// A composição raiz, num arquivo só.
///
/// Existe separada da tela porque **a janela de background monta o mesmo
/// outbox sem UI nenhuma**: quando o sistema acorda o app, não há `runApp`, não
/// há widget, e ainda assim a fila precisa ser esvaziada com o mesmo motor,
/// sobre o mesmo banco.
///
/// É o encaixe que `docs/ARCHITECTURE.md` descreve: a camada 3 aciona o motor a
/// partir de um ponto de entrada diferente, e o núcleo não muda por causa disso.
final class OutboxRuntime {
  OutboxRuntime._(this.outbox, this.transport, this.storage);

  final Outbox outbox;
  final DemoTransport transport;
  final SqliteStorage storage;

  /// [owner] identifica quem está com o lease: a tela e a janela de background
  /// são donos diferentes, e é isso que impede as duas de esvaziarem a fila ao
  /// mesmo tempo.
  static Future<OutboxRuntime> open({required String owner}) async {
    final directory = await getApplicationDocumentsDirectory();
    final storage = await SqliteStorage.open(
      // A factory do aparelho. O pacote não sabe qual é, e é isso que mantém o
      // núcleo dele rodando em `dart test`.
      databaseFactory,
      path: p.join(directory.path, 'outbox.db'),
    );
    final transport = DemoTransport();
    return OutboxRuntime._(
      Outbox(
        transport: transport,
        storage: storage,
        // A composição raiz é o único lugar do app onde o relógio de verdade
        // entra.
        clock: const SystemClock(),
        lock: SqliteLease(storage.database, owner: owner),
      ),
      transport,
      storage,
    );
  }

  Future<void> close() => storage.close();
}
