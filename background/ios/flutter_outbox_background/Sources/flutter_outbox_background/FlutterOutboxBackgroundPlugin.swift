import BackgroundTasks
import Flutter
import UIKit

/// O lado iOS do platform channel, escrito à mão sobre `BGTaskScheduler`.
///
/// **Leia isto antes de confiar em qualquer teste desta classe.** O
/// `BGTaskScheduler` não roda no simulador, e um aparelho conectado ao Xcode
/// não entra em background de verdade. O que existe é um par de helpers
/// privados de LLDB — `_simulateLaunchForTaskWithIdentifier:` e
/// `_simulateExpirationForTaskWithIdentifier:` — que disparam o handler à mão.
///
/// Eles exercitam **este** código e **pulam o agendador inteiro**. Passar com
/// eles prova que o handler funciona quando chamado; não prova nada sobre ser
/// chamado. O cenário 15 de `docs/TESTING.md` só fecha em aparelho solto, ao
/// longo de dias.
public class FlutterOutboxBackgroundPlugin: NSObject, FlutterPlugin {

  /// Precisa ser idêntico ao `BackgroundScheduler.channelName` do Dart e ao
  /// `CHANNEL_NAME` do Kotlin. Se divergirem, a chamada some sem erro.
  static let channelName = "flutter_outbox/background"

  /// O identificador da tarefa. Além de bater com o Dart e o Kotlin, ele
  /// **precisa estar no `Info.plist`**, em `BGTaskSchedulerPermittedIdentifiers`
  /// — sem isso o registro lança em tempo de execução, e só no aparelho.
  static let taskIdentifier = "com.example.flutter_outbox.drain"

  private var channel: FlutterMethodChannel?

  /// Quanto tempo depois de agora a janela pode vir, quando o Dart não diz.
  private var earliest: TimeInterval = 15 * 60
  private var requiresNetwork = true

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterOutboxBackgroundPlugin()
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    instance.channel = channel
    registrar.addMethodCallDelegate(instance, channel: channel)

    // O registro tem que acontecer **antes de o app terminar de iniciar**, e
    // uma única vez por identificador. Registrar depois, ou duas vezes, lança.
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: taskIdentifier,
      using: nil
    ) { task in
      instance.handle(task: task)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "schedule":
      let arguments = call.arguments as? [String: Any]
      if let seconds = arguments?["earliestSeconds"] as? NSNumber {
        earliest = seconds.doubleValue
      }
      requiresNetwork = arguments?["requiresNetwork"] as? Bool ?? true
      schedule()
      result(nil)

    case "cancel":
      BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
      result(nil)

    case "registerEntrypoint":
      // O iOS não precisa de callback handle: quando a janela vem, o app é
      // acordado com o motor Dart que ele já tinha. Aceitar a chamada e não
      // fazer nada mantém a API igual nas duas plataformas.
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func schedule() {
    let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
    request.requiresNetworkConnectivity = requiresNetwork
    request.requiresExternalPower = false

    // Submeter de novo com o mesmo identificador **substitui** o pedido
    // anterior, e é isso que se quer: empilhar trabalho gasta o orçamento de
    // execução do app, e o sistema pune as janelas seguintes de quem faz isso.
    do {
      try BGTaskScheduler.shared.submit(request)
    } catch {
      // Falhar em agendar não perde nada: a fila continua no journal, e a
      // próxima abertura do app tenta de novo. Nada aqui pode expirar por não
      // ter rodado.
      NSLog("flutter_outbox: não foi possível agendar — \(error)")
    }
  }

  private func handle(task: BGTask) {
    // A janela seguinte é pedida **agora**, antes do trabalho: se o sistema
    // encerrar esta tarefa no meio, o pedido já está feito.
    schedule()

    task.expirationHandler = {
      // O sistema está encerrando a tarefa. Não há nada a desfazer: o journal
      // foi gravado antes de cada envio, e a próxima janela retoma de onde
      // parou. É o cenário 13.
      task.setTaskCompleted(success: false)
    }

    guard let channel = channel else {
      task.setTaskCompleted(success: false)
      return
    }

    channel.invokeMethod("runBackgroundWork", arguments: nil) { result in
      let finished = (result as? Bool) ?? false
      task.setTaskCompleted(success: finished)
    }
  }
}
