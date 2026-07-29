# Auditoria técnica profunda do Ohayo

**Data:** 28 de julho de 2026
**Commit auditado:** `ab23123` (`main`, tag `v1.1.1`)
**Foco:** confiabilidade do produto, jornada de novos usuários e integração com Claude Code e Codex CLI

## Atualização pós-correções — worktree atual

Os achados e números abaixo documentam a **baseline `ab23123`**. Depois da
auditoria, o worktree recebeu uma correção ampla, ainda sem commit ou release.
O estado atual já resolve os quatro P0 da baseline e a maior parte dos P1/P2 de
onboarding e recuperação:

- `ProviderAccountContext` passou a distinguir conta Claude nativa de perfil
  custom, aplicar `CLAUDE_CONFIG_DIR`/`CODEX_HOME` corretamente e usar a pasta
  canônica da conta, inclusive quando o default é um symlink;
- a identidade persistida do provider agora acompanha o request até o detector
  de quota; pasta ausente ou assinatura ambígua não reinterpreta Codex como
  Claude;
- o detector aceita apenas evidência positiva de tokens e retorna
  `active`/`inactive`/`unavailable`; envelope desconhecido, pasta ilegível e
  schema futuro falham fechados;
- uma tarefa contínua só faz bootstrap com consentimento explícito, e
  cooldown, retry exponencial e `needsAttention` sobrevivem a restart;
- o sidecar de recovery preserva entradas válidas diante de corrupção parcial,
  bloqueia de forma conservadora um blob ilegível e sobrevive a conta offline
  ou downgrade com task ainda desconhecida;
- edição durante dispatch não duplica o comando nem aplica outcome de uma
  revisão antiga; backoff começa quando a falha retorna, não antes do timeout;
- uma ocorrência fixa é reservada antes do `await`, impedindo wake/timer de
  dispararem a mesma ocorrência em paralelo; reconfigurações antigas também
  não ressuscitam tarefas já removidas;
- contas contínuas temporariamente offline continuam participando de filtros e
  conflitos pelo alvo pretendido e voltam a ser configuradas quando a pasta
  reaparece;
- `FireController` usa outcome tipado e FIFO por provider/conta; Terminal é
  registrado como `launched`, e erro permanente não entra em loop de retry;
- batch recebe prompt por stdin, timeout configurável, output head+tail e
  encerramento da árvore de processos; scripts temporários do Terminal usam
  `0600`, são limpos e não pré-aprovam imports externos;
- o onboarding ganhou Doctor passivo para CLI/login por conta, instruções de
  permissão recuperáveis e defaults/rótulos coerentes;
- histórico e notificações ocultam conteúdo sensível por padrão e oferecem
  limpeza local;
- o picker Codex consulta o inventário autoritativo e somente leitura de
  plugins instalados e habilitados da conta, sem varrer versões antigas ou
  plugins desativados do cache; snapshots aceleram a UI, mas troca de
  conta/tipo revalida o inventário e cancelamento encerra também a descoberta
  do binário;
- CI/release, `.app` e DMG agora falham fechados em assinatura, hardened
  runtime, notarização e validação, em vez de mascarar erros; a release gera
  binário universal, testa nativamente arm64 e x86_64 em runners macOS 15,
  valida o deployment target macOS 13 e executa Gatekeeper mais smoke no app
  montado depois da notarização.

As regressões críticas estão cobertas por testes de conta, provider, quota,
restart, recovery, edição concorrente, downgrade e symlink. A validação final
deste worktree retornou:

```text
swift test
444 testes, 0 falhas

swift build
exit=0

OHAYO_UNIVERSAL_BUILD=1 ./scripts/make-app.sh
build/Ohayo.app universal (arm64 + x86_64), minos 13.0 nas duas slices,
gerado e codesign --verify aprovado

OHAYO_UNIVERSAL_BUILD=1 ./scripts/make-dmg.sh
build/Ohayo-1.1.1.dmg gerado, montado, conteúdo conferido e hdiutil verify aprovado
SHA-256 66988c363212195f5df4c368c0a7c4b9b08020a7bfef7122f726a7234ab92465

plutil -lint build/Ohayo.app/Contents/Info.plist
OK

spctl --assess --type execute build/Ohayo.app
rejected, exit=3
```

O último resultado é esperado neste build local ad-hoc: não havia identidade
Developer ID nem credenciais de notarização no ambiente. O workflow público
agora exige o conjunto completo de secrets de assinatura/notary, habilita
hardened runtime e timestamp, valida a resposta `Accepted`, faz staple e só
então publica. Esse caminho de distribuição ainda precisa de uma execução real
com as credenciais do projeto.

### Limites que continuam reais

