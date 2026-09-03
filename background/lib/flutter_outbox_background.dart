/// A camada 3 do Flutter Outbox: o agendamento nativo de background.
///
/// **Pacote separado, e o motivo é o critério 2 de `docs/STACK.md`.** Este
/// código importa `package:flutter`, e `flutter_outbox` não pode — é o que
/// mantém as camadas 1 e 2 rodando em `dart test`, em segundos, sem SDK de UI.
/// Um pacote que depende de Flutter não roda em `dart test`, nem para as partes
/// que não usam Flutter.
///
/// Quem quer só o motor depende de `flutter_outbox`. Quem quer background em
/// aparelho depende dos dois.
library;

export 'src/background_scheduler.dart';
