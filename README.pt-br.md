# Ohayo

[English](README.md) | **Português**

App de menu bar para macOS que mantém as janelas de uso de 5h do seu plano
Claude sempre abertas — por conta, automaticamente. Swift + SwiftUI
(`MenuBarExtra`), com Sparkle para atualizações seguras dentro do app.

## Por quê

Os planos Claude (Pro/Max) abrem uma janela de uso de 5h a partir do primeiro
prompt. Quem usa pesado quer a janela já aberta na hora de sentar para
trabalhar — não gastar a primeira hora dela aquecendo. O Ohayo encadeia as
janelas de cada conta, e um Agendamento contínuo nunca executa de forma
redundante enquanto já existe uma janela ativa: ele detecta a janela corrente
passivamente pelos transcripts locais do Claude Code, sem nenhuma chamada de
rede própria.

## Recursos

- **Agendamentos unificados** — um único conceito para tudo que é agendado.
  Cada agendamento carrega um comando embutido e uma repetição: **Contínua**
  (encadeia janelas de 5h, com opt-in explícito antes de iniciar sem evidência
  de janela ativa) ou **Horários fixos** (horários × dias da semana). Tudo na
  seção **Agendamentos**
- **Comandos configuráveis** — um prompt do Claude (modelo, esforço,
  safe-mode, pasta de trabalho), um prompt do Codex (modelo, esforço de
  raciocínio, pasta de trabalho), ou qualquer comando shell — embutido direto
  no agendamento. Prompts Claude/Codex abrem no Terminal.app por padrão, para
  você continuar interagindo na mesma sessão; se desligar essa opção, rodam em
  modo batch
- **Multi-conta, Claude e Codex** — as pastas padrão (`~/.claude`, `~/.codex`)
  são detectadas automaticamente quando existem; outras pastas `~/.claude*`
  entram uma única vez, no primeiro launch, e daí em diante novas contas são
  adicionadas a qualquer momento via "Adicionar conta…" — mostra o e-mail
  logado, aceita apelidos
- **Histórico** — disparos recentes com status e resposta expansível (log
  capturado de stdout/stderr nas falhas), incluindo o estado separado
  **Iniciado** para sessões interativas no Terminal; pode ser limpo a qualquer
  momento
- **Notificações privadas por padrão** — notificações do macOS escondem
  prompt, resposta, erro e conta até você habilitar explicitamente os detalhes
  em **Geral**
- **Provider Doctor** — verificações somente leitura, na primeira abertura, da
  instalação das CLIs e do login de cada conta Claude/Codex configurada; nunca
  executa prompt nem consome cota
- **Idioma** — inglês por padrão, com opção para português nos Ajustes
- **Atualizações dentro do app** — consulta automaticamente o feed assinado
  das releases no GitHub; instala e reinicia sem download manual do DMG
- **Pausar/Retomar** por conta, em **Contas**, e **Iniciar com o Mac**
  opcional

## Requisitos

- macOS 13+ (o binário v1.1.1 publicado atualmente exige Apple Silicon; a
  próxima release gerada por esta revisão será universal)
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

O Ohayo deve ser instalado de forma limpa. Remova completamente qualquer
instalação anterior antes de instalar a primeira versão com Sparkle. Depois
dessa instalação-bootstrap, as próximas releases podem ser instaladas em
**Ohayo → Geral → Sobre → Buscar atualizações…**.

### DMG

Baixe o `Ohayo-<versão>.dmg` da [última release](../../releases/latest) e
arraste o **Ohayo** para **Applications**.

> O artefato v1.1.1 publicado atualmente funciona somente em Apple Silicon. A
> distribuição gratuita para testers a partir da v1.2.0 é universal para Apple
> Silicon e Intel, assinada ad-hoc e não notarizada. Na primeira abertura, o
> Gatekeeper pode exigir clicar com o botão direito no app e escolher **Abrir**
> ou usar **Ajustes do Sistema → Privacidade e Segurança → Abrir Assim Mesmo**.
> Quando todas as credenciais Apple forem configuradas, o mesmo workflow passa
> automaticamente a usar Developer ID, hardened runtime, notarização e
> stapling.

### A partir do código

```bash
git clone https://github.com/hayashirafael/ohayo.git
cd ohayo
swift test            # suíte de testes
./scripts/make-app.sh # build/Ohayo.app (assinado ad-hoc)
./scripts/make-dmg.sh # build/Ohayo-<versão>.dmg (requer `brew install create-dmg`)
open build/Ohayo.app
```

### Atualizações

A versão 1.2.0 é o bootstrap do atualizador. Instalações anteriores, ainda sem
Sparkle, precisam desta última atualização manual via Homebrew/DMG. A partir da
1.2.0, o Ohayo consulta diariamente o feed assinado e oferece **Instalar e
reiniciar** dentro do app. Use **Ohayo → Geral → Sobre → Buscar
atualizações…** para verificar imediatamente.

