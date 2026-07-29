# Resultado da refatoração de arquitetura

Data: 2026-07-29

## Resultado executivo

As quatro frentes propostas foram implementadas e mantidas. Os benchmarks
confirmaram ganho relevante no runtime de processos CLI e no ciclo de vida
contínuo e pequenos ganhos na preparação de dispatch e na restauração do
editor de agendamentos. Neste último caso, a mudança vale principalmente pela
remoção de estado duplicado e pelas garantias de concorrência que ela
introduziu, não pela diferença de microssegundos.

Nenhuma release foi criada. O artefato local foi recompilado e validado em
`build/Ohayo.app`.

## Mudanças mantidas

### 1. Dispatch preparado e consciente da conta

- `DispatchIntent` é a entrada única de `FireController`.
- `DispatchPreparer` resolve mensagem, conta, provider, diretório e origem uma
  única vez em `PreparedDispatch`.
- quota, autenticação, runner, terminal e histórico consomem a mesma conta
  canônica.
- conta explícita ausente falha fechada, sem cair silenciosamente na conta
  padrão.
- dispatches de agenda e renovação são revalidados depois da espera na fila;
  snapshots editados, removidos ou desabilitados não executam.
- a mesma revalidação ocorre depois de quota e autenticação, antes de runner ou
  Terminal receberem o payload, incluindo pausa aplicada durante o `await`.
- ações manuais continuam explícitas e podem executar uma configuração legada
  contínua de shell.

### 2. Runtime único para processos CLI

- toda criação de `Foundation.Process` ficou confinada em
  `CLIProcessRuntime`.
- stdout e stderr têm limites explícitos, incluindo política de overflow.
- timeout e cancelamento encerram a árvore do processo.
- stdin é escrito e fechado de forma consistente.
- o diretório de trabalho preparado é preservado até a execução.
- localização do binário do Codex respeita cancelamento cooperativo.
- o drain final é não bloqueante mesmo quando um descendente herda o pipe.
- cancelamento escala imediatamente para `SIGKILL` após `SIGTERM`, sem girar
  por um segundo dentro de uma task já cancelada.
- cancelamento que chega depois de timeout/overflow também interrompe o grace
  period sem alterar o outcome que venceu a corrida.
- o inventário de plugins Codex distingue `notQueried`, `unavailable` e
  `loaded(Data)`: falha limpa opções stale, mas preserva a seleção atual; JSON
  válido vazio é autoritativo.

### 3. Editor de agendamentos como módulo de domínio

- `AgendamentoDraft` concentra restauração, normalização e montagem do
  agendamento.
- `AgendamentoEditor` é a única fronteira de mutação da coleção de tarefas.
- save, toggle, delete e desabilitação por conta passam pela mesma fronteira.
- edições obsoletas e tarefas removidas não são sobrescritas ou
  ressuscitadas.
- o formulário ficou com seis propriedades `@State`: um draft de domínio e
  cinco estados exclusivamente assíncronos/de UI.
- cada renderização usa um único `AgendamentoFormSnapshot`, evitando repetir
  acesso ao disco e varredura de tarefas para cada campo derivado.

### 4. Ciclo de vida contínuo tipado

- `ContinuousScheduleDefinition`, `ContinuousScheduleInput` e
  `RenewalSnapshot` substituíram mapas e callbacks paralelos.
- detecção, dispatch, recovery e UI trabalham sobre a mesma definição de
  tarefa/conta.
- a publicação de snapshots foi agrupada, removendo o custo quadrático da
  sincronização.
- resultados assíncronos antigos são descartados por geração, UID, revisão e
  provider.
- recovery tardio não volta a persistir sidecar depois que a tarefa é removida
  ou desabilitada.
- ao editar a mesma UID/conta durante um hand-off, somente a lease conservadora
  de cooldown sobrevive à revisão e ao restart; retry e needs-attention antigos
  são limpos.
- o outcome stale continua sendo ignorado; a lease da conta é persistida na
  revisão corrente apenas para impedir um hand-off duplicado.

## Desempenho

Comando:

```sh
swift test -c release --filter ArchitecturePerformanceTests
```

Método: mesma carga fixa antes e depois, cinco execuções Release por versão e
comparação da mediana em milissegundos por iteração. Valor negativo na coluna
de variação significa execução mais rápida.