Esta correção não transforma um hand-off interativo em execução supervisionada:
o Terminal continua terminando em `launched`, sem observar exit code, conclusão
ou cancelamento do Claude/Codex. Também permanecem como próximos passos:

1. fila realmente persistente de jobs e supervisor de processo/PTY;
2. eventos estruturados, session/thread ID, usage e custo por execução;
3. fonte oficial de rate limits do Codex quando o auth for ChatGPT, mantendo
   transcript apenas como fallback com proveniência;
4. perfis explícitos de capabilities (`read-only`, `workspace-write`, etc.);
5. auto-update assinado e execução real do gate Developer ID/notarização com
   as credenciais do projeto;
6. confirmação formal do enquadramento comercial do uso de OAuth Claude;
7. smoke de runtime no próprio macOS 13 via máquina/self-hosted runner; a
   imagem hospedada `macos-13` foi aposentada, então o CI cobre as duas
   arquiteturas no macOS 15 e verifica `minos 13.0`, mas isso não substitui
   execução real no sistema mínimo.

## Veredicto

O Ohayo tem uma base Swift pequena, legível e com bons pontos iniciais de
injeção de dependência. O problema principal não está na UI: está no modelo que
liga conta, autenticação, execução e janela de uso.

Na versão auditada, eu não recomendaria o produto para novos usuários sem antes
corrigir quatro bloqueadores:

1. a conta Claude padrão é tratada como um perfil alternativo e aparece
   deslogada;
2. o batch Codex padrão executa com `CODEX_HOME=~/.claude`;
3. uma tarefa contínua nova não inicia a primeira janela;
4. transcripts de execuções que falharam podem criar uma janela fictícia de
   cinco horas.

Além disso, abrir o Terminal é registrado como execução bem-sucedida antes de o
Claude ou o Codex sequer terminar. Isso torna o histórico e as renovações menos
confiáveis do que a UI sugere.

A direção correta não é acrescentar mais condicionais por provider. É criar
módulos profundos para conta, runtime e quota de cada provider, com uma máquina
de estados comum para os jobs.

## Como a auditoria foi feita

Foram usados:

- leitura do fluxo completo entre `AppState`, schedulers, `FireController`,
  runners, detector e histórico;
- três auditorias paralelas: Claude, Codex e produto/onboarding;
- execução dos testes Swift;
- build e validação do `.app`;
- execução real das CLIs em perfis padrão e isolados;
- inspeção de transcripts de falha gerados pelas duas CLIs;
- documentação oficial atual do Claude Code e do Codex.

As severidades usadas neste documento são:

- **P0:** impede o caminho principal ou invalida a promessa central;
- **P1:** pode produzir estado incorreto, perda de execução ou risco relevante;
- **P2:** onboarding, operação, manutenção ou segurança incompletos;
- **P3:** consistência e acabamento.

## P0 — bloqueadores confirmados

### 1. A conta Claude padrão é tratada como um perfil alternativo

**Evidência no código**

- `AppState.defaultConfigDir` representa a conta padrão como `~/.claude`
  (`Sources/Ohayo/AppState.swift:234-237`).
- `AppEnvironment` injeta essa URL no runner
  (`Sources/Ohayo/AppEnvironment.swift:35-39`).
- O auth preflight sempre exporta `CLAUDE_CONFIG_DIR`
  (`Sources/Ohayo/AuthenticationChecker.swift:57-64`).
- Batch e Terminal também sempre exportam a variável
  (`Sources/Ohayo/CommandRunner.swift:227-236` e
  `Sources/Ohayo/TerminalLauncher.swift:103-123`).
- A identidade procura `~/.claude/.claude.json`, embora o estado global nativo
  esteja em `~/.claude.json`
  (`Sources/Ohayo/AccountIdentity.swift:33-37`).

**Reprodução nesta máquina, com Claude Code 2.1.220**

```text
claude auth status --json
exit=0

CLAUDE_CONFIG_DIR="$HOME/.claude" claude auth status --json
exit=1
```

