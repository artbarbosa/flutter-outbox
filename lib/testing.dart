/// O servidor falso, o transporte com falha injetada e os quatro clientes.
///
/// Fica em `lib/` de propósito, e não em `test/`: eles são parte da entrega.
/// Quem depende deste pacote precisa conseguir usá-los para testar o próprio
/// código sem rede, conta ou contêiner.
library;

export 'src/testing/checks.dart';
export 'src/testing/clients.dart';
export 'src/testing/fake_server.dart';
export 'src/testing/layer1_scenarios.dart';
export 'src/testing/scenarios/queue_scenario.dart';
export 'src/testing/ledger.dart';
export 'src/testing/scenario.dart';
export 'src/testing/scripted_transport.dart';
export 'src/testing/shrink.dart';
export 'src/testing/soak.dart';
