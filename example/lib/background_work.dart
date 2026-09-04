import 'package:flutter_outbox/outbox.dart';

/// O que a janela de background faz, sem nada de plataforma.
///
/// Separado de `main.dart` para poder ser testado: lá em cima há
/// `path_provider`, `sqflite` e um `MethodChannel`, e nenhum dos três roda numa
/// suíte headless. Aqui não há nenhum, e é este o código que decide o que o
/// sistema operacional ouve de volta.
///
/// Devolve `true` quando a fila esvaziou. `false` vira `Result.retry()` no
/// Android, e é o que faz a próxima janela tentar de novo — **uma fila que não
/// esvaziou não é uma fila perdida**.
Future<bool> drainQueue(Outbox outbox, Storage storage) async {
  await outbox.recover();

  // Uma linha só: a pergunta é "sobrou alguma?", e não "quantas sobraram".
  final pendentes = await storage.unfinished(limit: 1);
  return pendentes.isEmpty;
}
