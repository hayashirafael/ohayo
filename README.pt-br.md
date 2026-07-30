# Ohayo

[English](README.md) | **Português**

Centro de automações na barra de menus do macOS para Claude, Codex e comandos
shell. Ele pode encadear as janelas de uso de 5h compatíveis por conta e
executar Agendamentos automaticamente. Swift + SwiftUI (`MenuBarExtra`), com
Sparkle para atualizações seguras dentro do app.

## Por quê

Os planos Claude (Pro/Max) abrem uma janela de uso de 5h a partir do primeiro
prompt. Quem usa pesado quer a janela já aberta na hora de sentar para
trabalhar — não gastar a primeira hora dela aquecendo. O Ohayo encadeia as
janelas de cada conta, e um Agendamento contínuo nunca executa de forma
redundante enquanto já existe uma janela ativa. O detector lê passivamente os
transcripts locais do Claude/Codex sem chamar APIs dos provedores; o Sparkle
consulta separadamente o GitHub para buscar atualizações assinadas do app.

## Recursos

- **Agendamentos unificados** — um único conceito para tudo que é agendado.
  Cada agendamento carrega um comando embutido e uma repetição: **Contínua**
  (encadeia janelas de 5h e inicia automaticamente sem evidência de janela
  ativa, a menos que você desligue esse comportamento) ou **Horários fixos**
  (horários × dias da semana). Tudo na seção **Agendamentos**
- **Comandos configuráveis** — um prompt do Claude (modelo, esforço,
  safe-mode, pasta de trabalho), um prompt do Codex (modelos e esforços de
  raciocínio descobertos na conta selecionada, acesso total por padrão com
  alternativas de escrita na pasta e somente leitura, pasta de trabalho), ou
  qualquer comando shell — embutido direto no agendamento. Prompts
  Claude/Codex abrem no Terminal.app por padrão, para você continuar
  interagindo na mesma sessão; se desligar essa opção, rodam em modo batch
- **Multi-conta, Claude e Codex** — as pastas padrão (`~/.claude`, `~/.codex`)
  são detectadas automaticamente quando existem; outras pastas `~/.claude*`
  entram uma única vez, na primeira abertura, e daí em diante novas contas são
  adicionadas a qualquer momento via "Adicionar conta…" — mostra o e-mail
  logado, aceita apelidos
- **Histórico e arquivos de resposta** — disparos recentes com status e
  resposta expansível (Markdown é formatado quando selecionado, e o
  stdout/stderr das falhas continua disponível), incluindo o estado separado
  **Iniciado** para sessões interativas no Terminal. Respostas batch do
  Claude/Codex podem ser salvas em `.md` (padrão) ou `.txt` numa pasta
  escolhida, com pastas favoritas para reutilização
- **Notificações privadas por padrão** — notificações do macOS escondem
  prompt, resposta, erro e conta até você habilitar explicitamente os detalhes
  em **Geral**
- **Provider Doctor** — verificações somente leitura, na primeira abertura, da
  instalação das CLIs e do login de cada conta Claude/Codex configurada; nunca
  executa prompt nem consome cota
- **Idioma** — inglês por padrão, com opção para português em **Geral**
- **Atualizações dentro do app** — consulta automaticamente o feed assinado
  das releases no GitHub; instala e reinicia sem download manual do DMG
- **Pausar/Retomar** por conta, em **Contas**, e **Iniciar com o Mac**
  opcional

## Requisitos

- macOS 13+; as releases publicadas desde a v1.2.0 são universais para Apple
  Silicon e Intel
- [Claude Code](https://claude.com/claude-code) instalado e logado (somente
  se você usar Agendamentos Claude)
- [Codex CLI](https://github.com/openai/codex) instalado e logado (opcional,
  só para contas/comandos Codex)
- Para build a partir do código: Swift 5.9+ (Xcode ou Command Line Tools)

O Ohayo verifica a conta Claude ou Codex selecionada imediatamente antes de
cada disparo agendado. Se a conta não estiver logada, o disparo é registrado
sem abrir uma sessão; o histórico mostra o comando exato de login com a pasta
da conta selecionada. Se a CLI falhar por outro motivo, os detalhes do
histórico preservam stdout e stderr quando disponíveis.

