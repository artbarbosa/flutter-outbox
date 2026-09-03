package com.example.flutter_outbox_background

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.FlutterCallbackInformation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume

/**
 * O que roda quando o sistema concede a janela.
 *
 * Sobe um motor Dart **headless** — sem UI, porque o app pode estar fechado —,
 * chama de volta o handler registrado por `onBackgroundWork`, e traduz a
 * resposta dele para o vocabulário do WorkManager.
 *
 * O sistema pode encerrar isto no meio, e nada aqui tenta impedir: quem garante
 * que a interrupção não deixa estado inconsistente é o journal, gravado antes
 * de cada envio. É o cenário 13 de `docs/TESTING.md`.
 */
class OutboxDrainWorker(
  context: Context,
  parameters: WorkerParameters
) : CoroutineWorker(context, parameters) {

  override suspend fun doWork(): Result = withContext(Dispatchers.Main) {
    val callbackHandle = applicationContext
      .getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
      .getLong(CALLBACK_HANDLE, 0L)

    if (callbackHandle == 0L) {
      // O app nunca registrou um ponto de entrada. Repetir não vai mudar isso.
      return@withContext Result.failure()
    }

    val engine = FlutterEngine(applicationContext)
    try {
      val callback = FlutterCallbackInformation.lookupCallbackInformation(callbackHandle)
        ?: return@withContext Result.failure()

      engine.dartExecutor.executeDartCallback(
        DartExecutor.DartCallback(
          applicationContext.assets,
          io.flutter.FlutterInjector.instance().flutterLoader().findAppBundlePath(),
          callback
        )
      )

      val channel = MethodChannel(
        engine.dartExecutor.binaryMessenger,
        FlutterOutboxBackgroundPlugin.CHANNEL_NAME
      )

      val finished = suspendCancellableCoroutine { continuation ->
        channel.invokeMethod("runBackgroundWork", null, object : MethodChannel.Result {
          override fun success(result: Any?) {
            continuation.resume(result as? Boolean ?: false)
          }

          override fun error(code: String, message: String?, details: Any?) {
            // Erro não é "desista": a fila continua no journal, e a próxima
            // janela tenta de novo.
            continuation.resume(false)
          }

          override fun notImplemented() = continuation.resume(false)
        })
      }

      // `retry` e não `failure`: uma fila que não esvaziou não é uma fila
      // perdida, e nada aqui pode expirar por não ter rodado.
      if (finished) Result.success() else Result.retry()
    } finally {
      engine.destroy()
    }
  }

  companion object {
    const val PREFERENCES = "flutter_outbox_background"
    const val CALLBACK_HANDLE = "callback_handle"
  }
}
