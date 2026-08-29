import 'dart:convert';

/// Serializa em JSON com as chaves de todo mapa em ordem, recursivamente.
///
/// Existe para que a mesma intenção produza sempre os mesmos bytes: sem isto,
/// `{'from': a, 'to': b}` e `{'to': b, 'from': a}` teriam impressões digitais
/// diferentes, e a detecção de conflito de payload do cenário 7 viraria ruído.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _write(value, buffer);
  return buffer.toString();
}

void _write(Object? value, StringBuffer out) {
  switch (value) {
    case null || bool() || num():
      out.write(jsonEncode(value));
    case String():
      out.write(jsonEncode(value));
    case List():
      out.write('[');
      for (var i = 0; i < value.length; i++) {
        if (i > 0) out.write(',');
        _write(value[i], out);
      }
      out.write(']');
    case Map():
      final keys = value.keys.map((Object? k) => k.toString()).toList()..sort();
      out.write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out
          ..write(jsonEncode(keys[i]))
          ..write(':');
        _write(value[keys[i]], out);
      }
      out.write('}');
    default:
      throw ArgumentError.value(
        value,
        'value',
        'payload só aceita JSON: null, bool, num, String, List, Map',
      );
  }
}

/// FNV-1a de 64 bits, em duas metades de 32.
///
/// Não é criptográfico e não precisa ser. O que se exige aqui é **estabilidade
/// entre execuções e máquinas**, que `String.hashCode` não garante — e a chave
/// de idempotência de uma operação que sobreviveu a um restart do processo
/// precisa sair igual. As duas metades de 32 bits existem para a aritmética não
/// depender de `int` de 64 bits, que a compilação para web não tem.
String fingerprint(String input) {
  final bytes = utf8.encode(input);
  final low = _fnv1a32(bytes, 0x811c9dc5);
  final high = _fnv1a32(bytes, 0x01000193);
  return '${_hex8(high)}${_hex8(low)}';
}

int _fnv1a32(List<int> bytes, int basis) {
  var hash = basis;
  for (final byte in bytes) {
    hash ^= byte;
    // hash * 16777619, decomposto em somas e deslocamentos: 32×32 estoura os
    // 53 bits de precisão de um double, e a multiplicação direta divergiria
    // entre a VM e a web.
    hash = (hash +
            ((hash << 1) & 0xFFFFFFFF) +
            ((hash << 4) & 0xFFFFFFFF) +
            ((hash << 7) & 0xFFFFFFFF) +
            ((hash << 8) & 0xFFFFFFFF) +
            ((hash << 24) & 0xFFFFFFFF)) &
        0xFFFFFFFF;
  }
  return hash;
}

String _hex8(int value) => value.toRadixString(16).padLeft(8, '0');
