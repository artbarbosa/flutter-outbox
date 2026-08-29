/// A única fonte de tempo do pacote.
///
/// `DateTime.now()` fora da composição raiz torna o teste dependente do relógio
/// da máquina e faz o soak parar de reproduzir — ver `docs/PITFALLS.md`, seção
/// Tempo. Tudo aqui é UTC: horário local muda de valor quando o aparelho troca
/// de fuso, e ordenação por tempo local quebra duas vezes por ano.
abstract interface class Clock {
  DateTime nowUtc();
}

/// Para a composição raiz do app. Nunca dentro do motor.
final class SystemClock implements Clock {
  const SystemClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}

/// Relógio controlado, para cenário e soak.
///
/// Ele pode estar **errado** de propósito: o cenário 8 depende disso, e a
/// defesa do projeto não é sincronizar o relógio — é não depender dele.
final class FixedClock implements Clock {
  FixedClock(this._now);

  DateTime _now;

  @override
  DateTime nowUtc() => _now;

  void advance(Duration by) => _now = _now.add(by);
}
