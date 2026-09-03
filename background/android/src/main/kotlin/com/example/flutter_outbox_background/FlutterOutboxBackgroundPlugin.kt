package com.example.flutter_outbox_background

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.TimeUnit

/**
 * O lado Android do platform channel, escrito à mão sobre `androidx.work`.
 *
 * Existem plugins que embrulham o WorkManager. Usá-los esvaziaria esta camada,
 * que existe para demonstrar escrita de módulo nativo — é escolha de propósito,
 * registrada em `docs/STACK.md`.
 */
class FlutterOutboxBackgroundPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {

  private lateinit var channel: MethodChannel
  private lateinit var context: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
    channel.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    when (call.method) {
      "schedule" -> {
        val earliestSeconds = (call.argument<Int>("earliestSeconds") ?: 900).toLong()
        val requiresNetwork = call.argument<Boolean>("requiresNetwork") ?: true
        schedule(earliestSeconds, requiresNetwork)
        result.success(null)
      }
      "registerEntrypoint" -> {
        val handle = call.argument<Number>("handle")?.toLong()
        if (handle == null) {
          result.error("sem-handle", "registerEntrypoint exige um handle", null)
        } else {
          // Em SharedPreferences porque precisa sobreviver à morte do processo:
          // quando a janela vier, o app pode estar fechado há dias.
          context.getSharedPreferences(OutboxDrainWorker.PREFERENCES, Context.MODE_PRIVATE)
            .edit()
            .putLong(OutboxDrainWorker.CALLBACK_HANDLE, handle)
            .apply()
          result.success(null)
        }
      }
      "cancel" -> {
        WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  private fun schedule(earliestSeconds: Long, requiresNetwork: Boolean) {
    val constraints = Constraints.Builder()
      .setRequiredNetworkType(
        if (requiresNetwork) NetworkType.CONNECTED else NetworkType.NOT_REQUIRED
      )
      .build()

    val request = OneTimeWorkRequestBuilder<OutboxDrainWorker>()
      .setInitialDelay(earliestSeconds, TimeUnit.SECONDS)
      .setConstraints(constraints)
      .build()

    // REPLACE, e não APPEND: chamar `schedule` duas vezes precisa deixar uma
    // tarefa só. Empilhar trabalho gasta o orçamento de execução do app, e o
    // sistema pune as janelas seguintes de quem faz isso.
    WorkManager.getInstance(context).enqueueUniqueWork(
      WORK_NAME,
      ExistingWorkPolicy.REPLACE,
      request
    )
  }

  companion object {
    /**
     * Precisa ser idêntico ao `BackgroundScheduler.channelName` do Dart e ao
     * `channelName` do Swift. Se divergirem, a chamada some sem erro — e um
     * teste do repositório compara os três arquivos por causa disso.
     */
    const val CHANNEL_NAME = "flutter_outbox/background"

    /** O nome único do trabalho. É ele que faz REPLACE substituir o certo. */
    const val WORK_NAME = "com.example.flutter_outbox.drain"
  }
}
