package com.example.flutter_outbox_background

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Configuration
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * O agendamento no Android, exercitado com o `TestDriver` do WorkManager.
 *
 * **Isto roda em emulador, e é o que o iOS não tem.** O `BGTaskScheduler` não
 * roda em simulador e um aparelho ligado ao Xcode não entra em background de
 * verdade, então lá a única evidência é aparelho solto ao longo de dias. Aqui o
 * ciclo de feedback é de minutos, e é por isso que `docs/ARCHITECTURE.md` manda
 * começar a camada 3 pelo Android: os erros de fronteira aparecem aqui, com o
 * desenho ainda mole.
 *
 * O que estes testes provam: que o trabalho é enfileirado com o nome único
 * certo, que as restrições chegam ao sistema, e que agendar duas vezes não
 * empilha. O que eles **não** provam: que o sistema concede a janela num
 * aparelho de usuário. O `TestDriver` satisfaz as restrições à mão — ele pula
 * a decisão do sistema, exatamente como o helper de LLDB faz no iOS.
 *
 * Para rodar:
 *
 * ```bash
 * cd background/android && ../../gradlew connectedAndroidTest
 * ```
 *
 * com um emulador aberto (`flutter emulators --launch <id>`).
 */
@RunWith(AndroidJUnit4::class)
class OutboxSchedulingTest {

  private lateinit var workManager: WorkManager

  @Before
  fun setUp() {
    val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    // `SynchronousExecutor` faz o trabalho rodar na mesma thread: sem ele o
    // teste precisaria de espera, e teste com espera é teste que fica lento e
    // instável.
    val configuration = Configuration.Builder()
      .setExecutor(SynchronousExecutor())
      .build()
    WorkManagerTestInitHelper.initializeTestWorkManager(context, configuration)
    workManager = WorkManager.getInstance(context)
  }

  private fun context() =
    ApplicationProvider.getApplicationContext<android.content.Context>()

  private fun scheduled(): List<WorkInfo> =
    workManager.getWorkInfosForUniqueWork(OutboxScheduling.WORK_NAME).get()

  @Test
  fun schedule_enfileira_um_trabalho_com_o_nome_unico() {
    OutboxScheduling.schedule(context(), earliestSeconds = 900, requiresNetwork = true)

    val infos = scheduled()
    assertEquals(1, infos.size)
    assertEquals(WorkInfo.State.ENQUEUED, infos.first().state)
  }

  @Test
  fun agendar_duas_vezes_nao_empilha() {
    // Reagendamento descontrolado gasta o orçamento de execução do app, e o
    // sistema pune as janelas seguintes de quem faz isso. É `ExistingWorkPolicy
    // .REPLACE` que impede, e é isto que este teste cobra.
    OutboxScheduling.schedule(context(), earliestSeconds = 900, requiresNetwork = true)
    OutboxScheduling.schedule(context(), earliestSeconds = 60, requiresNetwork = true)
    OutboxScheduling.schedule(context(), earliestSeconds = 30, requiresNetwork = false)

    val vivos = scheduled().filter { !it.state.isFinished }
    assertEquals(1, vivos.size)
  }

  @Test
  fun a_exigencia_de_rede_chega_ao_sistema() {
    OutboxScheduling.schedule(context(), earliestSeconds = 900, requiresNetwork = true)
    val comRede = scheduled().first()
    assertEquals(NetworkType.CONNECTED, comRede.constraints.requiredNetworkType)

    // E dá para pedir uma janela que roda sem rede — o cenário 14 existe por
    // causa dela: o sistema pode conceder a janela com o aparelho offline.
    OutboxScheduling.schedule(context(), earliestSeconds = 900, requiresNetwork = false)
    val semRede = scheduled().first { !it.state.isFinished }
    assertEquals(NetworkType.NOT_REQUIRED, semRede.constraints.requiredNetworkType)
  }

  @Test
  fun a_janela_so_roda_quando_o_atraso_e_as_restricoes_sao_satisfeitos() {
    OutboxScheduling.schedule(context(), earliestSeconds = 900, requiresNetwork = true)
    val id = scheduled().first().id
    val driver = WorkManagerTestInitHelper.getTestDriver(context())!!

    assertEquals(WorkInfo.State.ENQUEUED, scheduled().first().state)

    // O `TestDriver` satisfaz o atraso e as restrições à mão. **Ele pula a
    // decisão do sistema**: passar aqui prova que o handler roda quando
    // chamado, não que ele será chamado no aparelho de um usuário.
    driver.setInitialDelayMet(id)
    driver.setAllConstraintsMet(id)

    // O trabalho **saiu da fila**: as restrições satisfeitas fizeram o
    // WorkManager despachá-lo. É só isto que este teste pode afirmar.
    //
    // Não dá para esperar o estado final aqui: `OutboxDrainWorker` é um
    // `CoroutineWorker`, e o `SynchronousExecutor` não torna corrotina
    // síncrona — a primeira versão deste teste exigia `isFinished` e pegava o
    // worker ainda em RUNNING. Além disso, o desfecho dele depende de um motor
    // Dart que não existe num teste de instrumentação: quem cobre o que o
    // trabalho faz é `example/test/background_work_test.dart`, sobre
    // `drainQueue`.
    val depois = scheduled().first()
    assertTrue(
      "esperado despachado, encontrado ainda ENQUEUED",
      depois.state != WorkInfo.State.ENQUEUED
    )
  }

  @Test
  fun cancel_remove_o_trabalho() {
    OutboxScheduling.schedule(context(), earliestSeconds = 900, requiresNetwork = true)
    OutboxScheduling.cancel(context())

    val infos = scheduled()
    assertEquals(1, infos.size)
    assertEquals(WorkInfo.State.CANCELLED, infos.first().state)
  }
}
