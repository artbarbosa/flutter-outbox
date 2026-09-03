import 'scripted_transport.dart';

/// Um roteiro que reprova, com o tamanho que ele tem.
final class FailingCase {
  const FailingCase({required this.operations, required this.script});

  final int operations;
  final List<Fault> script;

  /// Quantas falhas de verdade sobraram. É o número que diz se a redução
  /// funcionou: um roteiro de 2500 posições com três falhas é legível.
  int get faults => script.where((f) => f != Fault.none).length;

  @override
  String toString() {
    final positions = <String>[
      for (var i = 0; i < script.length; i++)
        if (script[i] != Fault.none) '$i:${script[i].name}',
    ];
    return '$operations operações, ${positions.length} falhas '
        '[${positions.join(", ")}]';
  }
}

/// "Este roteiro ainda reprova?"
typedef StillFails = Future<bool> Function(FailingCase candidate);

/// Encurta um roteiro que reprovou até o menor que ainda reprova.
///
/// Uma seed que quebra com 25 operações é um relatório ilegível: ninguém lê
/// 2500 posições de falha para descobrir qual delas importava. Reduzir é o que
/// transforma um soak vermelho em um cenário que cabe na cabeça — e é
/// pré-requisito para a regra de `docs/TESTING.md` de que **seed que reprovar
/// vira um cenário nomeado**.
///
/// É busca binária sobre uma lista, no vocabulário do domínio — operação e
/// falha — e não sobre o vocabulário genérico de um gerador. `docs/STACK.md`
/// explica por que isto é escrito à mão em vez de vir de biblioteca; escrever
/// só ganha do que existe quando o que existe está parado há dois anos, e este
/// é o caso.
///
/// A redução é **monotônica**: cada passo só é aceito se o caso menor continuar
/// reprovando, então o retorno reprova tanto quanto a entrada.
Future<FailingCase> shrink(
  FailingCase failing,
  StillFails stillFails, {
  int maxRounds = 10,
}) async {
  if (!await stillFails(failing)) {
    throw ArgumentError(
      'o caso dado não reprova, e reduzir um caso que passa não quer dizer '
      'nada: $failing',
    );
  }

  var best = failing;
  for (var round = 0; round < maxRounds; round++) {
    final before = (best.operations, best.faults);

    best = await _fewerOperations(best, stillFails);
    best = await _fewerFaults(best, stillFails);
    best = await _shorterScript(best, stillFails);

    // Passou uma rodada inteira sem encolher: chegou no menor que esta busca
    // sabe encontrar.
    if ((best.operations, best.faults) == before) break;
  }
  return best;
}

/// Menos operações, por busca binária.
///
/// Metade das operações, um quarto, e assim por diante — enquanto continuar
/// reprovando. É o corte que mais encurta o relatório, e por isso vem primeiro.
Future<FailingCase> _fewerOperations(
  FailingCase best,
  StillFails stillFails,
) async {
  var current = best;
  var step = current.operations ~/ 2;
  while (step >= 1) {
    final candidate = FailingCase(
      operations: current.operations - step,
      script: current.script,
    );
    if (candidate.operations >= 1 && await stillFails(candidate)) {
      current = candidate;
    } else {
      step ~/= 2;
    }
  }
  return current;
}

/// Menos falhas, em blocos que vão diminuindo.
///
/// Tenta apagar metade das falhas de uma vez; se o caso parar de reprovar,
/// tenta blocos menores. Delta debugging, com o bloco medido em falhas e não em
/// posições — 2500 posições com três falhas tornariam a busca por posição um
/// desperdício.
Future<FailingCase> _fewerFaults(
  FailingCase best,
  StillFails stillFails,
) async {
  var current = best;
  var block = current.faults;
  while (block >= 1) {
    var progressed = false;
    for (var offset = 0; offset < current.faults; offset += block) {
      final candidate = FailingCase(
        operations: current.operations,
        script: _withoutFaults(current.script, from: offset, count: block),
      );
      if (await stillFails(candidate)) {
        current = candidate;
        progressed = true;
        // O índice das falhas mudou; recomeça este tamanho de bloco.
        break;
      }
    }
    if (!progressed) block ~/= 2;
  }
  return current;
}

/// Corta a cauda inerte do roteiro.
///
/// Só cosmético, e mesmo assim vale: um roteiro com 2500 posições assusta quem
/// abre o relatório, mesmo quando 2490 delas são `Fault.none`.
Future<FailingCase> _shorterScript(
  FailingCase best,
  StillFails stillFails,
) async {
  final lastFault =
      best.script.lastIndexWhere((fault) => fault != Fault.none);
  if (lastFault == best.script.length - 1) return best;

  final candidate = FailingCase(
    operations: best.operations,
    script: best.script.sublist(0, lastFault + 1),
  );
  return await stillFails(candidate) ? candidate : best;
}

/// Apaga [count] falhas a partir da [from]-ésima, contando só as que são falha.
List<Fault> _withoutFaults(
  List<Fault> script, {
  required int from,
  required int count,
}) {
  final reduced = List<Fault>.from(script);
  var seen = 0;
  for (var i = 0; i < reduced.length; i++) {
    if (reduced[i] == Fault.none) continue;
    if (seen >= from && seen < from + count) reduced[i] = Fault.none;
    seen++;
  }
  return reduced;
}