Mesmo no modo gratuito para testers, os arquivos de atualização e o feed são
validados criptograficamente por uma chave EdDSA separada do Sparkle. Developer
ID e notarização da Apple ficam intencionalmente para depois; até lá, a primeira
instalação não tem a confiança do Gatekeeper. O workflow de release publica
juntos o DMG final e seu `appcast.xml` assinado.

## Uso

O Ohayo vive na menu bar, sem ícone permanente no Dock. O macOS exibe um ícone
no Dock apenas enquanto uma janela padrão do Ohayo está aberta, para que ela
possa receber foco. O ícone da menu bar fica preenchido enquanto alguma conta
tem janela ativa, mostra `!` em erro e esmaece quando todas as contas agendadas
estão pausadas; opcionalmente mostra também o tempo até a próxima janela vencer
entre elas.

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
- **Skill (opcional):** em Agendamentos Claude/Codex, escolha uma skill da
  conta, do usuário ou do repositório selecionado. O Ohayo resolve skills da
  conta/plugins Claude e `.claude/skills` nos ancestrais; para Codex, resolve
  também `$HOME/.agents/skills`, `.agents/skills` nos ancestrais e as skills
  dos plugins que a conta selecionada declara instalados e habilitados em
  `codex plugin list --json`. A consulta é somente leitura e nunca executa um
  prompt. Cada Disparo prefixa a skill ao Comando (`/skill comando` no Claude,
  `$skill comando` no Codex). Selecionar uma skill carrega as customizações
  do Claude; a UI deixa claro que isso amplia o contexto e não é sandbox de
  filesystem
- **Histórico** — disparos recentes em cards com status, ícone do provedor,
  modelo, apelido/e-mail da conta, comando, resposta e detalhes de erro;
  filtrável por conta do mesmo jeito que Agendamentos
- **Geral** — Iniciar com o Mac, tempo restante na barra de menus, detalhes
  sensíveis nas notificações (desligados por padrão), quantos próximos Disparos
  o painel mostra (1–5), Idioma, acesso ao sistema, a versão do app e **Buscar
  atualizações…**

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
com janela ativa.
Sem diretório de trabalho, abre em
`~/Library/Application Support/Ohayo/workspace`. O script temporário privado
usa modo `0600`, se remove no exit/sinais e resíduos antigos de crash são
limpos. O Ohayo semeia o trust básico do projeto Claude apenas nesse workspace
controlado pelo app. Um diretório de trabalho escolhido ou importado pela pessoa
nunca é pré-confiado pelo Ohayo, deixando o Claude exibir seu prompt normal de
trust no Terminal quando necessário. Imports externos do `CLAUDE.md` também
nunca são pré-aprovados; esse consentimento continua visível.

Os padrões Claude — Haiku, esforço baixo, customizações ignoradas e `1+1` —
formam um Comando mínimo para a Repetição Contínua. Um Disparo Codex batch
executa `codex exec [--model <modelo>] --sandbox read-only [-c
model_reasoning_effort=<esforço>]`; o prompt também chega por stdin. Em
**Padrão da conta**, modelo e raciocínio são omitidos para o `config.toml`
valer. O timeout batch é configurável por agendamento: o padrão é 15 minutos
para Claude/Codex e 5 minutos para shell; sessões interativas no Terminal não
são supervisionadas por timeout. A captura é limitada preservando o início e a
cauda, onde normalmente está o erro.

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

Um novo agendamento **Contínuo** aguarda quando não existe evidência de janela
ativa, a menos que você habilite explicitamente **Tentar iniciar quando não
houver janela ativa**. O formulário avisa que o comando pode consumir cota do
provedor e que uma sessão interativa no Terminal ainda pode exigir sua
confirmação. Depois de uma tentativa de bootstrap entregue, o Ohayo espera até
cinco horas antes de tentar outra vez para esse agendamento, inclusive após
reiniciar o app; se uma janela real aparecer antes, seu transcript substitui o
cooldown. Falhas transitórias conhecidas mantêm o retry exponencial mais curto.
O backoff começa quando a falha retorna. Um hand-off agendado mantém seu próprio
cooldown de recuperação mesmo com o bootstrap opt-in desligado. Erros de
autenticação, CLI, permissão ou configuração param em um estado que
exige atenção, em vez de virar outro cooldown. Pausar a conta ou desligar a
opção cancela o trabalho de bootstrap. Depois de detectar uma janela, o Ohayo
arma no fim dela e encadeia a próxima; uma tentativa redundante é pulada
enquanto a janela está ativa.
Agendamentos criados por versões antigas continuam
aguardando até você editá-los e habilitar essa opção explicitamente. Um
agendamento de **Horários fixos** sempre dispara nos seus horários × dias da
semana, tanto em batch quanto no modo interativo. No wake, horários fixos
disparam no máximo uma vez para recuperar a ocorrência mais recente que perdeu
— um sleep longo nunca gera uma rajada de disparos atrasados, e o launch em si
nunca reproduz ocorrências perdidas antes dele.
