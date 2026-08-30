import '../core/clock.dart';
import '../core/decisions.dart';
import '../core/engine.dart';
import '../core/invariants.dart';
import '../core/journal.dart';
import '../core/operation.dart';
import '../core/storage.dart';
import '../core/transport.dart';
import 'checks.dart';
import 'clients.dart';
import 'fake_server.dart';
import 'scripted_transport.dart';

/// Um cenário adversarial, definido **uma vez** e executável por qualquer um
/// dos quatro clientes.
///
/// É essa reutilização que permite ao estudo de ablação afirmar alguma coisa:
/// se cada cenário fosse escrito duas vezes — uma para o teste, outra para a
/// ablação —, as duas cópias divergiriam e a tabela viraria decoração.
final class Scenario {
  const Scenario({
    required this.number,
    required this.name,
    required this.body,
    required this.ablationsThatMustFail,
  });

  final int number;

  /// A frase de `docs/TESTING.md`, para o documento e o código não divergirem.
  final String name;

  final Future<List<String>> Function(ScenarioRun run) body;

  /// A coluna da direita da tabela de ablações, virada do avesso.
  ///
  /// É uma **asserção**: quem não está aqui precisa passar. Ablação que reprova
  /// em cenário demais é ruído; ablação que passa em todos significa que a
  /// decisão dela não está sendo testada por nada.
  final Set<ClientKind> ablationsThatMustFail;

  @override
  String toString() => 'cenário $number — $name';
}

/// Uma execução de um cenário por um cliente.
///
/// Guarda o servidor, os storages e os transportes que o cenário criou, para o
/// runner poder verificar as invariantes sem o cenário ter que lembrar disso.
final class ScenarioRun {
  ScenarioRun({required this.kind, required this.invariantsEnabled});

  final ClientKind kind;

  /// Desligadas só na medição, que quer observar o dano em vez de abortar no
  /// primeiro sinal dele. Nunca em teste.
  final bool invariantsEnabled;

  /// Contas sintéticas, e valores em `int` de centavos. Sempre.
  static const openingBalances = {'conta-a': 1000000, 'conta-b': 0};

  late final FakeServer server = FakeServer(openingBalances: openingBalances);

  /// Uma só para todos os clientes do cenário: aparelhos diferentes produzem
  /// tentativas diferentes.
  final AttemptNonces nonces = AttemptNonces();

  final List<Storage> storages = [];
  final List<ScriptedTransport> transports = [];

  ScriptedTransport transport({
    List<Fault> script = const [],
    int reorderWindow = 1,
  }) {
    final created = ScriptedTransport(
      server: server,
      script: script,
      reorderWindow: reorderWindow,
    );
    transports.add(created);
    return created;
  }

  /// Um motor novo. Cada um traz o seu observador de invariantes internas: um
  /// processo novo tem um motor novo, e não herda o que o anterior tinha visto.
  Outbox client({
    required Transport transport,
    Storage? storage,
    Clock? clock,
    int maxAttempts = 3,
  }) {
    final chosen = storage ?? InMemoryStorage();
    if (!storages.contains(chosen)) storages.add(chosen);
    return buildClient(
      kind,
      transport: transport,
      storage: chosen,
      clock: clock,
      maxAttempts: maxAttempts,
      nonces: nonces,
      invariants: invariantsEnabled ? Invariants() : Invariants.off(),
    );
  }

  Operation transfer(String reference, int amountInCents) => Operation(
        reference: reference,
        payload: {
          'from': 'conta-a',
          'to': 'conta-b',
          'amountInCents': amountInCents,
        },
      );

  Future<List<List<JournalEntry>>> journals() async =>
      [for (final storage in storages) await storage.all()];

  /// Quantos efeitos existiram de verdade para uma referência.
  int effectsFor(String reference) =>
      server.ledger.forReference(reference).length;
}

/// O que sobrou de uma execução: vazio significa que o cliente passou.
final class ScenarioOutcome {
  const ScenarioOutcome(this.violations);

  final List<String> violations;

  bool get passed => violations.isEmpty;

  @override
  String toString() => passed ? 'passou' : violations.join('\n  ');
}

/// Roda um cenário com um cliente e devolve tudo que quebrou.
///
/// Não usa `expect`: o estudo de ablação precisa **medir** reprovação em vez de
/// interrompê-la, e uma violação interna que aborta é um resultado tão válido
/// quanto uma invariante externa que não fecha.
Future<ScenarioOutcome> runScenario(
  Scenario scenario,
  ClientKind kind, {
  bool invariantsEnabled = true,
}) async {
  final run = ScenarioRun(kind: kind, invariantsEnabled: invariantsEnabled);
  final violations = <String>[];

  try {
    violations.addAll(await scenario.body(run));
  } on InvariantViolation catch (error) {
    // Reprovou onde o defeito acontece, e não dez passos depois. É o melhor
    // tipo de reprovação que esta suíte sabe produzir.
    violations.add('interna ${error.invariant}: ${error.detail}');
  }

  violations.addAll(checkInvariants(
    server: run.server,
    journals: await run.journals(),
    sendOrder: run.transports.length == 1
        ? run.transports.single.referencesInSendOrder
        : null,
  ));

  return ScenarioOutcome(violations);
}
