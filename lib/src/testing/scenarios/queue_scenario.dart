import '../../core/outcome.dart';
import '../../core/storage.dart';
import '../scenario.dart';
import '../scripted_transport.dart';

/// Cenário 5 — partição com fila offline.
///
/// Em arquivo próprio porque ele sozinho ficou maior que os outros sete: a fila
/// tem **três** caminhos de entrada — `recover()`, `submit` de operação nova e
/// `submit` de operação que já está na fila — e o mesmo defeito de ordem
/// apareceu em todos, um de cada vez. `test/queue_discipline_test.dart` cobre
/// os três isoladamente; aqui eles aparecem juntos, na sequência em que um
/// usuário os produziria.
final scenario05 = Scenario(
  number: 5,
  name: 'partição com fila offline',
  ablationsThatMustFail: {},
  body: (run) async {
    final storage = InMemoryStorage();
    const enqueued = [
      ('transferencia-5a', 10000),
      ('transferencia-5b', 20000),
      ('transferencia-5c', 30000),
    ];

    // Sem rede: nada sai, e nada pode se perder.
    final offline = run.client(
      transport: run.transport(
        script: const [Fault.offline, Fault.offline, Fault.offline],
      ),
      storage: storage,
    );
    final violations = <String>[];
    for (final (reference, amount) in enqueued) {
      final result = await offline.submit(run.transfer(reference, amount));
      if (result is! Queued) {
        violations.add('cenário 5: $reference devolveu $result sem rede');
      }
    }

    // A rede volta **pela metade**: a primeira ainda não sai.
    //
    // É aqui que mora o caso que o roteiro de tudo-offline não alcança. Com
    // todas offline, nenhuma sai e a ordem se preserva por acidente; é quando
    // algumas podem sair que a promessa é cobrada. Se o motor seguir para a
    // segunda, ela é aplicada com a primeira ainda pendente, e a ordem de
    // enfileiramento quebra sem ninguém duplicar nada.
    final parcial = run.transport(
      script: const [Fault.offline, Fault.none, Fault.none],
    );
    await run.client(transport: parcial, storage: storage).recover();

    if (run.effectsFor(enqueued.first.$1) == 0 &&
        run.effectsFor(enqueued[1].$1) > 0) {
      violations.add(
        'cenário 5: ${enqueued[1].$1} foi aplicada com ${enqueued.first.$1} '
        'ainda pendente — ordem global estrita não deixa furar a fila',
      );
    }
    if (parcial.sends > 1) {
      violations.add(
        'cenário 5: ${parcial.sends} envios numa janela em que a primeira '
        'operação nem saiu — insistir atrás de uma parada gasta orçamento de '
        'background para descobrir a mesma coisa várias vezes',
      );
    }

    // E o usuário faz um pagamento **novo**, com a rede boa e a fila cheia.
    //
    // É o caso mais comum que existe — alguém paga no avião, aterrissa, paga de
    // novo — e é o caminho que o `recover()` não cobre: aqui a operação entra
    // por `submit`, não pela fila. Se ela sair na frente, a ordem de
    // enfileiramento quebra sem ninguém duplicar nada.
    final novo = run.transport();
    final resultado =
        await run.client(transport: novo, storage: storage).submit(
              run.transfer('transferencia-5d', 40000),
            );

    if (novo.sends > 0) {
      violations.add(
        'cenário 5: transferencia-5d saiu na rede com ${enqueued.length} '
        'operações pendentes à frente dela — submit não pode furar a fila',
      );
    }
    if (resultado is! Queued) {
      violations.add(
        'cenário 5: transferencia-5d devolveu $resultado; com fila à frente, '
        'o desfecho honesto é NaFila',
      );
    }

    // E o usuário toca de novo num pagamento que a tela mostra como pendente.
    //
    // Terceiro caminho para a mesma fila, e o mais fácil de esquecer: a
    // operação **já existe** no journal, então a checagem de "sou nova?" não a
    // alcança. Ela continua no meio da fila e continua tendo que esperar.
    final retoque = run.transport();
    final resultadoRetoque =
        await run.client(transport: retoque, storage: storage).submit(
              run.transfer(enqueued.last.$1, enqueued.last.$2),
            );

    if (retoque.sends > 0) {
      violations.add(
        'cenário 5: ${enqueued.last.$1} saiu na rede ao ser resubmetida, com '
        'operações à frente ainda pendentes — estar no journal não dá '
        'passagem na fila',
      );
    }
    if (resultadoRetoque is! Queued) {
      violations.add(
        'cenário 5: resubmeter ${enqueued.last.$1} devolveu $resultadoRetoque '
        'em vez de NaFila',
      );
    }

    // E então a rede volta de verdade.
    final online = run.transport();
    await run.client(transport: online, storage: storage).recover();

    final expectedOrder = [
      for (final (reference, _) in enqueued) reference,
      'transferencia-5d',
    ];
    if (online.referencesInSendOrder.join(',') != expectedOrder.join(',')) {
      violations.add(
        'cenário 5: a ordem de saída não é a de enfileiramento — '
        '${online.referencesInSendOrder.join(" → ")}',
      );
    }
    for (final reference in expectedOrder) {
      if (run.effectsFor(reference) != 1) {
        violations.add(
          'cenário 5: $reference tem ${run.effectsFor(reference)} efeitos',
        );
      }
    }
    return violations;
  },
);