`CLAUDE_CONFIG_DIR` é um override para um diretório de configuração alternativo,
não uma forma neutra de expressar o perfil nativo. A documentação atual confirma
esse uso para múltiplas contas e explica que, no macOS, as credenciais ficam no
Keychain: [Claude Code environment variables](https://code.claude.com/docs/en/env-vars).
O estado global que inclui OAuth e trust fica em `~/.claude.json`:
[Claude Code settings](https://code.claude.com/docs/en/configuration).

**Impacto**

O usuário pode instalar o Claude Code, fazer login normalmente, instalar o Ohayo
e receber:

```text
Claude is not logged in for this account.
Run CLAUDE_CONFIG_DIR='/Users/.../.claude' claude auth login
```

O comando sugerido reforça o perfil alternativo incorreto. Batch e Terminal da
conta Claude padrão ficam bloqueados pelo preflight.

**Correção**

Modelar a conta de forma explícita:

```swift
enum AccountStorage {
    case nativeDefault
    case custom(URL)
}
```

Para `nativeDefault`, não exportar `CLAUDE_CONFIG_DIR`. Para `custom`, exportar
o caminho. Identidade, transcript e trust devem ser propriedades resolvidas
pelo adapter Claude, porque não são o mesmo caminho na conta nativa.

### 2. O batch Codex padrão recebe `CODEX_HOME=~/.claude`

**Evidência no código**

- `AppEnvironment` constrói um único `CommandRunner` com
  `configDir: AppState.defaultConfigDir`, isto é, `~/.claude`
  (`Sources/Ohayo/AppEnvironment.swift:35-39`).
- `CommandRunner` reutiliza esse `configDir` independentemente do provider:
  `messageConfigDir ?? configDir ?? fallback`
  (`Sources/Ohayo/CommandRunner.swift:227-235`).
- O auth preflight do Codex, por outro lado, valida corretamente `~/.codex`.

**Reprodução nesta máquina, com Codex CLI 0.145.0**

```text
codex login status
exit=0

CODEX_HOME="$HOME/.claude" codex login status
exit=1
```

Assim, o Ohayo pode confirmar que a conta `~/.codex` está autenticada e, logo
depois, executar o batch em `~/.claude`, onde não há a credencial validada.
O Terminal Codex não tem exatamente esse bug porque resolve `~/.codex`
separadamente.

O teste `testCodexSemConfigDirUsaCodexHomePadrao` instancia um runner sem o
`configDir` usado na composição real, então não cobre a falha
(`Tests/OhayoTests/CommandRunnerTests.swift:433-440`).

**Correção**

Remover `configDir` do runner compartilhado. Toda execução deve receber um
`AccountContext` já resolvido pelo provider. Adicionar um teste de composição
`AppEnvironment -> FireController -> CommandRunner` que inspecione o ambiente
efetivo.

### 3. Uma tarefa contínua nova nunca inicia a primeira janela

**Evidência no código**

- Sem um transcript recente, `activeWindowEnd` retorna `nil`
  (`Sources/Ohayo/SessionDetector.swift:21-39`).
- Sem uma janela previamente armada, `RenewalEngine.rearm` apenas limpa o estado
  e retorna (`Sources/Ohayo/RenewalEngine.swift:62-76`).
- O teste `testSemJanelaAguardaSemRenovar` fixa esse comportamento.
- A UI mostra “aguardando janela”, enquanto o README e as strings prometem
  renovação contínua 24/7.

Isso também ocorre depois de reiniciar o app quando a janela anterior já
expirou: `nextRenewal` não é persistido, então não existe o estado `missed` que
faria o engine disparar.

**Impacto**

O usuário cria uma renovação contínua esperando automação e precisa abrir uma
janela manualmente sem que o produto explique isso. Para um usuário novo, a
feature principal parece simplesmente parada.

**Correção**

Criar estados explícitos:

```text
needsBootstrap -> starting -> active -> renewing
                         \-> retrying / needsAttention
```

Ao criar a tarefa, oferecer “Iniciar primeira janela agora”. O opt-in é
importante porque há consumo de quota. Depois disso, persistir o estado mínimo
necessário para recuperar a cadeia após restart, sleep e falhas.

### 4. Um transcript de erro pode abrir uma janela fictícia

**Evidência no código**

- `SessionDetector.timestamp(fromLine:)` aceita qualquer linha que contenha
  `"timestamp"` (`Sources/Ohayo/SessionDetector.swift:59-65`).
- `collectTimestamps` não valida tipo de evento, sucesso, modelo ou uso
  (`Sources/Ohayo/SessionDetector.swift:94-111`).
- `activeBlockEnd` transforma qualquer timestamp aceito em um bloco de cinco
  horas (`Sources/Ohayo/SessionDetector.swift:47-56`).

Em execuções isoladas e desautenticadas, tanto `claude -p` quanto `codex exec`
criaram JSONL recente antes de sair com erro. O transcript Claude continha uma
mensagem sintética com `isApiErrorMessage: true`, modelo `<synthetic>` e uso
zero; o Codex registrou eventos de início e conclusão da task sem um evento de
uso válido.

**Impacto**

Logout, modelo inválido, falha de rede ou rate limit podem fazer o Ohayo afirmar
que a janela está ativa e aguardar cinco horas. O mesmo erro pode impedir retry
e fazer o ícone comunicar um estado que nunca existiu no provider.

**Correção**

O detector não deve retornar apenas `Date?`:

```swift
enum QuotaWindowState {
    case active(until: Date, confidence: EvidenceConfidence)
    case inactive
    case unavailable(reason: String)
}
```

Para Claude, aceitar somente eventos comprovadamente faturáveis e ignorar
mensagens sintéticas/de erro. Para Codex autenticado via ChatGPT, substituir a
heurística pelo `account/rateLimits/read` do app-server, que fornece
`usedPercent`, duração e `resetsAt`:
[Codex App Server](https://learn.chatgpt.com/docs/app-server).

Quando só houver inferência local, a UI deve dizer “estimado”. Quando não houver
evidência válida, deve dizer “indisponível”, não “sem janela”.

## P1 — execução, recuperação e segurança

### Terminal aberto é registrado como tarefa concluída

`TerminalLauncher.launch` só sabe se o AppleScript conseguiu executar
`do script` (`Sources/Ohayo/TerminalLauncher.swift:22-60`). Em seguida,
`FireController` grava `.success` e pode emitir notificação de sucesso
(`Sources/Ohayo/FireController.swift:104-126`).

O Claude ou o Codex ainda pode:

- falhar em autenticação ou quota;
- rejeitar modelo/configuração;
- esperar trust ou aprovação;
- sair com erro;
- ficar travado;
- nem iniciar corretamente.

O histórico precisa distinguir:

```text
queued -> launched -> running -> completed
                            \-> failed / cancelled / timedOut
```

Uma opção mínima é um wrapper que grave PID, horário, exit code e output em um
arquivo de status. A opção mais forte é um supervisor de processo/PTY com
attach, cancelamento e streaming para o app.

### Falhas reais encerram a cadeia contínua sem retry

`FireController.fire` retorna `true` tanto em sucesso quanto em auth inválida,
CLI ausente, timeout ou exit não zero
(`Sources/Ohayo/FireController.swift:39-50,84-100,129-168`).
`RenewalEngine` entende `true` como uma tentativa executada, marca dedupe e
procura a próxima janela. Sem transcript válido, fica sem próximo evento
(`Sources/Ohayo/RenewalEngine.swift:94-109`).

O retorno booleano é um contrato raso demais. O engine precisa receber um
outcome tipado e aplicar política de retry:

- falha transitória: backoff com jitter;
- desautenticado: `needsAttention`, sem loop;
- CLI ausente: health issue;
- ocupado: reencaminhar para a fila;
- sucesso sem evidência de quota: verificar antes de armar cinco horas.

### O lock global descarta jobs legítimos

`FireController.isRunning` serializa todas as contas, providers e tarefas. Um
segundo disparo é descartado e existe apenas um log interno
(`Sources/Ohayo/FireController.swift:39-53`).

Uma tarefa manual pode sumir sem feedback, e duas contas independentes não podem
executar batch em paralelo. Deve existir uma fila persistente com limite por
provider/conta e status “na fila”. Colisão não é sucesso nem falha.

### Timeout fixo de 60 segundos é inadequado para agentes

Todo Claude batch, Codex batch e comando shell compartilha um timeout de 60
segundos (`Sources/Ohayo/CommandRunner.swift:73-75,268-295`).

Outros problemas associados:

- timeout perde stdout/stderr parcial;
- o processo pai é encerrado, mas não há gerenciamento explícito do grupo de
  processos;
- o buffer preserva o início, não necessariamente a cauda onde está o erro;
- tarefas reais de engenharia frequentemente excedem um minuto.

O timeout deve ser configurável por tarefa, com presets, cancelamento de árvore
de processos e buffer head+tail. Para execuções estruturadas, Claude oferece
`--output-format json/stream-json` com session ID, uso e eventos; Codex oferece
`codex exec --json` com eventos de thread, turn, item e erro:
[Claude programmatic usage](https://code.claude.com/docs/en/headless) e
[Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode).

### “Safe mode” não significa sandbox

No Claude, `--safe-mode` desliga customizações, mas não é um sandbox de
filesystem. Built-in tools e permissões continuam existindo. Selecionar uma
skill força `safeMode=false` (`Sources/Ohayo/Models.swift:114-127`), o que ativa
não apenas a skill, mas também CLAUDE.md, hooks, plugins, MCP, agentes e outras
customizações.

O CLI atual ainda possui `--bare`, mas ele não é substituto direto para o fluxo
de assinatura do Ohayo: esse modo não lê OAuth/Keychain e exige outra fonte de
autenticação. A UI deve separar:

- customizações carregadas;
- tools permitidas;
- modo de permissão;
- sandbox/escopo de escrita;
- diretório de trabalho.

Para o ping mínimo, usar um perfil de capabilities estrito, não um booleano
chamado “modo seguro”.

### Trust e imports externos são aprovados sem consentimento específico

Antes de cada launch Claude interativo, `seedTrust` edita `.claude.json` e marca
como aceitos o trust do diretório e imports externos de CLAUDE.md
(`Sources/Ohayo/TerminalLauncher.swift:133-178`).

A documentação do Claude explica que o diálogo de imports externos lista os
arquivos na primeira ocorrência justamente para proteger o usuário de conteúdo
commitado por terceiros:
[Claude Code memory](https://code.claude.com/docs/en/memory).

O Ohayo deve:

- pedir consentimento por projeto;
- não pré-aprovar imports externos junto com o trust básico;
- mostrar o arquivo que será alterado;
- serializar/mesclar a atualização para evitar perder uma escrita concorrente
  da própria CLI.

No batch, há outro detalhe: a verificação de trust é desativada quando `-p` é
usado. Isso torna ainda mais importante não desligar todas as proteções ao
selecionar uma skill:
[Claude Code security](https://code.claude.com/docs/en/security).

### Comando shell recebe ambiente Claude inesperadamente

`CommandRunner` trata tudo que não é Codex como provider Claude na montagem do
ambiente (`Sources/Ohayo/CommandRunner.swift:232-235`). Portanto uma tarefa
shell arbitrária recebe `CLAUDE_CONFIG_DIR`, apesar de não ser uma tarefa
Claude.

O shell também roda com todos os privilégios do usuário e sem sandbox. Isso pode
ser uma feature válida, mas precisa de aviso explícito, preview do comando,
diretório configurável, logs completos e nenhuma mutação de ambiente que o
usuário não escolheu.

### Scripts temporários mantêm o prompt em texto

O Terminal launcher escreve ambiente, cwd e prompt em
`ohayo-terminal-<UUID>.sh` e só remove o arquivo ao fim da sessão
(`Sources/Ohayo/TerminalLauncher.swift:39-58`). Em sessão longa ou crash, o
prompt permanece no diretório temporário.

É necessário limpar resíduos no startup, aplicar permissões restritas ao arquivo
e oferecer política de retenção/redação para conteúdo sensível.

No batch, o prompt também é passado integralmente como argumento do processo.
As duas CLIs aceitam input por stdin; usar stdin reduz a exposição do conteúdo
na inspeção da lista de processos.

## Claude Code — avaliação específica

### O que está bem encaminhado

- localização do binário contempla Homebrew e instalações no home;
- há preflight pela CLI em vez de leitura direta de tokens;
- safe mode, modelo e esforço são configuráveis;
- stdout e stderr são preservados em falhas de batch;
- a ideia de contas alternativas via `CLAUDE_CONFIG_DIR` é válida.

### O que eu mudaria

1. Separaria conta nativa de conta customizada.
2. Usaria output estruturado e guardaria `session_id`, usage, custo e resultado.
3. Criaria perfis explícitos: “ping mínimo”, “somente leitura” e “agente com
   ferramentas”.
4. Removeria a aprovação automática de imports externos.
5. Descobriria skills efetivas pelo cwd, incluindo `.claude/skills`, e não
   apenas o diretório global/cache.
6. Usaria aliases de modelo quando possível e faria capability check, em vez de
   depender apenas de nomes versionados hardcoded.
7. Monitoraria mudanças de contrato da CLI com contract tests por versão
   suportada.

### `claude -p`: situação atual, sem falso alarme

O formulário novo começa em saída “Nenhuma”, que persiste batch
(`runInTerminal=false`), apesar de o README dizer que Terminal é o default.
Esse batch usa `claude -p`.

Uma mudança para separar o consumo do Agent SDK/`claude -p` do limite interativo
foi anunciada, mas está **pausada** desde 15 de junho de 2026. Hoje, segundo a
fonte oficial, `claude -p` continua consumindo o limite da assinatura:
[Anthropic Help Center](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan).

Portanto, não existe base atual para desabilitar o batch apenas por esse motivo.
Existe, porém, um risco de produto: a promessa central depende de uma política
externa que já foi anunciada e suspensa. Eu colocaria esse comportamento atrás
de um adapter/capability flag e manteria um canário de compatibilidade.

### Gate de distribuição/compliance

Não é possível concluir uma violação jurídica apenas pela leitura do código.
Entretanto, a documentação atual diz que OAuth de planos é destinado ao uso
normal dos apps nativos e orienta desenvolvedores de produtos/serviços a usar
API key; também veda oferecer login Claude.ai ou rotear credenciais de planos
em nome dos usuários:
[Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance).

Como o Ohayo é distribuído publicamente e agenda chamadas usando a sessão local
do usuário, esse ponto deve receber confirmação formal da Anthropic antes de
escala comercial. Até lá, a posição mais defensável é “ferramenta local pessoal
que aciona a CLI já instalada”, sem capturar nem transportar credenciais.

## Codex — avaliação específica

### O que está bem encaminhado

- `codex exec` é a interface correta para batch;
- `--sandbox read-only` é um bom default para um ping simples;
- modelo e reasoning são omitidos quando o usuário quer o default da conta;
- `--skip-git-repo-check` permite o workspace neutro;
- o preflight usa `codex login status`.

### O que eu mudaria

1. Corrigiria imediatamente o `CODEX_HOME` padrão.
2. Detectaria e exibiria o modo de autenticação:
   ChatGPT, API key ou access token.
3. Para ChatGPT auth, usaria `account/rateLimits/read` como fonte da janela.
4. Para API key, não mostraria uma “janela de cinco horas”: o uso é faturado
   pela Platform e tem outra semântica. A documentação oficial distingue
   assinatura de acesso por uso:
   [Codex authentication](https://learn.chatgpt.com/docs/auth).
5. Usaria `codex exec --json` e outcomes estruturados.
6. Para ping isolado, avaliaria `--ephemeral`, `--ignore-user-config` e
   `--ignore-rules`; o sandbox read-only sozinho não desliga plugins, hooks,
   MCP ou outras integrações com efeitos externos.
7. Resolveria skills a partir do cwd e do repositório.

Há ainda uma contradição funcional: o produto permite escrever uma tarefa
Codex arbitrária, mas batch e Terminal sempre forçam `--sandbox read-only`
(`Sources/Ohayo/CommandRunner.swift:194-214` e
`Sources/Ohayo/TerminalLauncher.swift:77-87`). Um pedido para corrigir código,
formatar arquivos ou criar um commit não consegue escrever, e a UI não explica
essa restrição. Eu ofereceria presets:

- renovação/consulta: `read-only`;
- tarefa de projeto: `workspace-write`, com cwd obrigatório;
- interativa: permissões visíveis no Terminal;
- nenhum bypass perigoso como default.

O reasoning também tem uma ambiguidade confirmada. A UI usa `low` como valor
inicial, mas só persiste o campo quando ele é diferente de `low`
(`Sources/Ohayo/AgendamentoFormSheet.swift:397-400`). Portanto selecionar “low”
pode significar “usar o default da conta”; se `config.toml` estiver em `high`,
o runtime não executa em low. Deve existir uma opção separada “Padrão da conta”,
e o enum precisa acompanhar capabilities atuais, incluindo `xhigh`.

### Catálogo de skills Codex está desatualizado

`SkillCatalog` varre somente `<configDir>/skills`
(`Sources/Ohayo/SkillCatalog.swift:13-22`). A documentação atual informa que o
Codex carrega skills do usuário em `$HOME/.agents/skills`, skills de
`$CWD/.agents/skills` até a raiz do repositório, além de scopes admin e system:
[Codex skills](https://learn.chatgpt.com/docs/build-skills).

Consequências:

- o picker pode ficar vazio embora o Codex reconheça skills;
- skills do projeto escolhido não aparecem;
- o picker e o runtime podem discordar;
- plugins e skills bundled não são representados.

O resolver deve receber `provider + account + workingDir` e retornar origem,
escopo, conflito e disponibilidade efetiva.

Em vez de reconstruir isso manualmente, o adapter pode usar `skills/list` do
app-server, que já resolve skills por cwd. O mesmo adapter pode usar
`account/read` para email, plano e tipo de autenticação, evitando ler
`auth.json` inteiro apenas para extrair o email
(`Sources/Ohayo/AccountIdentity.swift:40-45`).

## Problemas que um usuário novo provavelmente encontrará

| Momento | O que pode acontecer | Causa |
|---|---|---|
| Instalação | Gatekeeper bloqueia o app | assinatura ad-hoc e ausência de notarização |
| Primeiro launch | vê apenas permissões, sem ajuda de CLI/login | onboarding não possui “Doctor” |
| Conta Claude padrão | recebe falso “não autenticado” | `CLAUDE_CONFIG_DIR=~/.claude` |
| Conta Codex padrão em batch | preflight passa e execução falha deslogada | `CODEX_HOME=~/.claude` |
| Criar tarefa | “Nenhuma” significa batch sem resposta | rótulo e default pouco claros |
| Tornar contínua | fica em “aguardando janela” para sempre | falta bootstrap |
| Usar Terminal | histórico mostra sucesso após apenas abrir a janela | ausência de supervisão |
| Escolher skill | outras customizações são ativadas junto | safe mode é desligado globalmente |
| Tarefa longa | termina em timeout depois de 60 s | timeout único e fixo |
| Permissão negada | botão tenta pedir de novo, sem abrir Ajustes | estado de recuperação incompleto |
| Conta custom sumiu | provider pode virar Claude e edição redirecionar conta | provider inferido do disco, não persistido |

Há ainda inconsistências verificadas:

- o README diz que Terminal é o default, mas o formulário novo começa em
  “Nenhuma”/batch;
- o README promete descoberta inicial de outros `~/.claude*`, mas
  `discoverAccounts` não faz essa varredura;
- `~/.claude` aparece sempre, mesmo inexistente;
- Claude ausente é tratado como alerta relevante até para um usuário somente
  Codex/shell;
- o diretório padrão descrito pela UI não é igual nos modos batch e Terminal.

## Distribuição e operação

O build do app foi concluído e as verificações locais retornaram:

```text
plutil -lint build/Ohayo.app/Contents/Info.plist
OK

codesign --verify --deep --strict build/Ohayo.app
exit=0

spctl --assess --type execute --verbose=4 build/Ohayo.app
rejected, exit=3
```

Isso é coerente com `scripts/make-app.sh`, que usa assinatura ad-hoc, e com o
README, que orienta “Open Anyway” ou remoção de quarantine. Para um produto de
menu bar voltado a usuários menos técnicos, esse é um bloqueador de confiança.

Prioridades:

1. Developer ID, hardened runtime e notarização;
2. smoke test do `.app` empacotado;
3. `hdiutil verify`, mount e validação do conteúdo do DMG;
4. `spctl` como gate esperado no release;
5. mecanismo de update assinado;
6. matriz macOS 13/14/15 e arquitetura suportada.

`scripts/make-dmg.sh` também ignora qualquer exit de `create-dmg` com `|| true`;
isso deve aceitar somente o código conhecido e validar o DMG, não apenas sua
existência.

## Testes e observabilidade

### Resultado atual

A suíte completa executou **303 testes e falhou em 2**:

- `testFireNowRegistraSucessoComOrigemManual`;
- `testFireNowSobrepoePausaDaConta`.

O recorte reproduzido foi:

```text
swift test --filter AppEnvironmentTests
8 testes, 2 falhas
```

Os testes esperam sucesso com launcher fake, mas `AppEnvironment` constrói um
`CLIAuthenticationChecker` real internamente. Nesta máquina, o override
incorreto da conta Claude transforma o resultado em “não autenticado”. Em CI,
a ausência do binário pode gerar `.unknown` e passar em fail-open, então o verde
do pipeline não prova o fluxo real.

### Gaps prioritários

- composição real de ambiente para Claude e Codex;
- conta nativa versus conta customizada;
- fixtures de transcript de auth/model/rate-limit error;
- bootstrap e restart de tarefa contínua;
- retry por categoria de erro;
- exit real do modo Terminal;
- contract tests com versões mínima e atual das CLIs;
- performance do detector em diretórios grandes;
- UI tests de onboarding, permissões, teclado e VoiceOver;
- smoke do `.app`, DMG e Gatekeeper.

Cada execução deveria persistir ao menos:

- run ID e task ID;
- provider, account ID e auth mode;
- estado e timestamps de cada transição;
- cwd e versão da CLI;
- session/thread ID;
- exit code;
- usage/custo quando disponíveis;
- erro estruturado e cauda do log.

## Arquitetura recomendada

Hoje existem protocolos úteis (`CommandRunning`, `TerminalLaunching`,
`AuthenticationChecking`, `SessionDetecting`), mas as regras de provider estão
espalhadas por `Provider`, `AppState`, `CommandRunner`, `TerminalLauncher`,
`AuthenticationChecker`, `AccountIdentity`, `SessionDetector` e
`SkillCatalog`.

Eu aprofundaria três módulos:

```text
ScheduleEngine
      |
      v
PersistentJobQueue ---> RunEventStore ---> History / Notifications
      |
      v
ProviderRuntime
  |- ClaudeRuntime
  |- CodexRuntime
  `- ShellRuntime
      |
      +-- AccountContext
      +-- QuotaSource
      +-- CapabilityProfile
      `-- SkillResolver
```

### `AccountContext`

Deve ser a única fonte para:

- provider;
- conta nativa ou customizada;
- ID canônico;
- auth mode;
- env overrides;
- arquivo de identidade;
- raiz de transcripts;
- cwd e capabilities.

### `ProviderRuntime`

Interface conceitual:

```swift
protocol ProviderRuntime {
    func probe(account: AccountContext) async -> ProviderHealth
    func quota(account: AccountContext) async -> QuotaWindowState
    func run(_ request: RunRequest) -> AsyncStream<RunEvent>
    func skills(account: AccountContext, workingDir: URL) async -> [ResolvedSkill]
}
```

Cada adapter pode usar a melhor fonte disponível sem contaminar o domínio com
detalhes como `CLAUDE_CONFIG_DIR`, `CODEX_HOME` ou schemas JSONL.

### `PersistentJobQueue`

Deve possuir:

- máquina de estados;
- concorrência por provider/conta;
- retry/backoff;
- cancelamento;
- timeout por job;
- idempotência;
- recuperação após restart;
- distinção entre `launched` e `completed`.

Isso elimina o retorno booleano de `fire`, o lock global e o retry implícito
baseado na presença de transcript.

## Features que eu implementaria

### Primeiro: features de confiança

| Feature | Valor |
|---|---|
| Provider Doctor | detecta CLI, versão, auth, conta, cwd, permissões e executa dry-run |
| “Iniciar janela agora” | resolve o bootstrap com consentimento explícito de consumo |
| Dashboard de quota | mostra `verificado`, `estimado` ou `indisponível`, nunca uma falsa precisão |
| Execução supervisionada | estados reais, streaming, attach, cancelamento e retry |
| Preview de execução | mostra provider, conta, cwd, env, sandbox e customizações antes de salvar |
| Reparar conta | recria/login em perfil custom ou permite remapear pasta ausente |
| Diagnóstico exportável | versões, health, últimos estados e logs redigidos |

### Depois: features de produto

| Feature | Valor |
|---|---|
| Templates | “manter janela ativa”, briefing matinal, repo health e revisão de PR |
| Orçamento por provider | pausa ao atingir limite e explica quando volta |
| Skills por projeto | catálogo igual ao que a CLI realmente resolve |
| Import/export | backup e migração de tarefas sem copiar credenciais |
| Histórico pesquisável | duração, custo, status, export e retenção configurável |
| Perfis de segurança | ping mínimo, read-only, workspace-write e custom |
| Suporte a terminal/PTY | escolha do terminal ou sessão incorporada supervisionada |
| Auto-update | atualizações assinadas e rollback seguro |

Eu não priorizaria agora mais modelos hardcoded, mais cards visuais ou mais tipos
de agenda. Essas melhorias ampliariam uma base cujo estado ainda não é
confiável.

## Roadmap sugerido

### Hotfix — antes da próxima release

1. Corrigir conta Claude nativa sem `CLAUDE_CONFIG_DIR`.
2. Corrigir `CODEX_HOME` da composição real.
3. Tornar os testes de `AppEnvironment` herméticos.
4. Filtrar transcripts de erro e exibir estado indisponível.
5. Implementar bootstrap explícito da primeira janela.
6. Registrar Terminal como `launched`, nunca como `success`.
7. Corrigir README/default do seletor de saída.

### Runtime v2

1. Introduzir `AccountContext` e adapters por provider.
2. Implementar outcomes e run events estruturados.
3. Criar fila persistente e retry/backoff.
4. Usar rate limits oficiais do Codex quando disponíveis.
5. Adicionar Provider Doctor e preview de execução.
6. Separar customizações, permissões e sandbox.

### Segurança, distribuição e escala

1. Consentimento de trust/imports externos.
2. Retenção, limpeza e redação de histórico/notificações.
3. Developer ID, notarização, smoke e auto-update.
4. Resolver formalmente o enquadramento do uso de OAuth Claude.
5. Contract tests contínuos contra mudanças das CLIs.

### Expansão de produto

Somente após os estados de execução e quota serem confiáveis: templates,
orçamentos, catálogo de skills por projeto, analytics locais, import/export e
suporte avançado a sessões.

## Critério de “pronto para novo usuário”

Eu consideraria o Ohayo pronto quando este cenário passar de ponta a ponta em um
Mac limpo:

1. instalar sem bypass do Gatekeeper;
2. o Doctor encontrar ou orientar a instalação da CLI;
3. login nativo Claude e ChatGPT Codex serem reconhecidos;
4. criar uma tarefa contínua e iniciar a primeira janela;
5. observar `queued -> running -> completed`;
6. ver quota/reset com origem e confiança explícitas;
7. reiniciar o Mac e recuperar o próximo disparo;
8. provocar auth failure, timeout e rate limit e observar retry/ação correta;
9. limpar/exportar histórico;
10. nunca receber “sucesso” para um processo que apenas foi aberto.

Esse teste vale mais para a promessa do produto do que aumentar a cobertura
unitária isolada.