## Instalação

### Homebrew

```bash
brew tap hayashirafael/tap
brew trust --cask hayashirafael/tap/ohayo
brew install --cask ohayo
```

O Homebrew instala a release publicada mais recente. Instalações anteriores à
v1.2.0 precisam de um último `brew upgrade --cask ohayo`; depois disso, as
próximas releases também podem ser instaladas em **Ohayo → Geral → Sobre →
Buscar atualizações…**.

### DMG

Baixe o `Ohayo-<versão>.dmg` da [última release](../../releases/latest) e
arraste o **Ohayo** para **Applications**.

> As releases publicadas desde a v1.2.0 são universais para Apple Silicon e
> Intel.
> Builds existentes para testers, assinados ad-hoc, podem perder a autorização
> de privacidade do macOS após uma atualização porque sua identidade de código
> não é estável. Novas releases públicas desta revisão ficam bloqueadas sem
> Developer ID, hardened runtime, notarização e stapling. Builds locais a partir
> do código continuam ad-hoc e podem pedir acesso a pastas protegidas novamente
> após cada rebuild.

### A partir do código

```bash
git clone https://github.com/hayashirafael/ohayo.git
cd ohayo
swift test            # suíte de testes
./scripts/make-app.sh # build/Ohayo.app (assinado ad-hoc)
./scripts/make-dmg.sh # build/Ohayo-<versão>.dmg (requer `brew install create-dmg`)
open build/Ohayo.app
```

Para um build local isolado que pode rodar junto do app instalado pelo DMG:

```bash
./scripts/make-dev-app.sh
open "build/Ohayo Dev.app"
orca computer get-app-state --app io.github.hayashirafael.Ohayo.dev --json
```

Se o Computer Use não conseguir inspecionar diretamente a superfície da menu
bar, exponha a janela central do app no canal de desenvolvimento:

```bash
open "build/Ohayo Dev.app" --args --ui-testing
```

O `Ohayo Dev.app` usa o bundle ID `io.github.hayashirafael.Ohayo.dev`,
`~/Library/Application Support/Ohayo Dev`, um lock de instância e um domínio de
preferências separados. Atualizações no app e Iniciar com o Mac ficam
indisponíveis nesse canal. O desenvolvimento começa sem copiar contas,
agendamentos, histórico ou preferências do app de produção.

### Atualizações

A versão 1.2.0 introduziu o atualizador. Instalações ainda sem Sparkle precisam
de uma última atualização manual via Homebrew/DMG. Releases a partir da v1.2.0
consultam diariamente o feed assinado e oferecem **Instalar e reiniciar**
dentro do app. Use **Ohayo → Geral → Sobre → Buscar atualizações…** para
verificar imediatamente.

Os arquivos de atualização e o feed são validados criptograficamente por uma
chave EdDSA separada do Sparkle. O workflow de release agora falha de forma
fechada sem todas as credenciais de Developer ID, notarização e Sparkle; ele
publica juntos o DMG notarizado e o `appcast.xml` assinado.

## Primeiros passos

1. Abra o Ohayo e conclua ou feche o guia inicial não bloqueante.
2. Em **Contas**, confirme as contas Claude/Codex que deseja usar.
3. Em **Agendamentos**, escolha **Novo Agendamento…** e configure o Comando.
4. Selecione **Contínua** para encadear Janelas de uso detectadas ou **Horários
   fixos** para horários e dias da semana específicos.
5. Use o painel da barra de menus para os próximos Disparos e o **Histórico**
   para resultados e detalhes capturados das falhas.

## Uso

O Ohayo vive na barra de menus, sem ícone permanente no Dock. O macOS exibe um
ícone no Dock apenas enquanto uma janela padrão do Ohayo está aberta, para que
ela possa receber foco. O ícone da barra de menus fica preenchido enquanto
alguma conta tem janela ativa, mostra `!` em erro e esmaece quando todas as
contas agendadas estão pausadas; opcionalmente mostra também o tempo até a
próxima janela vencer entre elas.

