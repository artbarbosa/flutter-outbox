import 'package:flutter_outbox/outbox.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';

/// Um `SqliteStorage` limpo, destruído no fim do teste.
///
/// **Use isto em vez de `SqliteStorage.open` direto.** `inMemoryDatabasePath`
/// não dá um banco por conexão: ele é **compartilhado**, e duas chamadas
/// devolvem o mesmo banco. Um teste que abre e não fecha entrega os próprios
/// dados para o teste seguinte, e a suíte passa a depender da ordem de
/// execução — o tipo de falha que aparece em outra máquina, ou meses depois,
/// quando alguém acrescenta um teste no meio.
///
/// O `addTearDown` aqui é o que garante o isolamento: quando a última conexão
/// fecha, o banco em memória deixa de existir. O compartilhamento em si é útil
/// e o cenário 12 depende dele — duas instâncias precisam mesmo ver o mesmo
/// banco. O que não pode é atravessar a fronteira de um teste.
Future<SqliteStorage> openTestStorage() async {
  final storage =
      await SqliteStorage.open(databaseFactoryFfi, path: inMemoryDatabasePath);
  addTearDown(storage.close);
  return storage;
}
