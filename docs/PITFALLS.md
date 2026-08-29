# Armadilhas

Onde este projeto **erra em silêncio** — devolve um resultado plausível, os
testes ficam verdes, e a conta fecha errada.

Acrescente aqui o que a execução revelar. Boa parte das armadilhas reais só
aparece rodando; as de baixo são as que o domínio e a stack já são conhecidos
por ter.

## Identidade

**A chave derivada do relógio.** Parece razoável dizer que "chave de idempotência
vale por cinco minutos" e derivá-la de uma janela de tempo. Com o relógio do
aparelho atrasado, a janela vira em hora diferente da do servidor, a chave muda
entre tentativas, e a reconciliação passa a procurar por uma chave que nunca
existiu. Cobra duas vezes, e o teste feliz não vê nada. **A chave é função da
intenção, e de mais nada.**

**A chave derivada da tentativa.** UUID gerado na hora do envio é a mesma
armadilha com outra roupa, e é o comportamento do cliente ingênuo.

**Payload igual, referência diferente.** Duas operações legitimamente idênticas
em valor precisam de referências de negócio diferentes, ou viram uma só. A
identidade é da *operação*, não do conteúdo.

## Tempo

**`DateTime.now()` fora da composição raiz.** Qualquer chamada direta torna o
teste dependente do relógio da máquina e o soak não reproduz. Tudo por `Clock`
injetável.

**Fuso e horário de verão.** Guarde e compare em UTC. Nunca persista horário
local: o mesmo instante muda de valor quando o aparelho troca de fuso, e a
ordenação por tempo local quebra de madrugada duas vezes por ano.

**Expiração medida com o relógio errado.** O TTL da chave é do servidor. O
cliente não tem autoridade nenhuma sobre ele e não deve tentar prever.

## Dinheiro

**Ponto flutuante.** Valor é `int` em centavos, sempre. `0.1 + 0.2` passa em
teste de igualdade aproximada e erra na soma do ledger.

**Arredondamento em divisão.** Se algum dia houver divisão — taxa, rateio —
defina para onde vai o centavo que sobra, e teste. Um centavo perdido por
operação quebra a invariante de soma, e demora a aparecer.

## Ordem e concorrência

**Ordem por timestamp.** Duas operações no mesmo milissegundo empatam, e o
empate é resolvido de forma indefinida. Ordene por sequência monotônica do
banco, não por tempo.

**Gravar e marcar em duas transações.** Registrar a operação e mudar o estado
dela precisa ser uma transação só. Em duas, a morte do processo no meio deixa
uma operação registrada que ninguém retoma — ou pior, retoma duas vezes.

**Duas instâncias do motor.** O app pode acordar em background enquanto o
usuário abre a tela. Sem lock, as duas leem a mesma operação pendente. É o
cenário 12.

**Ler a fila inteira na memória.** Funciona com três operações e falha com três
mil. Leia por página, mantendo a ordem.

## Rede

**Tratar timeout como falha.** É o erro central que o projeto existe para
demonstrar. Timeout é **destino desconhecido**, e destino desconhecido se
resolve perguntando.

**Retry com backoff mas sem teto.** Sem limite de tentativa, uma operação
rejeitada de forma permanente gira para sempre e segura a fila inteira atrás
dela.

**Confiar que a chave ainda existe no servidor.** Ela expira. Quando o servidor
responde que não conhece a chave, isso **não** prova que nada aconteceu — é
preciso conferir o ledger pela referência de negócio antes de reenviar.

## Background

**Assumir que a janela vai rodar.** No iOS, `BGTaskScheduler` pode não conceder
execução por dias, e o comportamento em simulador não representa o do aparelho.
Nada pode expirar por não ter rodado.

**Confundir o helper de LLDB com evidência.** `_simulateLaunchForTaskWithIdentifier:`
dispara o seu handler na hora, e é a única forma prática de exercitar o código
durante o desenvolvimento — mas ele **pula o agendador inteiro**. Passar com ele
prova que o handler funciona quando chamado; não prova nada sobre ser chamado.
Some a isso que o simulador não executa `BGTaskScheduler` e que um aparelho
conectado ao Xcode não entra em background de verdade, e o resultado é o pior
tipo de armadilha: tudo verde na sua máquina, nada rodando na do usuário. O
cenário 15 só fecha em aparelho solto, ao longo de dias.

**Trabalho longo demais na janela.** O sistema encerra a tarefa no meio. Todo
envio precisa ser interrompível a qualquer instante sem deixar estado
inconsistente — é o cenário 13.

**Agendar de novo dentro da própria tarefa, sem cuidado.** Reagendamento
descontrolado gasta o orçamento de execução do app e faz o sistema punir as
janelas seguintes.

## Testes

**`Random()` sem seed.** Reprovação que não reproduz não vira cenário, e some na
próxima execução.

**Verificar a invariante só no fim.** Um cenário pode terminar certo tendo
passado por um estado impossível no meio. Verifique depois de cada passo, não só
no `expect` final.

As outras três armadilhas de teste — suíte que passa com o cliente ingênuo,
ledger que deduplica e falha sem seed — são regra, não armadilha, e estão em
`docs/TESTING.md`.
