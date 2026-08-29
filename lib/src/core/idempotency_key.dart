/// O token que o servidor usa para reconhecer uma operação que já viu.
///
/// É um tipo próprio, e não uma `String`, para que trocá-lo por uma referência
/// de negócio ou por um id de tentativa seja um erro de compilação em vez de um
/// bug silencioso.
final class IdempotencyKey {
  const IdempotencyKey(this.value);

  final String value;

  @override
  bool operator ==(Object other) =>
      other is IdempotencyKey && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}