Clicar no ícone abre um painel com os próximos disparos agendados entre todas as
contas — quantos, é configurável em **Geral** (1–5, padrão 1) — ordenados
por horário; contas pausadas são puladas, então só aparece o que vai
executar de fato. O primeiro vem em destaque, os demais em linhas compactas:
ícone do provedor, rótulo da conta, nome do Agendamento e horário. Se não houver
nada para mostrar, o painel explica o motivo (nenhum agendamento ativo,
todas as contas pausadas, ou apenas aguardando a próxima janela/horário).
Clicar num card ou linha abre **Ohayo → Agendamentos** filtrado para aquela
conta. O rodapé tem **Agendamentos**, **Histórico** e **Ajustes…**. Uma CLI
ausente vira um aviso acionável de configuração; **Ajustes…**,
**Permissões…** e **Sair do Ohayo** ficam agrupados no menu de ações
secundárias.

A janela central **Ohayo** abre em **Agendamentos** e tem uma sidebar com
quatro seções:

- **Contas** — por conta, a identidade logada / apelido, o provedor com seu
  ícone, a pasta local, quantos agendamentos ativos miram a conta, e
  **Pausar/Retomar** por conta. Adicione ou remova contas aqui
- **Agendamentos** — a lista única de Agendamentos. Cada um tem nome, um tipo
  (Claude / Codex / comando shell) com sua config, uma conta e uma repetição —
  **Contínua** (encadeia janelas de uso, no máximo uma por conta) ou
  **Horários fixos** (horários × dias da semana). Um único formulário cria ou
  edita qualquer um deles; novos Agendamentos começam com o campo de Comando
  vazio. Entrar por um Agendamento no painel do menu filtra essa lista para a
  conta, com um chip para limpar o filtro
  - **Skill opcional:** em Agendamentos Claude/Codex, escolha uma skill da
    conta, do usuário ou do repositório selecionado. O Ohayo resolve skills da
    conta/plugins Claude e `.claude/skills` nos ancestrais; para Codex, resolve
    também `$HOME/.agents/skills`, `.agents/skills` nos ancestrais e as skills
    dos plugins que a conta selecionada declara instalados e habilitados em
    `codex plugin list --json`. A consulta é somente leitura e nunca executa um
    prompt. Cada Disparo prefixa a skill ao Comando (`/skill comando` no
    Claude, `$skill comando` no Codex). Selecionar uma skill carrega as
    customizações do Claude; a UI deixa claro que isso amplia o contexto e não
    é sandbox de filesystem
- **Histórico** — disparos recentes em cards com status, ícone do provedor,
  modelo, apelido/e-mail da conta, comando, resposta Markdown formatada, link
  para o arquivo salvo e detalhes de erro; filtrável por conta do mesmo jeito
  que Agendamentos
- **Geral** — Iniciar com o Mac, tempo restante na barra de menus, detalhes
  sensíveis nas notificações (desligados por padrão), quantos próximos Disparos
  o painel mostra (1–5), Idioma, acesso ao sistema, a versão do app e **Buscar
  atualizações…**. Abra por **Ajustes…** ou com `⌘,`

### Permissões na primeira abertura

O app empacotado abre uma única vez um guia não bloqueante. O Provider Doctor
verifica quais CLIs Claude/Codex e contas configuradas estão prontas e mostra o
comando de login correto quando há algo a corrigir. As verificações são somente
leitura: nunca executam prompt, iniciam login ou consomem cota. Nele você também
pode permitir notificações, testar a automação do Terminal usada nas sessões
interativas e, opcionalmente, ativar **Iniciar com o Mac**. Fechar o guia não
desativa o app; reabra-o pelo menu de ações secundárias do painel ou em
**Ohayo → Geral → Acesso ao Sistema → Permissões…**.

Se notificações ou automação do Terminal forem negadas, altere-as em **Ajustes
do Sistema → Notificações → Ohayo** ou **Ajustes do Sistema → Privacidade e
Segurança → Automação** e reabra o guia para atualizar ou testar a integração.

