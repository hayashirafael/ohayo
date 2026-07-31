<div align="center">

# Ohayo

### Claude vs Codex — Provider Lab

Configure cada Provedor nos próprios termos. Reúna Agendamentos, evidências de
Janela de uso, respostas, notificações e Histórico em uma central de controle
nativa na barra de menus do macOS.

[English](README.md) · **Português**

macOS 13+ · Apple Silicon + Intel · Swift + SwiftUI

[Instalar com Homebrew](#instalação) ·
[Baixar o DMG mais recente](https://github.com/hayashirafael/ohayo/releases/latest)

</div>

<table>
  <tr>
    <td width="50%">
      <img src="assets/readme/ohayo-claude-controls.png" alt="Controles de Agendamento Claude no Ohayo com repetição Contínua, saída da resposta, modelo, esforço e seleção de Skill instalada">
    </td>
    <td width="50%">
      <img src="assets/readme/ohayo-codex-controls.png" alt="Controles de Agendamento Codex no Ohayo com repetição Contínua, saída da resposta, modelo da Conta, raciocínio e seleção de Skill instalada">
    </td>
  </tr>
  <tr>
    <td><strong>Plano de controle do Claude</strong><br>Escolha no catálogo Claude atual do Ohayo, defina o esforço, reutilize uma Skill instalada e decida se o Ohayo pode pré-autorizar o trust básico da pasta.</td>
    <td><strong>Plano de controle do Codex</strong><br>Escolha um modelo descoberto na Conta e um raciocínio compatível, reutilize uma Skill instalada e defina Acesso total, Escrita na pasta ou Somente leitura explicitamente.</td>
  </tr>
</table>

O Ohayo mantém **Claude Code** e **Codex CLI** nativos sem fingir que são o
mesmo Provedor. Cada Agendamento preserva a Conta selecionada, o projeto, os
controles de modelo, a decisão de permissão, a repetição e o comportamento da
saída. As CLIs continuam sendo pré-requisitos externos: o usuário cuida da
instalação e da autenticação, e elas permanecem responsáveis pelo trabalho que
executam.

Comandos shell também podem executar em horários fixos, mas não ganham contrato
de Conta, modelo, Skill ou Janela de uso do Claude/Codex.

## O mesmo formulário. Controles próprios de cada Provedor.

| | Claude Code | Codex CLI |
| --- | --- | --- |
| **Conta** | `~/.claude` nativa ou uma pasta Claude customizada cadastrada | `~/.codex` nativa ou uma pasta Codex customizada cadastrada |
| **Origem dos modelos** | Catálogo Claude atual do Ohayo: Haiku 4.5, Sonnet 5 e Opus 4.8 | Modelos visíveis no `models_cache.json` da Conta selecionada; um fallback interno só é usado quando o cache está ausente, inválido ou não contém modelos visíveis |
| **Controle de profundidade** | Esforço: low, medium, high, xhigh ou max | Níveis de raciocínio aceitos pelo modelo selecionado; uma escolha incompatível é normalizada para o padrão aceito por aquele modelo |
| **Invocação de Skill** | Uma Skill instalada prefixa o prompt como `/skill` | Uma Skill instalada prefixa o prompt como `$skill` |
| **Acesso ao projeto** | Consentimento separado **Confiar nesta pasta para o Claude**; ligado por padrão para o trust básico do projeto | Modos explícitos **Acesso total**, **Escrita na pasta** ou **Somente leitura** |
| **Execução** | Hand-off interativo ao Terminal ou batch observável em background | Hand-off interativo ao Terminal ou batch observável com `codex exec` |

Os nomes do Claude acima descrevem o catálogo desta versão do Ohayo, não uma
garantia permanente do Provedor. Os modelos Codex dependem ainda mais
explicitamente da Conta: o cache da Conta selecionada é preferido, o fallback
é apenas uma rota de resiliência e nenhuma lista exibida deve ser entendida
como disponibilidade universal.

### Claude: modelo, esforço, Skill e trust

- **Modelo e esforço** são escolhas independentes do Agendamento no catálogo
  Claude atual do Ohayo. A disponibilidade e a execução continuam pertencendo
  à CLI Claude instalada e à Conta selecionada.
- **Skill** seleciona uma customização Claude instalada e prepara sua invocação
  nativa. Por padrão, o Ohayo ignora as customizações do Claude — isso não é
  sandbox. Selecionar uma Skill desliga essa opção para carregar as
  customizações nativas. Uma Skill pode ampliar o contexto do agente, mas não
  concede acesso ao filesystem.
- **Trust da pasta** permite ao Ohayo pré-autorizar o trust básico do projeto
  selecionado. Imports externos de `CLAUDE.md` não são pré-aprovados, e o
  Claude ainda pode pedir consentimento separado pelo próprio fluxo de
  permissões.
- O Claude nativo executa sem forçar `CLAUDE_CONFIG_DIR=~/.claude`; Contas
  customizadas cadastradas recebem seu próprio override.

### Codex: catálogo da Conta, raciocínio, Skill e acesso

- **Modelo e raciocínio** acompanham a Conta selecionada. O Ohayo lê do cache
  as entradas visíveis e os níveis de raciocínio aceitos, mantendo o
  **Padrão da conta** como fonte da verdade quando não há override.
- **Skill** seleciona uma Skill Codex instalada e prepara a invocação `$skill`.
  Ela pode ampliar o contexto; não é sandbox nem concessão de permissão.
- **Acesso total** é o padrão e executa sem sandbox nem pedidos de aprovação.
  **Escrita na pasta** usa o sandbox `workspace-write` na pasta selecionada.
  **Somente leitura** usa o sandbox `read-only`.
- Para uma sessão interativa confiada, o Ohayo passa um override oficial
  efêmero de trust do projeto. Ele não reescreve o `config.toml` da Conta.

## Uma faixa compartilhada: Janelas de uso compatíveis de cinco horas

![Novo Agendamento Claude selecionando repetição Contínua para uma Janela de uso de cinco horas detectada e tentativa opcional de bootstrap](assets/readme/ohayo-claude-continuous.png)

**Contínua** está disponível para os dois Provedores nativos. Ela reconstrói
uma Janela de uso de cinco horas compatível a partir de evidência positiva em
transcripts locais, pula um Disparo Contínuo redundante enquanto a janela está
ativa e programa a próxima tentativa perto do fim detectado.

```text
Evidência local positiva
          ↓
Janela de uso ativa por cinco horas
          ↓
Pula Disparos Contínuos redundantes
          ↓
Tenta novamente perto do fim detectado
```

> Contínua é automação baseada em evidência, não promessa de cota.

- Claude exige um evento real de assistant, sem erro e com uso positivo de
  tokens.
- Codex exige um evento real `token_count` com `last_token_usage` positivo.
- Dados de autenticação, modelo, rede, sintéticos, com zero tokens, ilegíveis
  ou com schema desconhecido nunca criam uma Janela de uso fictícia.
- Um novo Agendamento Contínuo pode tentar iniciar opcionalmente quando a
  detecção concluir que não há janela ativa. Esse Disparo pode consumir cota
  do provedor.
- Um bootstrap entregue sem evidência positiva entra em cooldown limitado; ele
  não é repetido continuamente.

O Ohayo **não** garante reset do provedor, cota disponível, um Disparo concluído
a cada cinco horas nem execução 24/7. Planos, capacidade da Conta e limites
adicionais do provedor continuam sendo a fonte da verdade. Agendamentos em
Horários fixos permanecem independentes e não são suprimidos por uma Janela de
uso ativa.

## Da configuração à evidência

```text
Agendamento + Conta + controles do Provedor
                         ↓
                  Disparo preparado
             ↙                              ↘
Batch em background                 Hand-off ao Terminal
observado pelo Ohayo                aberto para interação
             ↓                              ↓
Resultado + prévia da resposta             Iniciado
+ arquivo capturado + notificação          sem resposta final capturada
             ↘                              ↙
                         Histórico
```

### Batch em background e Terminal são diferentes de propósito

| Execução | O que o Ohayo consegue observar | Contrato do Histórico |
| --- | --- | --- |
| **Batch em background** | Resultado do processo, captura limitada de stdout/stderr, timeout e cancelamento; com **Mostrar resposta**, uma prévia formatada da resposta e um arquivo opcional Markdown ou texto simples com a saída capturada | Sucesso, falha, pulado ou outro resultado observado, com detalhes da resposta quando disponíveis |
| **Terminal** | A sessão interativa foi entregue ao Terminal.app | **Iniciado** — nunca promovido a Sucesso porque o Ohayo não observa o exit status final |

Sem um projeto selecionado, Disparos de Provedor usam
`~/Library/Application Support/Ohayo/workspace`, não a pasta pessoal. Arquivos
de resposta usam por padrão
`~/Library/Application Support/Ohayo/Responses`, e pastas favoritas de
resposta ficam armazenadas localmente.

## Respostas, notificações privadas e Histórico

<table>
  <tr>
    <td width="42%">
      <img src="assets/readme/ohayo-notification-privacy.png" alt="Ajustes Gerais do Ohayo com detalhes sensíveis das notificações desativados por padrão">
    </td>
    <td width="58%">
      <img src="assets/readme/ohayo-response-history.png" alt="Histórico do Ohayo com resposta batch Codex expandida, arquivo de resposta salvo, Disparo Claude marcado como Iniciado e Disparo Contínuo pulado">
    </td>
  </tr>
  <tr>
    <td><strong>Notifique sem vazar contexto</strong><br>Cada Agendamento em background pode habilitar um alerta de sucesso. Respostas observadas e falhas agendadas também podem notificar; prompt, resposta, erro e detalhes da Conta ficam ocultos, a menos que os detalhes sensíveis sejam habilitados explicitamente em Geral.</td>
    <td><strong>Leia agora. Encontre depois.</strong><br>Prévias de respostas batch observadas ficam com o Disparo no Histórico e podem apontar para um arquivo Markdown ou texto com a saída capturada. Hand-offs interativos permanecem Iniciados.</td>
  </tr>
</table>

A permissão para notificações vem do macOS. O Ohayo pode notificar um sucesso
habilitado, uma resposta observada ou uma falha agendada. Essas notificações
são separadas de hooks do Claude ou notificações do Codex e não aumentam o que
o Ohayo consegue observar numa sessão interativa do Terminal.

O Histórico preserva Provedor, snapshot da Conta, modelo, origem, horário e o
resultado que o Ohayo realmente observou. Ele distingue Disparos concluídos
com sucesso, com falha, pulados, perdidos e iniciados em vez de apresentar todo
Disparo como trabalho concluído.

## Primeiros passos

1. Abra o Ohayo e conclua ou feche o guia inicial não bloqueante.
2. Em **Contas**, confirme as Contas Claude e Codex que deseja usar.
3. Em **Agendamentos**, escolha **Novo Agendamento…** e selecione o Provedor.
4. Configure controles de modelo, Skill, acesso ao projeto, execução e
   repetição em **Horários fixos** ou **Contínua** daquele Provedor.
5. Ative **Mostrar resposta** para um resultado batch observável, ou mantenha o
   Terminal para um hand-off interativo.
6. Em Disparos em background, ative notificações de sucesso quando forem úteis
   e inspecione cada Disparo no **Histórico**.

Imediatamente antes de um Disparo Claude/Codex, o Ohayo verifica a autenticação
da Conta selecionada. Se ela não estiver logada, nenhuma sessão do agente é
aberta; o Histórico registra o Disparo e mostra o comando de login para a
pasta daquela Conta.

## Também incluído

| Controle diário | Proteções operacionais |
| --- | --- |
| **Primeiro, a barra de menus** — Veja os próximos 1–5 Disparos e suas Contas sem manter um ícone no Dock. O ícone aparece somente enquanto uma janela padrão do Ohayo está aberta. | **Contas prontas** — Pause ou retome cada Conta de forma independente. O Provider Doctor somente leitura verifica instalação das CLIs e autenticação sem executar um prompt. |
| **Dois modos de repetição** — Combine horários com dias da semana em **Horários fixos** ou use um Agendamento **Contínuo** habilitado por Conta. | **Batch limitado** — Opcionalmente limite a execução em background a um número inteiro positivo de minutos. Sessões interativas no Terminal continuam sem supervisão. |
| **Controles nativos** — Escolha inglês ou português, inicie o Ohayo com o Mac e abra **Geral** pelo atalho padrão `⌘,`. | **Uma janela central** — Navegue entre Agendamentos, Contas, Histórico e Geral enquanto o painel compacto da barra de menus mantém o foco nos próximos Disparos. |

## Instalação

### Homebrew

```bash
brew tap hayashirafael/tap
brew trust --cask hayashirafael/tap/ohayo
brew install --cask ohayo
```

O Homebrew instala a release publicada mais recente. Instalações anteriores à
v1.2.0 precisam de um último `brew upgrade --cask ohayo`; releases desde a
v1.2.0 também podem atualizar em **Ohayo → Geral → Sobre → Buscar
atualizações…**.

### DMG

Baixe o `Ohayo-<versão>.dmg` da
[release mais recente](https://github.com/hayashirafael/ohayo/releases/latest),
abra-o e arraste o **Ohayo** para **Applications**.

As releases publicadas desde a v1.2.0 são universais para Apple Silicon e
Intel. Quando as credenciais Apple não estão disponíveis, releases para
testers usam assinatura ad-hoc sem notarização. O Gatekeeper pode exigir
aprovação manual na primeira abertura, e o macOS pode pedir acesso a pastas
protegidas novamente após uma atualização porque a identidade de código
ad-hoc não é estável. Com todas as credenciais Apple configuradas, o workflow
de release usa Developer ID, hardened runtime, notarização e stapling.

## Requisitos

- macOS 13+
- [Claude Code](https://claude.com/claude-code), instalado e logado somente
  para Agendamentos Claude
- [Codex CLI](https://github.com/openai/codex), instalado e logado somente para
  Agendamentos Codex
- Swift 5.9+ pelo Xcode ou Command Line Tools, somente para build a partir do
  código

## Permissões e privacidade

<details>
<summary><strong>Primeira abertura e permissões do macOS</strong></summary>

O app empacotado mostra uma vez um guia inicial não bloqueante. Ele faz verificações somente leitura da instalação das CLIs e da autenticação das Contas Claude/Codex configuradas. Essas verificações não executam prompt, iniciam login nem consomem cota do provedor intencionalmente.

O guia pode pedir acesso às notificações, testar a automação do Terminal para sessões interativas e, opcionalmente, habilitar **Iniciar com o Mac**. Fechá-lo não desativa o Ohayo. Reabra-o pelo painel ou em **Ohayo → Geral → Acesso ao Sistema → Permissões…**.

Se um acesso foi negado, altere-o em **Ajustes do Sistema → Notificações → Ohayo** ou **Ajustes do Sistema → Privacidade e Segurança → Automação**. Para um projeto protegido, como Documents, escolha **Permitir** no diálogo do macOS; o Ohayo não pode conceder essa permissão por você.

Um app assinado com Developer ID pode manter a mesma identidade de autorização entre atualizações. Um rebuild local ou para testers com assinatura ad-hoc tem outra identidade de código, então o macOS pode pedir novamente.

</details>

<details>
<summary><strong>Dados locais, skills e conteúdo sensível</strong></summary>

A detecção de Janelas de uso lê transcripts locais compatíveis do Claude/Codex e não chama uma API de provedor. Contas, Agendamentos, pastas favoritas e Histórico ficam armazenados localmente. O Sparkle e as CLIs dos provedores continuam usando seus próprios acessos de rede, portanto o Ohayo não é apresentado como produto totalmente offline.

Prompts batch são enviados por stdin, em vez de expostos na lista de argumentos do processo. As notificações do macOS escondem prompt, resposta, erro e detalhes da Conta por padrão.

Uma Skill selecionada pode ampliar o contexto, mas não concede acesso. O modo de acesso do Codex ou o fluxo de permissões do próprio Claude continua sendo a fonte da verdade para o filesystem.

</details>

## Atualizações

Releases desde a v1.2.0 consultam diariamente o feed assinado do Sparkle.
Quando há uma atualização, sua versão aparece no painel da barra de menus e em
**Geral → Sobre**, onde **Atualizar agora** abre o fluxo **Instalar e
reiniciar** do Sparkle. Use **Buscar atualizações…** para consultar
imediatamente.

O Sparkle valida os arquivos de release e o `appcast.xml` com sua chave EdDSA.
O acesso do Sparkle ao GitHub é separado da detecção passiva de Janelas de uso
locais. As credenciais Apple determinam se um build publicado pode usar
assinatura Developer ID e notarização.

## Limites técnicos

<details>
<summary><strong>Contas, identidade, filas e tentativas</strong></summary>

O Ohayo detecta `~/.claude` e `~/.codex` quando existem; outras Contas podem ser cadastradas com apelidos. A identidade do Provedor é persistida, e uma Conta customizada indisponível não é reinterpretada silenciosamente como outro Provedor nem como a Conta padrão.

Caminhos canônicos do filesystem são a identidade da Conta. Os Disparos entram numa fila FIFO por Provedor/Conta, enquanto Contas diferentes podem avançar em paralelo. Falta de CLI, autenticação, permissão ou configuração vira um estado que exige atenção em vez de um loop de alertas. Falhas transitórias conhecidas usam tentativas limitadas.

Somente uma instância do Ohayo executa por perfil de runtime. Produção e o perfil Dev isolado podem coexistir.

</details>

<details>
<summary><strong>Comportamento da CLI e das respostas</strong></summary>

O Claude nativo executa com `CLAUDE_CONFIG_DIR` removido; Contas Claude customizadas recebem seu override configurado. O Codex recebe o `CODEX_HOME` selecionado. Agendamentos shell não recebem nenhuma das variáveis de provedor.

Claude em background usa seu modo print não interativo. Codex em background usa `codex exec` com as configurações selecionadas de modelo, raciocínio e acesso. A captura do processo é limitada, preservando o começo e a cauda onde costuma estar o erro; por isso o Histórico é uma visão para diagnóstico, não um arquivo ilimitado de transcripts. Quando **Mostrar resposta** está ligado, o Ohayo mantém uma prévia formatada no Histórico e pode salvar atomicamente a saída capturada e limitada como Markdown ou texto simples.

</details>

## Build a partir do código

<details>
<summary><strong>App local no estilo produção e DMG</strong></summary>

```bash
git clone https://github.com/hayashirafael/ohayo.git
cd ohayo
swift test
./scripts/make-app.sh # build/Ohayo.app (assinado ad-hoc)
./scripts/make-dmg.sh # requer: brew install create-dmg
open build/Ohayo.app
```

O DMG é criado como `build/Ohayo-<versão>.dmg`.

</details>

<details>
<summary><strong>Canal isolado Ohayo Dev</strong></summary>

Use o bundle de desenvolvimento quando o app Ohayo instalado e seus dados precisam permanecer intocados:

```bash
./scripts/make-dev-app.sh
open "build/Ohayo Dev.app"
orca computer get-app-state --app io.github.hayashirafael.Ohayo.dev --json
```

Se o Computer Use não conseguir inspecionar diretamente a superfície da barra de menus, exponha a janela central nesse canal de desenvolvimento:

```bash
open "build/Ohayo Dev.app" --args --ui-testing
```

O `Ohayo Dev.app` usa o bundle ID `io.github.hayashirafael.Ohayo.dev`, sua própria pasta Application Support, domínio de preferências, workspace, pasta de respostas e lock de instância. Ele não copia Contas, Agendamentos, Histórico nem preferências de produção. Atualizações no app e Iniciar com o Mac ficam indisponíveis, e seu ícone azul tem um selo **DEV** visível.

</details>

---

O Ohayo é construído com Swift 5.9, SwiftUI `MenuBarExtra`, Swift Package
Manager e Sparkle.
