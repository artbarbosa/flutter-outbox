import 'package:flutter/material.dart';
import 'package:flutter_outbox/outbox.dart';
import 'package:flutter_outbox_background/flutter_outbox_background.dart';

import 'background_work.dart';
import 'demo_transport.dart';
import 'outbox_runtime.dart';

/// O app exemplo, e o que ele existe para provar:
///
/// > modo avião, três operações, **matar o app pelo gerenciador de tarefas**,
/// > reabrir, ligar a rede — e o ledger fecha com três efeitos, na ordem certa.
///
/// O roteiro completo está no README do repositório. Nada aqui é bonito de
/// propósito: a tela é um instrumento de medição, não um produto.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final runtime = await OutboxRuntime.open(owner: 'ui');
  final scheduler = BackgroundScheduler();

  // Diz ao nativo qual função chamar quando a janela vier, e pede a primeira.
  // As duas coisas são baratas e idempotentes: chamar de novo não empilha
  // trabalho.
  await scheduler.registerEntrypoint(drainInBackground);
  await scheduler.schedule();

  runApp(ExampleApp(
    outbox: runtime.outbox,
    transport: runtime.transport,
    storage: runtime.storage,
  ));
}

/// O ponto de entrada da janela de background.
///
/// Precisa ser **função de topo** e anotada: uma closure não tem handle, e sem
/// a anotação o tree shaking remove isto do build de release. Nos dois casos a
/// falha aparece só no aparelho, e como uma janela que roda e não faz nada.
@pragma('vm:entry-point')
Future<void> drainInBackground() async {
  // O app pode estar fechado: aqui não há `runApp`, não há widget, e o binding
  // precisa ser inicializado à mão para os canais de plataforma funcionarem.
  WidgetsFlutterBinding.ensureInitialized();

  BackgroundScheduler().onBackgroundWork(() async {
    // Dono diferente do da tela: se o usuário abrir o app agora, o lease decide
    // quem esvazia a fila, e o outro não gasta envio à toa.
    final runtime = await OutboxRuntime.open(owner: 'background');
    try {
      return await drainQueue(runtime.outbox, runtime.storage);
    } finally {
      await runtime.close();
    }
  });
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({
    super.key,
    required this.outbox,
    required this.transport,
    required this.storage,
  });

  final Outbox outbox;
  final DemoTransport transport;
  final SqliteStorage storage;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Outbox',
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: HomePage(
        outbox: outbox,
        transport: transport,
        storage: storage,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.outbox,
    required this.transport,
    required this.storage,
  });

  final Outbox outbox;
  final DemoTransport transport;

  /// A interface, e não a implementação: o teste do widget passa um storage em
  /// memória, e a tela não precisa saber a diferença.
  final Storage storage;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<JournalEntry> _journal = const [];
  int _counter = 0;
  bool _recovering = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // No start do app: é isto que fecha o que ficou em aberto quando o processo
    // morreu. Sem esta linha, o roteiro manual não funciona.
    _recover();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Voltar do segundo plano é o outro momento em que vale tentar de novo.
    if (state == AppLifecycleState.resumed) _recover();
  }

  Future<void> _refresh() async {
    final journal = await widget.storage.all();
    if (mounted) setState(() => _journal = journal);
  }

  Future<void> _recover() async {
    if (_recovering) return;
    setState(() => _recovering = true);
    try {
      await widget.outbox.recover();
    } finally {
      if (mounted) setState(() => _recovering = false);
      await _refresh();
    }
  }

  Future<void> _submit() async {
    // A referência de negócio é gerada e persistida **antes** do envio, e é
    // isto que o README chama de "o trabalho que o pacote empurra para quem
    // usa". Sem uma identidade estável da intenção, não há chave estável.
    final reference = 'pagamento-${DateTime.now().millisecondsSinceEpoch}'
        '-${++_counter}';
    await _refresh();

    final result = await widget.outbox.submit(Operation(
      reference: reference,
      payload: {
        'from': 'conta-a',
        'to': 'conta-b',
        // Dinheiro é int em centavos. Sempre.
        'amountInCents': 1500 * _counter,
      },
    ));

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(_describe(result))),
    );
    await _refresh();
  }

  String _describe(SubmitOutcome outcome) => switch (outcome) {
        Settled(:final effectId) => 'Liquidado: $effectId',
        Rejected(:final reason) => 'Recusado: $reason',
        Queued() => 'Na fila — sem rede, nada se perdeu',
        // "Sem desfecho" **não é erro**, e mostrar erro aqui é a mentira que
        // vira cobrança dupla.
        Undetermined() => 'Processando — recover() fecha depois',
      };

  @override
  Widget build(BuildContext context) {
    final offline = widget.transport.offline;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Flutter Outbox'),
        actions: [
          IconButton(
            tooltip: offline ? 'Ligar a rede' : 'Modo avião',
            icon: Icon(offline ? Icons.airplanemode_active : Icons.wifi),
            onPressed: () {
              setState(() => widget.transport.offline = !offline);
              if (!widget.transport.offline) _recover();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (_recovering) const LinearProgressIndicator(),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              offline
                  ? 'Sem rede. Enfileire três pagamentos, mate o app pelo '
                      'gerenciador de tarefas, reabra e ligue a rede.'
                  : 'Metade dos envios perde a resposta na volta. Nenhum '
                      'pagamento pode acontecer duas vezes.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _journal.isEmpty
                ? const Center(child: Text('Nenhuma operação ainda'))
                : ListView.builder(
                    itemCount: _journal.length,
                    itemBuilder: (context, index) {
                      final entry = _journal[index];
                      return ListTile(
                        dense: true,
                        leading: Text('#${entry.sequence}'),
                        title: Text(entry.reference),
                        subtitle: Text(
                          '${entry.state.name} · ${entry.attempts} tentativa(s)'
                          '${entry.effectId == null ? "" : " · ${entry.effectId}"}',
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _submit,
        icon: const Icon(Icons.payment),
        label: const Text('Pagar'),
      ),
    );
  }
}
