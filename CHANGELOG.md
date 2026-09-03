# Changelog

## 0.1.0-dev — não publicado

A primeira versão utilizável. **Nada aqui foi publicado no pub.dev**, e o número
de versão existe para o `pubspec.yaml` ter um.

### O que existe

- **Camada 1 — o núcleo**, em Dart puro, sem dependência de runtime. Chave de
  idempotência derivada da intenção, journal gravado antes do envio, fila
  ordenada, reconciliação que termina no ledger, e as três decisões de desenho
  como peças substituíveis do motor.
- **Camada 2 — persistência.** `SqliteStorage` sobre `sqflite_common`, que é
  Dart puro: quem escolhe a implementação é o app, e a suíte continua rodando em
  `dart test` sem SDK do Flutter. `SqliteLease` impede que dois motores esvaziem
  a mesma fila ao mesmo tempo.
- **Camada 3 — background**, em `background/`, pacote separado: platform channel
  escrito à mão sobre `androidx.work` e `BGTaskScheduler`. **Não validado em
  aparelho** — ver "O que ainda não foi provado", no README.
- **A prova**: servidor falso em processo, transporte com falha por seed, quatro
  clientes sobre o mesmo motor (o correto e três ablações), 15 cenários
  adversariais, redução automática de seed que reprova, e a medição gerada por
  `dart run bin/measure.dart`.

### Três defeitos que a suíte encontrou no próprio motor

Registrados porque são a evidência de que ela funciona, e porque cada um deles
passaria despercebido numa suíte de caminho feliz:

- **Retomar não é insistir.** Ao voltar a uma operação sem desfecho de uma
  sessão anterior, o motor começava por reenviar. Depois de dias sem janela de
  background a chave já não existe no servidor, e o reenvio aplicava o efeito de
  novo — no cliente **correto**. Retomar agora exige reconciliação
  bem-sucedida antes de qualquer reenvio.
- **Ordem estrita que não era estrita.** Uma operação que não conseguia enviar
  ficava para trás enquanto as seguintes eram aplicadas. Ninguém duplicava nada
  e a conta fechava; o que quebrava era o critério de aceite sobre ordem. O
  motor agora para a fila na primeira que não sai.
- **A invariante de ordem olhava a coisa errada** — comparava a ordem das
  tentativas, não a dos efeitos, e por isso não via o defeito acima.

E um quarto, na própria suíte: `inMemoryDatabasePath` do SQLite é
**compartilhado** entre conexões, então um teste que não fechava o banco
entregava os próprios dados ao seguinte. A ordem dos testes agora é embaralhada
a cada execução (`dart_test.yaml`), para esse tipo de vazamento aparecer aqui em
vez de na máquina de outra pessoa.

### Limites conhecidos

- O agendamento de background não foi validado em aparelho.
- O cenário 11 (migração de schema) não foi escrito: não existe migração
  enquanto existe um schema só. A regra dele está em `SqliteStorage.migrate`.
- O modelo de falha é rede, morte de processo e relógio. Não há corrupção de
  disco, `fsync` que mente, nem relógio saltando para trás.