| Frente | Carga por amostra | Baseline (mediana) | Amostras finais | Final (mediana) | Variação | Decisão |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| Dispatch por conta | 20.000 | 0.044587 ms | 0.043289, 0.043747, 0.045117, 0.043496, 0.043380 | 0.043496 ms | -2,45% | Manter: pequeno ganho e contrato único fail-closed |
| Processo CLI curto | 8 | 207.487 ms | 1.171875, 1.102427, 1.113120, 1.236094, 1.122354 | 1.122354 ms | -99,46% | Manter: ganho decisivo |
| Restauração do editor | 100.000 | 0.004407 ms | 0.004330, 0.004412, 0.004464, 0.004372, 0.004392 | 0.004392 ms | -0,34% | Manter: desempenho neutro; valor principal é estrutural e funcional |
| Sincronização contínua | 25, com 40 contas | 0.964683 ms | 0.789800, 0.804510, 0.809468, 0.790183, 0.825038 | 0.804510 ms | -16,60% | Manter: ganho material e snapshot tipado |

O editor não deve ser apresentado como uma otimização relevante de velocidade:
a diferença de 0,34% é pequena e o tempo absoluto continua na ordem de
microssegundos. Ele foi mantido porque elimina estados paralelos, avalia a UI
uma vez por renderização e adiciona proteção testada contra concorrência
otimista.

## Revisão pós-refatoração

A revisão independente encontrou casos de borda adicionais, todos cobertos por
testes antes do fechamento:

- resultado de detector antigo podia alcançar uma tarefa já editada;
- retry/cooldown podia ser exibido como janela ativa no menu;
- conflito, conta ausente e configuração inválida podiam ficar ocultos no
  painel;
- identidade visual de conta offline podia ser perdida;
- o estado "todas pausadas" ignorava conta pretendida com pasta ausente;
- overflow `.fail` podia perder a corrida para a saída do processo;
- shell e histórico podiam recalcular dados já preparados;
- item aguardando na fila podia executar snapshot editado, removido ou
  desabilitado;
- cancelamento durante a espera da fila não removia o waiter;
- edição durante os `await` de quota ou autenticação ainda podia alcançar
  runner/Terminal com o snapshot antigo;
- pausa aplicada durante esses mesmos `awaits` ainda podia deixar o payload
  avançar;
- localização do Codex não observava cancelamento;
- recovery tardio podia ressuscitar sidecar;
- a lease conservadora podia ser perdida após edição/restart, permitindo
  bootstrap duplicado;
- execução manual de shell contínuo legado era bloqueada;
- processo raiz encerrado podia deixar `readToEnd` bloqueado por um descendente
  que herdou stdout/stderr;
- cancelamento podia consumir um segundo em spin no grace period;
- cancelamento posterior a timeout/overflow ainda podia cair no mesmo spin;
- o formulário repetia avaliação com I/O no mesmo `body`;
- cache de plugins Codex podia conservar opções de uma consulta anterior após
  falha/timeout;
- asserts permissivos podiam deixar os testes de recovery aceitarem launches
  extras;
- um teste de lifecycle tinha data fixa já passada e podia disparar `NSTimer`
  durante a suíte.

## Evidências finais

- suítes focadas finais: 57 testes de dispatch, 133 de
  AppState/AppEnvironment/Renewal e 42 de runtime/cache, 0 falhas;
- suíte completa: 496 testes, 0 falhas, 22,451 s;
- `swift test -c release --filter ArchitecturePerformanceTests`: cinco
  execuções finais, todas aprovadas;
- `./scripts/make-app.sh`: build Release concluído;
- `codesign --verify --deep --strict build/Ohayo.app`: aprovado;
- `plutil -lint build/Ohayo.app/Contents/Info.plist`: `OK`;
- bundle identifier: `io.github.hayashirafael.Ohayo`;
- assinatura local: ad-hoc;
- `git diff --check`: aprovado;
- único `Process()` de produção:
  `Sources/Ohayo/CLIProcessRuntime.swift`;
- APIs legadas auditadas: nenhuma ocorrência;
- mutações de `state.tasks` fora de `AgendamentoEditor`: nenhuma ocorrência.

O app não foi aberto contra o perfil real do macOS durante esta validação para
não disparar agendamentos ou usar contas reais. O limite de validação manual é,
portanto, a interação visual em runtime; compilação, empacotamento, assinatura,
contratos de domínio e fluxos concorrentes foram validados deterministicamente.
