import 'dart:math';

/// Onde o pacote espera.
///
/// Injetável pelo mesmo motivo que o `Clock`: uma suíte que espera de verdade
/// deixa de rodar em segundos, e aí ninguém a roda. O padrão do app é
/// [RealDelay]; os testes usam algo que registra o pedido sem dormir.
abstract interface class Delay {
  Future<void> wait(Duration duration);
}

/// Para a composição raiz do app.
final class RealDelay implements Delay {
  const RealDelay();

  @override
  Future<void> wait(Duration duration) =>
      duration <= Duration.zero ? Future.value() : Future.delayed(duration);
}

/// Não espera, e **registra o que teria esperado**.
///
/// É o que permite testar a política de espera sem pagar por ela: as durações
/// pedidas ficam em [waits], e um teste afirma sobre elas em milissegundos de
/// execução.
final class RecordedDelay implements Delay {
  final List<Duration> waits = [];

  @override
  Future<void> wait(Duration duration) async => waits.add(duration);
}

/// Quanto esperar antes de tentar de novo.
///
/// Separado de [Delay] de propósito: um decide **quanto**, o outro **como**. A
/// política é do domínio e vai para a documentação; a espera é infraestrutura e
/// vai para o teste.
abstract interface class RetrySchedule {
  /// [attemptNumber] é 1-based. A primeira tentativa nunca espera.
  Duration beforeAttempt(int attemptNumber);
}

/// Sem espera nenhuma. É o padrão da camada 1 e o que a medição usa.
final class NoBackoff implements RetrySchedule {
  const NoBackoff();

  @override
  Duration beforeAttempt(int attemptNumber) => Duration.zero;
}

/// Dobra a cada tentativa, com teto e com jitter.
///
/// **O teto não é conforto.** Sem ele, uma fila que passou dias offline acorda
/// com esperas de horas, e a operação da frente segura todas as outras por todo
/// esse tempo — com a ordem estrita deste pacote, o custo de um backoff sem
/// teto é a fila inteira.
///
/// **O jitter também não.** Sem ele, todos os aparelhos que perderam a rede no
/// mesmo instante voltam no mesmo instante, e o servidor que caiu recebe a
/// tempestade inteira de uma vez. A aleatoriedade entra por [seed], como todo o
/// resto deste repositório: mesma seed, mesma sequência de esperas.
final class ExponentialBackoff implements RetrySchedule {
  ExponentialBackoff({
    this.base = const Duration(seconds: 2),
    this.cap = const Duration(minutes: 5),
    this.jitter = 0.2,
    int seed = 0,
  })  : _random = Random(seed),
        assert(jitter >= 0 && jitter <= 1, 'jitter é uma fração de 0 a 1');

  final Duration base;
  final Duration cap;

  /// Fração da espera que varia. `0.2` significa ±20%.
  final double jitter;

  final Random _random;

  @override
  Duration beforeAttempt(int attemptNumber) {
    if (attemptNumber <= 1) return Duration.zero;

    // `1 << n` estoura rápido; o teto é aplicado sobre os microssegundos antes
    // de virar `Duration`, e não depois.
    final exponent = attemptNumber - 2;
    final scaled = exponent >= 32
        ? cap.inMicroseconds
        : min(base.inMicroseconds << exponent, cap.inMicroseconds);

    if (jitter == 0) return Duration(microseconds: scaled);

    final spread = (scaled * jitter).round();
    final offset = _random.nextInt(spread * 2 + 1) - spread;
    return Duration(microseconds: max(0, scaled + offset));
  }
}