Ao salvar um Agendamento Claude com **Confiar nesta pasta para o Claude**
ligado, ou um Agendamento Codex em **Acesso total** ou **Escrita na pasta**, o
Ohayo verifica o acesso imediatamente. Para uma pasta protegida pelo macOS,
como Documents, escolha **Permitir** no diálogo do sistema. Um Ohayo assinado
com Developer ID mantém essa autorização entre atualizações; um rebuild local
ou de teste ad-hoc tem outra identidade de código e o macOS pode perguntar de
novo. O app não pode clicar nem conceder essa permissão de privacidade por você.

## Como funciona

Para manter as Repetições Contínuas, o Ohayo lê os transcripts locais da
conta (`<conta>/projects/**.jsonl` no Claude, `sessions/**.jsonl` no Codex,
por `mtime`) e reconstrói a janela de 5h corrente. Só aceita evidência positiva
de uso: evento real de assistant Claude, sem erro/sintético e com tokens, ou
evento Codex `token_count` com `last_token_usage` positivo. Falhas de
autenticação/modelo/rede e eventos com zero tokens não criam uma janela
fictícia. Transcripts ilegíveis ou um schema de uso desconhecido viram um
estado indisponível explícito e nunca iniciam um bootstrap. Se houver uma
ativa, somente um Disparo contínuo redundante é pulado; Agendamentos em
Horários Fixos sempre executam.

Um Disparo do Claude inicia:

```
claude -p --model <modelo> --effort <esforço> [--safe-mode]
```

O prompt é escrito em stdin, em vez de exposto na lista de argumentos do
processo. A conta Claude nativa roda deliberadamente com
`CLAUDE_CONFIG_DIR` ausente, pois exportar `~/.claude` muda a semântica de
conta do Claude Code; perfis Claude customizados recebem o override. O Codex
recebe o `CODEX_HOME` selecionado, com `~/.codex` como padrão. Agendamentos shell
não recebem variável de nenhum provider.

Se o agendamento tem skill, o prompt é prefixado antes do disparo (`/skill
comando` no Claude, `$skill comando` no Codex). No Claude isso exige carregar
as customizações; “ignorar customizações do Claude” não é apresentado como
sandbox.

Por padrão, Claude/Codex abrem no Terminal.app sem `-p` / `exec`, deixando a
sessão interativa aberta. Abrir o Terminal é registrado como **Iniciado**, não
como execução concluída: o Ohayo não observa o exit status final da sessão. Um
Agendamento interativo em Horários Fixos ainda abre no horário agendado mesmo
com janela ativa. Sem diretório de trabalho, disparos de provider interativos e
batch usam `~/Library/Application Support/Ohayo/workspace` em vez da sua pasta
pessoal (ou o equivalente isolado `Ohayo Dev/workspace`). O script temporário
privado usa modo `0600`, se remove no exit/sinais e resíduos antigos de crash
são limpos.

Depois de escolher uma pasta de trabalho, o Ohayo pode solicitar acesso a ela
ao salvar o Agendamento. O Claude mantém a opção dedicada **Confiar nesta pasta
para o Claude**, ligada por padrão, que registra apenas o trust básico do
projeto. O Codex usa um único controle **Acesso** com três modos explícitos:
**Acesso total** (padrão, sem sandbox nem pedidos de aprovação), **Escrita na
pasta** (pasta confiada com sandbox `workspace-write`) e **Somente leitura**
(sem pré-autorizar o trust da pasta). Sessões Codex interativas e confiadas
recebem um override oficial efêmero
`projects.<path>.trust_level="trusted"`; o Ohayo nunca reescreve o
`config.toml`. Imports externos do `CLAUDE.md` nunca são pré-aprovados, então
esse consentimento separado continua visível.

