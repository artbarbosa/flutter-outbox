package com.example.flutter_outbox_background

import android.content.Context
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * O agendamento em si, separado do plugin.
 *
 * Existe apartado de [FlutterOutboxBackgroundPlugin] pelo mesmo motivo que
 * `drainQueue` existe apartado de `main.dart` no app exemplo: o plugin precisa
 * de um `BinaryMessenger` e de um motor Dart vivo, e nenhum dos dois sobe num
 * teste de instrumentação. Aqui não há nenhum — só `Context` e `WorkManager` —,
 * e é isto que o `WorkManager.TestDriver` consegue exercitar em emulador.
 *
 * O que se ganha com essa separação é o ciclo de feedback que o iOS não tem:
 * no Android dá para provar que o trabalho foi enfileirado, que as restrições
 * foram aplicadas e que agendar duas vezes não empilha. Ver
 * `docs/ARCHITECTURE.md`, Riscos ainda não validados.
 */
object OutboxScheduling {

  /** O nome único do trabalho. É ele que faz REPLACE substituir o certo. */
  const val WORK_NAME = "com.example.flutter_outbox.drain"

  fun schedule(
    context: Context,
    earliestSeconds: Long,
    requiresNetwork: Boolean
  ) {
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

  fun cancel(context: Context) {
    WorkManager.getInstance(context).cancelUniqueWork(WORK_NAME)
  }
}
