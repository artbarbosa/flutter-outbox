package com.example.flutter_outbox_background

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

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
        OutboxScheduling.schedule(context, earliestSeconds, requiresNetwork)
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
        OutboxScheduling.cancel(context)
        result.success(null)
      }
      else -> result.notImplemented()
    }
  }

  companion object {
    /**
     * Precisa ser idêntico ao `BackgroundScheduler.channelName` do Dart e ao
     * `channelName` do Swift. Se divergirem, a chamada some sem erro — e um
     * teste do repositório compara os três arquivos por causa disso.
     */
    const val CHANNEL_NAME = "flutter_outbox/background"

    /** Onde o nome único do trabalho vive: [OutboxScheduling.WORK_NAME]. */
  }
}