Os padrões Claude — Haiku, esforço baixo, customizações ignoradas e `1+1` —
formam um Comando mínimo para a Repetição Contínua. O Ohayo lê o
`models_cache.json` da conta Codex selecionada para oferecer apenas os modelos
listados e seus esforços de raciocínio compatíveis, com um fallback interno
atual quando esse cache não estiver disponível. Um Disparo Codex batch executa
`codex exec [--model <modelo>]` com
`--dangerously-bypass-approvals-and-sandbox` em **Acesso total**, `--sandbox
workspace-write` em **Escrita na pasta** ou `--sandbox read-only` em **Somente
leitura**, seguido de `--skip-git-repo-check --color never` e de um override de
raciocínio opcional. O mesmo modo de acesso vale para sessões interativas no
Terminal, e no batch o prompt sempre chega por stdin. Em **Padrão da conta**,
modelo e raciocínio são omitidos para o `config.toml` valer.

Quando **Mostrar resposta** está ligado num Agendamento Claude/Codex batch, a
resposta capturada completa é salva atomicamente como Markdown (padrão) ou
texto simples na pasta selecionada; o padrão é
`~/Library/Application Support/Ohayo/Responses` (ou o equivalente isolado
`Ohayo Dev/Responses`). Pastas favoritas ficam salvas localmente para
reutilização. O Histórico mantém uma prévia limitada, renderiza Markdown e
oferece um link para o arquivo. O timeout batch é configurável por agendamento:
o padrão é 15 minutos para Claude/Codex e 5 minutos para shell; sessões
interativas no Terminal não são supervisionadas por timeout. A captura do
processo é limitada preservando o início e a cauda, onde normalmente está o
erro.
Só uma instância do Ohayo roda por vez. Dentro dela, disparos formam uma fila
FIFO por provider/conta em vez de serem descartados por um lock global; contas
diferentes podem avançar em paralelo. Falhas transitórias usam backoff
exponencial limitado; falta de login/CLI ou permissão do Terminal vira estado
que exige atenção, sem loop de alertas.

Qual conta é Claude ou Codex é inferido pelo conteúdo da pasta, não pelo nome,
nesta ordem: um `.claude.json` indica Claude; senão um `auth.json` indica
Codex; senão uma subpasta `projects/` indica Claude; senão uma subpasta
`sessions/` indica Codex. O provider de uma conta custom cadastrada também é
persistido, então uma pasta temporariamente ausente ou ambígua não muda de
provider; disparo e leitura de cota recebem essa identidade explicitamente.
Pastas de conta existentes usam o caminho canônico do filesystem como
identidade. Cadastrar ou selecionar um symlink para a mesma conta Claude/Codex
não cria outra fila, Agendamento, pausa nem cooldown de cota.

Um novo agendamento **Contínuo** tenta iniciar automaticamente quando não existe
evidência de janela ativa. Esse também é o padrão de compatibilidade para
agendamentos contínuos criados por versões anteriores do Ohayo. Desligue
**Tentar iniciar quando não houver janela ativa** para mantê-lo aguardando. O
formulário avisa que o comando pode consumir cota do provedor. Depois de uma
tentativa de bootstrap entregue, o Ohayo espera até cinco horas antes de tentar
outra vez para esse agendamento, inclusive após reiniciar o app; se uma janela
real aparecer antes, seu transcript substitui o cooldown. Falhas transitórias
conhecidas mantêm o retry exponencial mais curto.
O backoff começa quando a falha retorna. Um hand-off agendado mantém seu próprio
cooldown de recuperação mesmo quando o início automático foi explicitamente
desligado. Erros de
autenticação, CLI, permissão ou configuração param em um estado que
exige atenção, em vez de virar outro cooldown. Pausar a conta ou desligar a
opção cancela o trabalho de bootstrap. Depois de detectar uma janela, o Ohayo
arma no fim dela e encadeia a próxima; uma tentativa redundante é pulada
enquanto a janela está ativa.
Um agendamento de **Horários fixos** sempre dispara nos seus horários × dias da
semana, tanto em batch quanto no modo interativo. No wake, horários fixos
disparam no máximo uma vez para recuperar a ocorrência mais recente que perdeu
— um sleep longo nunca gera uma rajada de disparos atrasados, e o launch em si
nunca reproduz ocorrências perdidas antes dele.
