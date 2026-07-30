# Pesquisa de UI/UX para o Ohayo no macOS

Data da pesquisa: 29 de julho de 2026
Escopo: baseline pré-implementação obtido por análise estática do repositório + pesquisa em fontes primárias da Apple
Plataforma mínima observada: macOS 13 (`Package.swift:6`)

> Este documento preserva o diagnóstico que orientou a implementação. As
> seções “Evidência no baseline” descrevem o estado encontrado antes das
> mudanças de UI/UX realizadas em 29 de julho de 2026; elas não devem ser lidas
> como descrição do código atual. O status pós-implementação está resumido
> abaixo.
>
> **Decisão posterior de produto:** Geral voltou para a sidebar da janela
> central do Ohayo. Essa decisão substitui a recomendação histórica de manter
> Ajustes em uma janela separada; o restante do documento foi preservado como
> registro da pesquisa.

## Resultado executivo

O Ohayo não é apenas uma tela de preferências: é um **centro operacional de automações locais**. Ele configura Agendamentos de Claude, Codex e shell, acompanha Contas, detecta Janelas de uso, mostra o próximo Disparo e explica falhas. A interface deveria responder, em poucos segundos, a quatro perguntas:

1. Está tudo pronto?
2. O que vai acontecer em seguida?
3. Existe algo que exige minha ação?
4. O que aconteceu no último disparo?

O app já tem fundamentos bons: usa componentes nativos de SwiftUI, um `MenuBarExtra` com estilo de janela, estados distintos no histórico, notificações privadas por padrão, confirmação para exclusões e um primeiro uso não bloqueante. A maior oportunidade não é “embelezar cards”; é corrigir a **arquitetura de informação**:

- **Contas, Agendamentos e Histórico são conteúdo operacional**, não configurações.
- **Geral é configuração** e deve continuar em Ajustes.
- O painel da barra de menus deve priorizar próximo Disparo, saúde e ação corretiva.
- O formulário precisa usar controles que expressem corretamente suas escolhas e esconder detalhes avançados até serem necessários.
- A acessibilidade precisa ser tratada como critério verificável, sobretudo nos controles por ícone, linhas expansíveis e no glifo da barra.

## Status após implementação

| Frente | Status | Entregue no código atual | Validação ou trabalho restante |
|---|---|---|---|
| Janela central | Implementado | Janela “Ohayo” redimensionável com Agendamentos, Contas, Histórico e Geral; abertura e foco centralizados em `AppWindowActions` | Validar o app empacotado no macOS 13 e o retorno dos deep links |
| Painel da barra de menus | Implementado | Saúde, estados vazios acionáveis, próximo Disparo dominante, CLI ausente acionável e Sair no menu secundário | Percorrer em runtime todos os estados waiting, paused, unavailable, needs-attention e CLI ausente |
| Formulário de Agendamento | Implementado | `Picker` em radio group, editor multilinha, scroll, rodapé fixo e disclosure único de opções avançadas | Validar foco, Tab/Shift-Tab, Return, Escape, VoiceOver e persistência dos três modos de execução |
| Feedback e ações destrutivas | Implementado | Progresso/resultado de “Executar agora” e confirmação de remoção de Conta com impacto nos Agendamentos | Validar visualmente sucesso, Terminal aberto, falha e pluralização 0/1/N da confirmação |
| Histórico | Implementado | Busca, filtro por status, empty state distinto e identidade estável dos cards mesmo após busca, filtro ou inserção | Filtros por provedor/período e ações de cópia/diagnóstico permanecem melhorias opcionais |
| Acessibilidade | Parcial | Labels acessíveis no glifo, Contas, Agendamentos e horários; controles de expansão acionáveis por teclado; ícones decorativos ocultos | Executar Accessibility Inspector, VoiceOver, Full Keyboard Access, Increase Contrast e auditoria de áreas de toque |
| Permissões no contexto de uso | Parcial | Guia continua não bloqueante e ganhou CTA direto para Agendamentos | O pedido contextual na primeira necessidade de notificação/Terminal continua pendente |
| Terminologia | Implementado | READMEs e cópias visíveis foram alinhados a Agendamento, Comando, Repetição e Disparo | Nomes internos legados podem ser refatorados separadamente sem impacto no modelo mental da UI |

### Validação manual pendente

Além dos testes automatizados, uma cópia empacotada com bundle e preferências
isolados foi inspecionada em Dark Mode: guia inicial, janela central,
formulário, empty states de Agendamentos/Contas/Histórico, Geral e painel da
barra. Ainda é necessário validar manualmente:

- abrir Geral pelo painel no macOS 13;
- criar e editar Agendamentos Claude, Codex e shell nos três modos de execução;
- percorrer painel, janela operacional, formulário, Histórico, Contas e
  permissões com VoiceOver e Full Keyboard Access;
- conferir Light Mode, Dark Mode, Increase Contrast, textos longos e os
  tamanhos mínimo e ampliado da janela;
- confirmar que fechar o guia de permissões não bloqueia o app e que o CTA abre
  Agendamentos.

## Como o app foi entendido

### Proposta observada

O README descreve o Ohayo como um utilitário de barra de menus que mantém Janelas de uso de cinco horas prontas por Conta e também executa Agendamentos em horários fixos de Claude, Codex e shell (`README.md:5-16`, `README.md:18-46`). A proposta de valor combina:

- automação proativa;
- visibilidade de quando algo vai executar;
- múltiplas contas e provedores;
- segurança por preflight de autenticação;
- diagnóstico local;
- histórico com stdout/stderr;
- interação opcional no Terminal.

A interface observada no baseline se dividia assim:

- `MenuBarExtra` em estilo `.window` (`Sources/Ohayo/OhayoApp.swift:29-41`);
- uma janela intitulada Settings, com Contas, Agendamentos, Histórico e Geral em uma sidebar (`Sources/Ohayo/SettingsView.swift:3-45`);
- uma janela separada para permissões e Provider Doctor (`Sources/Ohayo/OhayoApp.swift:43-51`);
- um formulário modal único e denso para criar/editar Agendamentos (`Sources/Ohayo/AgendamentoFormSheet.swift:172-270`).

### Modelo mental recomendado

Usar estes termos de forma consistente:

- **Agendamento**: instrução configurada que combina um Comando, uma Conta e uma Repetição.
- **Comando**: conteúdo executado pelo Agendamento, seja um prompt de provedor ou um comando shell.
- **Repetição**: comportamento Contínuo ou em Horários Fixos do Agendamento.
- **Conta**: identidade local de Claude ou Codex à qual o Agendamento pode ser direcionado.
- **Disparo**: ocorrência rastreável de execução de um Agendamento, registrada no Histórico.
- **Janela de uso**: período de quota de uma Conta, confirmado por evidência válida do Provedor.

Assim, “Agendamentos” é a área principal e “Repetição” é uma seção dentro do Agendamento. Na UI em inglês, o par canônico é “Schedules” e “Runs”. Isso elimina a alternância histórica observada no README (`README.md:109-148`) sem introduzir dois nomes para o mesmo objeto.

## O que já está alinhado com a Apple

1. **Menu-bar utility é uma escolha adequada.** A Apple define `MenuBarExtra` como uma cena persistente para funcionalidade usada mesmo quando o app não está ativo e recomenda o estilo `window` para conteúdo mais complexo ou rico em dados. O uso atual está coerente com essa finalidade. Fonte: [MenuBarExtra — SwiftUI](https://developer.apple.com/documentation/swiftui/menubarextra).

2. **O onboarding é dispensável e não bloqueia o app.** O guia pode ser fechado com “Configurar depois”, enquanto as verificações do Provider Doctor são somente leitura (`Sources/Ohayo/PermissionSetupView.swift:21-64`). A Apple recomenda onboarding rápido, opcional e interativo. Fonte: [Onboarding — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/onboarding).

3. **As permissões não são disparadas silenciosamente.** A tela explica notificações e automação antes de cada ação explícita (`Sources/Ohayo/PermissionSetupView.swift:33-46`). A Apple recomenda pedir acesso no contexto em que o benefício é compreensível. Fontes: [Privacy — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/privacy), [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications).

4. **Privacidade de notificações parte de um padrão seguro.** O README informa que detalhes sensíveis ficam ocultos por padrão (`README.md:38-40`). A HIG orienta evitar informação sensível, pessoal ou confidencial em notificações. Fonte: [Notifications — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/notifications).

5. **Histórico já combina texto, símbolo e cor.** Os estados Success, Launched, Failure, Skipped e Missed têm rótulos e símbolos próprios, não apenas cores (`Sources/Ohayo/HistoryTab.swift:85-139`). Isso segue a orientação de não depender exclusivamente de cor. Fonte: [Color — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/color).

6. **Ações destrutivas centrais já pedem confirmação.** Excluir um Agendamento e limpar o Histórico têm confirmação explícita (`Sources/Ohayo/HorariosView.swift:40-50`, `Sources/Ohayo/HistoryTab.swift:13-23`). A HIG recomenda alerta para uma ação destrutiva incomum que não pode ser desfeita. Fonte: [Alerts — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/alerts).

## Backlog priorizado

| Prioridade | Mudança | Impacto esperado |
|---|---|---|
| P0 | Separar centro operacional de Ajustes | Corrige a arquitetura de informação e reduz a sensação de “configurar para usar” |
| P0 | Tornar estados do painel acionáveis | Faz o menu-bar cumprir sua função de diagnóstico e próxima ação |
| P0 | Trocar checkboxes mutuamente exclusivos por um Picker | Elimina uma semântica de controle incorreta no formulário |
| P0 | Fechar lacunas de acessibilidade e navegação por teclado | Torna os fluxos essenciais operáveis sem depender de mouse, cor ou tooltip |
| P1 | Simplificar e tornar o formulário progressivo | Diminui carga cognitiva sem remover recursos avançados |
| P1 | Mostrar feedback local para “Executar agora” e diagnósticos | Evita aparência de travamento e ida obrigatória ao Histórico |
| P1 | Proteger remoção de conta e explicar impacto | Evita desativação acidental de Agendamentos |
| P1 | Refinar onboarding e notificações pelo momento de uso | Melhora compreensão e taxa de concessão sem pressionar no primeiro launch |
| P1 | Tornar Histórico mais investigável | Acelera diagnóstico de falhas reais |
| P2 | Padronizar microcopy, reticências, atalhos e estado de janela | Faz o app parecer mais nativo e previsível |
| P2 | Uniformizar empty states e adaptação visual | Melhora consistência e manutenção |

---

## P0. Separar o centro operacional de Ajustes

### Evidência no baseline

`SettingsView` lista Contas, Agendamentos, Histórico e Geral como quatro áreas equivalentes e a janela se chama Settings (`Sources/Ohayo/SettingsView.swift:3-45`). As três primeiras são usadas repetidamente para operar o produto; apenas Geral contém preferências infrequentes (`Sources/Ohayo/GeneralTab.swift:9-53`).

### Base oficial

A Apple orienta:

- usar Settings para opções gerais e infrequentemente alteradas;
- manter opções específicas de um Agendamento no contexto do próprio Agendamento;
- minimizar a quantidade de preferências;
- expor Settings pelo item padrão do app e por Command-Comma.

Fontes: [Settings — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/settings), [Settings — SwiftUI](https://developer.apple.com/documentation/swiftui/settings).

### Mudança recomendada

Criar dois destinos:

1. **Janela principal “Ohayo”**
   - Agendamentos
   - Contas
   - Histórico
   - sidebar persistente;
   - redimensionável;
   - restaura a última seção e o filtro relevante.

2. **Ajustes**
   - Iniciar no login
   - Mostrar tempo restante na barra
   - Privacidade das notificações
   - Quantidade de próximos Disparos no painel
   - Idioma
   - Permissões
   - Versão

Preferir uma cena `Settings` para a segunda janela; o SwiftUI então gerencia o item Settings e seu atalho equivalente. Para a janela operacional, remover a restrição global `.windowResizability(.contentSize)` e definir apenas um tamanho mínimo. No comportamento automático, `Window` usa uma estratégia com tamanho mínimo, enquanto `Settings` usa tamanho derivado do conteúdo. Fontes: [WindowResizability](https://developer.apple.com/documentation/swiftui/windowresizability), [automatic — WindowResizability](https://developer.apple.com/documentation/swiftui/windowresizability/automatic).

### Critério de aceite

- “Settings” não contém Agendamentos, Contas ou Histórico.
- Abrir um Agendamento no painel leva à janela “Ohayo”, não a “Settings”.
- Command-Comma abre apenas preferências gerais.
- A janela operacional pode ser redimensionada e continua utilizável no mínimo definido.
- A última área visitada volta selecionada quando a janela reabre.

## P0. Transformar o painel da barra em status + próxima ação

### Evidência no baseline

O painel já mostra os próximos Disparos, mas estados vazios são apenas uma linha de texto (`Sources/Ohayo/MenuPanel.swift:78-109`). “CLI ausente” ocupa o título do cabeçalho e o botão mais destacado nesse cabeçalho é um ícone de energia que encerra o app (`Sources/Ohayo/MenuPanel.swift:46-74`). Não há ação direta para corrigir “sem Agendamentos”, “tudo pausado”, “quota indisponível”, “requer atenção” ou “aguardando janela”.

### Base oficial

Um `MenuBarExtra` serve para acesso persistente à funcionalidade comum; o estilo de janela aceita controles e conteúdo rico. A Apple também orienta hierarquia clara, feedback explícito e itens importantes primeiro. Fontes: [MenuBarExtra — SwiftUI](https://developer.apple.com/documentation/swiftui/menubarextra), [Design principles — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/design-principles), [Layout — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/layout).

### Mudança recomendada

Organizar o painel em três blocos:

1. **Saúde**
   - “Tudo pronto” ou “Ação necessária”;
   - um resumo curto;
   - botão contextual “Revisar”.

2. **Próximo disparo**
   - Agendamento;
   - conta/provedor;
   - horário absoluto e relativo;
   - estado: agendada, aguardando evidência, retry, cooldown ou pausada.

3. **Navegação**
   - Abrir Ohayo;
   - Histórico;
   - Ajustes…

Cada empty state deve ter título, explicação e uma ação segura:

| Estado | Título sugerido | Ação |
|---|---|---|
| nenhum Agendamento | Nenhum Agendamento | Novo Agendamento… |
| todas as contas pausadas | Todas as contas estão pausadas | Revisar Contas |
| aguardando janela | Aguardando atividade do provedor | Ver Agendamento |
| quota/detecção indisponível | Não foi possível confirmar a janela | Ver detalhes |
| precisa de atenção | Um Agendamento precisa de você | Revisar problema |
| CLI ausente | Claude/Codex CLI não encontrado | Abrir Diagnóstico |

Não oferecer bootstrap que consome quota como um botão primário sem confirmação; levar a pessoa ao contexto do Agendamento.

Mover “Quit Ohayo” para uma ação secundária claramente rotulada. Um ícone de energia pode sugerir desligamento do sistema, enquanto a HIG pede que o conteúdo do botão comunique seu propósito e recomenda texto quando ele for mais claro que um símbolo. Fonte: [Buttons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/buttons).

### Critério de aceite

- Todo estado sem próximo Disparo oferece uma explicação específica e um caminho de resolução.
- “Ação necessária” nunca é comunicada apenas por cor ou `!`.
- O próximo disparo continua sendo a informação visualmente dominante quando não há problema.
- Encerrar o app não é a ação mais proeminente do painel.

## P0. Corrigir o controle de modo de saída

### Evidência no baseline

O formulário modela `OutputMode` como um único valor (`none`, `terminal`, `response`), mas apresenta três `Toggle` com estilo checkbox (`Sources/Ohayo/AgendamentoFormSheet.swift:8-24`, `Sources/Ohayo/AgendamentoFormSheet.swift:198-218`). Eles são mutuamente exclusivos por código, embora visualmente pareçam três opções independentes.

### Base oficial

A HIG define checkbox como estado binário e recomenda radio buttons para mais de duas opções mutuamente exclusivas. O SwiftUI fornece `Picker` com estilo `radioGroup` para duas a cinco opções. Fontes: [Toggles — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/toggles), [radioGroup — SwiftUI](https://developer.apple.com/documentation/swiftui/pickerstyle/radiogroup).

### Mudança recomendada

Substituir os três checkboxes por um único `Picker`, com rótulo que revele a dimensão da escolha. Exemplo:

**Modo do disparo**

- Terminal interativo
- Em segundo plano, mostrar resposta
- Em segundo plano, sem mostrar resposta

Exibir timeout apenas nos dois modos em segundo plano. Manter “Notificar ao concluir com sucesso” como checkbox independente, porque ele é de fato uma opção binária.

### Critério de aceite

- Só uma opção pode estar selecionada e a aparência deixa isso óbvio.
- VoiceOver anuncia o nome do grupo, cada opção e o valor selecionado.
- Alterar o provedor não deixa uma opção inválida selecionada.

## P0. Acessibilidade como gate de entrega

### Riscos encontrados por inspeção estática

Esta lista indica riscos a validar em runtime, não resultados de um audit executado:

- o glifo customizado da barra não define label/value acessível com o estado completo (`Sources/Ohayo/MenuBarLabel.swift:10-35`);
- a linha de Agendamento expande por `onTapGesture`, sem semântica explícita de botão/disclosure (`Sources/Ohayo/HorariosView.swift:233-247`);
- o toggle de Agendamento usa label vazio e depois esconde labels (`Sources/Ohayo/HorariosView.swift:250-264`);
- Pausar, Editar e Remover conta dependem de símbolos; alguns têm tooltip, mas não há rótulo acessível explícito localizado (`Sources/Ohayo/ContasView.swift:82-126`);
- vários elementos compactos truncam texto essencial em uma janela de largura fixa.

SwiftUI fornece acessibilidade básica para controles padrão, mas a própria Apple recomenda complementar interfaces customizadas com `accessibilityLabel`, `accessibilityValue` e `accessibilityHint`, e testar com VoiceOver e tecnologias assistivas. Fontes: [Accessibility fundamentals — SwiftUI](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals), [Accessible descriptions — SwiftUI](https://developer.apple.com/documentation/swiftui/accessible-descriptions).

### Mudança recomendada

- Glifo da barra:
  - label: “Ohayo”;
  - value dinâmico: “Tudo pronto”, “Ação necessária”, “Todas as contas pausadas” ou “Próxima janela termina em …”;
  - um único elemento acessível, evitando leitura fragmentada do ícone e contador.
- Linhas de Agendamento:
  - usar semântica de disclosure/botão;
  - anunciar expandido/recolhido;
  - dar ao toggle um label como “Ativar Agendamento X”.
- Contas:
  - labels localizados “Pausar conta X”, “Retomar conta X”, “Editar apelido de X” e “Remover conta X”;
  - esconder ícones decorativos do VoiceOver quando o texto adjacente já comunica o provedor.
- Estados:
  - manter símbolo + texto + cor;
  - usar cores semânticas do sistema;
  - verificar Dark Mode e Increase Contrast.
- Teclado:
  - Tab/Shift-Tab percorrem todos os controles;
  - Espaço ativa toggles;
  - Return salva quando válido;
  - Escape cancela sheets e diálogos;
  - foco volta ao elemento que abriu o sheet.

A Apple recomenda Full Keyboard Access, respeito aos atalhos padrão e teste de cada tela. Fontes: [Keyboards — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/keyboards), [Accessibility — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/accessibility).

### Gate verificável

Rodar Accessibility Inspector no mínimo nestes estados:

1. painel com próximo Disparo;
2. painel sem Agendamentos;
3. painel com ação necessária;
4. lista de Agendamentos;
5. formulário novo e formulário inválido;
6. contas;
7. histórico vazio, sucesso e falha;
8. Geral;
9. primeiro uso/permissões.

O audit deve cobrir descrição de elementos, contraste, região de interação, detecção, hierarquia pai/filho e ações. A Apple ressalta que o audit automatizado é apenas o começo e deve ser complementado com VoiceOver. Fonte: [Performing accessibility audits for your app](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app).

---

## P1. Simplificar o formulário com progressive disclosure

### Evidência no baseline

O sheet mostra, em uma coluna de 420 pontos, tipo, nome, prompt, conta, modelo, esforço, safe mode, skill, diretório, três modos de saída, timeout, notificação, repetição, horas, dias, bootstrap e enabled (`Sources/Ohayo/AgendamentoFormSheet.swift:172-270`). O prompt usa `TextField`, mesmo podendo conter uma instrução extensa (`Sources/Ohayo/AgendamentoFormSheet.swift:178-180`).

### Base oficial

A Apple recomenda:

- manter as opções mais usadas no topo e esconder detalhes avançados até serem relevantes;
- não usar mais de uma hierarquia de disclosure confusa;
- usar text field para pequenas entradas e text view para conteúdo maior;
- agrupar controles relacionados e alinhar elementos para facilitar leitura.

Fontes: [Disclosure controls — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls), [Text fields — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/text-fields), [Layout — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/layout).

### Mudança recomendada

Estrutura sugerida:

1. **Essencial, sempre visível**
   - Nome
   - Tipo
   - Conta
   - Prompt/comando em `TextEditor`
   - Repetição
   - Horário/dias ou estado contínuo

2. **Disparo**
   - Picker de modo do disparo
   - Notificação de sucesso

3. **Opções avançadas**, um único disclosure
   - modelo;
   - esforço/reasoning;
   - safe mode;
   - skill;
   - diretório de trabalho;
   - timeout.

Usar `Form`/seções nativas, permitir scroll e uma largura que acomode labels sem truncamento. Mostrar validação inline junto ao campo, não somente por um botão Save desabilitado com tooltip (`Sources/Ohayo/AgendamentoFormSheet.swift:258-265`).

### Critério de aceite

- Um Agendamento padrão pode ser criado vendo apenas o conjunto essencial.
- O prompt aceita várias linhas e continua legível durante a edição.
- Toda invalidez tem uma explicação visível e acessível.
- Opções avançadas permanecem disponíveis sem dominar o fluxo.

## P1. Feedback imediato para operações assíncronas

### Evidência no baseline

“Executar agora” desabilita o botão durante o trabalho e só mostra o resultado posteriormente no Histórico (`Sources/Ohayo/HorariosView.swift:307-340`). O Provider Doctor já usa um pequeno `ProgressView` ao verificar o CLI (`Sources/Ohayo/ProviderDoctor.swift:306-313`), que pode servir como padrão interno.

### Base oficial

A Apple recomenda mostrar algo rapidamente, deixar o restante do app utilizável e usar indicador de progresso quando uma operação leva mais que um ou dois instantes. Para duração desconhecida, um indicador indeterminado é apropriado. Fontes: [Loading — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/loading), [Progress indicators — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/progress-indicators).

### Mudança recomendada

- Alterar a ação para “Executando…” com spinner enquanto estiver em voo.
- Ao finalizar, mostrar brevemente:
  - “Terminal aberto”;
  - “Concluída”;
  - “Falhou — Ver detalhes”.
- Manter a navegação e os outros Agendamentos utilizáveis.
- Em falha, oferecer link direto para o Disparo recém-criado no Histórico.

## P1. Proteger a remoção de conta

### Evidência no baseline

O botão de remover conta executa imediatamente (`Sources/Ohayo/ContasView.swift:119-125`). A operação não apaga a pasta, mas limpa alias e desativa todos os Agendamentos que apontam para a Conta (`Sources/Ohayo/AppState.swift:548-563`), portanto seu impacto é maior que o ícone sugere.

### Base oficial

A HIG recomenda confirmação para ações destrutivas incomuns e sem undo, com título específico, consequência clara e Cancel seguro. Fonte: [Alerts — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/alerts).

### Mudança recomendada

Antes de remover:

- “Remover conta ‘X’ do Ohayo?”
- “A pasta não será apagada. N Agendamentos serão desativados.”
- Cancelar
- Remover Conta

Como alternativa superior, implementar undo real e então reduzir a interrupção modal, conforme a orientação de tornar ações reversíveis. Fonte: [Undo and redo — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo).

## P1. Refinar permissões e notificações pelo momento de uso

### Evidência no baseline

O guia reúne Provider Doctor, notificações, automação do Terminal e Launch at Login de uma vez (`Sources/Ohayo/PermissionSetupView.swift:21-64`). A ação é explícita, o que já é melhor que pedir permissões automaticamente.

### Base oficial

A Apple recomenda:

- onboarding rápido e opcional;
- adiar setup não essencial;
- pedir acesso quando a pessoa usa a função dependente;
- pedir notificações em um contexto que mostre sua utilidade;
- consultar novamente os settings, pois a autorização pode mudar.

Fontes: [Onboarding — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/onboarding), [Asking permission to use notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications).

### Mudança recomendada

- Manter o Provider Doctor somente leitura no primeiro uso.
- Não abrir o alerta do sistema de notificações automaticamente.
- Pedir notificações quando a pessoa habilitar “Notificar em caso de falha” ou criar seu primeiro Agendamento com notificação.
- Testar automação do Terminal quando a pessoa selecionar “Terminal interativo” pela primeira vez, mantendo o atalho no guia.
- Exibir status atual e ação adequada:
  - Não solicitado → Permitir;
  - Permitido → Concluído;
  - Negado → Abrir Ajustes do Sistema;
  - Indisponível → explicação não acionável.
- Manter detalhes sensíveis desligados por padrão e separar “receber notificação” de “mostrar conteúdo sensível”.

## P1. Tornar o Histórico uma ferramenta de diagnóstico

### Evidência no baseline

Os cards mostram conta, provedor, modelo, origem, comando, resultado e resposta selecionável (`Sources/Ohayo/HistoryTab.swift:85-139`). Há filtro por conta vindo de deep link, mas não busca ou filtros por status/provedor.

### Base oficial

A Apple observa que listas/tabelas podem representar dados complexos e que apps de produtividade podem usar colunas separadas e ordenáveis. Textos úteis como erro e localização devem ser selecionáveis. Fontes: [Lists and tables — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables), [Labels — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/labels).

### Mudança recomendada

- Busca por Agendamento, Conta, Comando, erro e resposta.
- Filtros por status, provedor e período.
- Em falha de autenticação: “Copiar comando de login” e “Abrir Diagnóstico”.
- Em outra falha: “Copiar detalhes”.
- “Executar novamente” somente quando a consequência estiver clara.
- Preservar a resposta expandível; para maior densidade, avaliar list/detail em vez de empilhar todos os detalhes.
- Usar empty state diferente para:
  - histórico realmente vazio;
  - filtro sem resultado.

---

## P2. Ajustes de consistência nativa

### Reticências

A Apple orienta reticências quando uma ação abre outra janela/view e ainda exige entrada. No baseline, “Settings” e “New schedule” abriam outros contextos sem reticências, enquanto “Permissions…” já usava o padrão (`Sources/Ohayo/Localization.swift:39`, `Sources/Ohayo/Localization.swift:143`, `Sources/Ohayo/Localization.swift:240`). Padronizar:

- Novo Agendamento…
- Adicionar Conta…
- Ajustes…
- Permissões…

Fonte: [Buttons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/buttons).

### Atalhos

Quando a janela estiver ativa, oferecer os atalhos esperados sem reaproveitar combinações padrão:

- Command-Comma: Ajustes
- Command-N: Novo Agendamento
- Command-F: buscar na área atual
- Command-W: fechar janela
- Escape: cancelar
- Return: ação padrão válida

No baseline, o sheet já usava os atalhos semânticos de cancel/default (`Sources/Ohayo/AgendamentoFormSheet.swift:258-264`). Fonte: [Keyboards — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/keyboards).

### Empty states consistentes

O SwiftUI oferece `ContentUnavailableView` para lista vazia, busca sem resultado e erro. Como o projeto suporta macOS 13, usar:

- um componente próprio equivalente no macOS 13;
- `ContentUnavailableView` sob availability em versões compatíveis;
- mesma anatomia: símbolo, título, descrição e ação.

Fonte: [ContentUnavailableView — SwiftUI](https://developer.apple.com/documentation/swiftui/contentunavailableview).

### Cores e contraste

Continuar preferindo cores semânticas do sistema, validar Light/Dark/Increase Contrast e nunca retirar os rótulos/símbolos dos estados. Fonte: [Color — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/color).

### Restauração

Restaurar seção, filtro e seleção da janela operacional com estado leve por cena, sem persistir dados sensíveis nesse mecanismo. Fonte: [SceneStorage — SwiftUI](https://developer.apple.com/documentation/swiftui/scenestorage).

## Arquitetura de navegação sugerida

```text
Barra de menus
├── Saúde / ação necessária
├── Próximo disparo
├── Próximos disparos
└── Abrir Ohayo | Histórico | Ajustes…

Janela Ohayo
├── Agendamentos
│   ├── lista, filtros e busca
│   └── criar/editar Agendamento
├── Contas
└── Histórico

Ajustes
├── Inicialização e barra de menus
├── Notificações e privacidade
├── Aparência/idioma
├── Permissões
└── Sobre/versão
```

## Ordem de implementação recomendada

### Entrega 1 — Estrutura

1. Renomear a janela atual para Ohayo.
2. Manter apenas Agendamentos, Contas e Histórico nela.
3. Criar uma cena Settings para Geral.
4. Tornar a janela operacional redimensionável.
5. Atualizar deep links do painel.

### Entrega 2 — Clareza de estado

1. Refazer estados do painel com CTA.
2. Rebaixar Quit para ação secundária.
3. Exibir progresso/resultado de “Executar agora”.
4. Diferenciar claramente waiting, paused, unavailable e needs attention.

### Entrega 3 — Formulário

1. Trocar os três checkboxes por Picker/radio group.
2. Usar editor multilinha para prompt/comando.
3. Adotar seções e um disclosure de opções avançadas.
4. Mostrar validação inline.
5. Garantir scroll e tamanho adaptável.

### Entrega 4 — Acessibilidade

1. Labels/values/hints explícitos.
2. Semântica correta para linhas expansíveis e toggles.
3. Navegação integral por teclado.
4. Audit em todos os estados listados.
5. Teste manual com VoiceOver e Increase Contrast.

### Entrega 5 — Diagnóstico e acabamento

1. Confirmação de remoção de conta com impacto.
2. Busca/filtros/ações do Histórico.
3. Permissões no contexto da primeira necessidade.
4. Microcopy, reticências e atalhos.
5. Empty states compartilhados.

## Checklist de validação final

### Fluxos

- Criar Agendamento em horários fixos de Claude.
- Criar Agendamento contínuo de Codex.
- Criar shell em background.
- Editar sem perder skill/conta.
- Executar agora e acompanhar estado.
- Pausar/retomar conta.
- Remover Conta com Agendamentos associados.
- Corrigir CLI/autenticação ausente.
- Investigar uma falha no histórico.

### Variações visuais

- Light Mode.
- Dark Mode.
- Increase Contrast.
- janela no tamanho mínimo e maior.
- nomes de Conta/Agendamento longos.
- português e inglês.

### Acessibilidade

- VoiceOver no painel e em cada seção.
- Full Keyboard Access.
- nenhum controle por ícone sem nome acionável.
- nenhuma informação essencial apenas por cor.
- foco previsível ao abrir/fechar sheet e diálogo.
- audit do Accessibility Inspector sem problemas não justificados.

## Fontes primárias consultadas

Todas as fontes externas abaixo são da Apple e foram consultadas em 29 de julho de 2026:

- [Designing for macOS — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Design principles — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/design-principles)
- [Settings — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/settings)
- [Settings — SwiftUI](https://developer.apple.com/documentation/swiftui/settings)
- [MenuBarExtra — SwiftUI](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Layout — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/layout)
- [Buttons — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/buttons)
- [Toggles — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/toggles)
- [radioGroup — SwiftUI](https://developer.apple.com/documentation/swiftui/pickerstyle/radiogroup)
- [Disclosure controls — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/disclosure-controls)
- [Text fields — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/text-fields)
- [ContentUnavailableView — SwiftUI](https://developer.apple.com/documentation/swiftui/contentunavailableview)
- [Loading — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/loading)
- [Progress indicators — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)
- [Alerts — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/alerts)
- [Undo and redo — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/undo-and-redo)
- [Onboarding — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/onboarding)
- [Privacy — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/privacy)
- [Notifications — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/notifications)
- [Asking permission to use notifications — User Notifications](https://developer.apple.com/documentation/usernotifications/asking-permission-to-use-notifications)
- [Accessibility — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- [Accessibility fundamentals — SwiftUI](https://developer.apple.com/documentation/swiftui/accessibility-fundamentals)
- [Accessible descriptions — SwiftUI](https://developer.apple.com/documentation/swiftui/accessible-descriptions)
- [Performing accessibility audits for your app](https://developer.apple.com/documentation/accessibility/performing-accessibility-audits-for-your-app)
- [Keyboards — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/keyboards)
- [Color — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/color)
- [Lists and tables — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)
- [Labels — Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/labels)
- [WindowResizability — SwiftUI](https://developer.apple.com/documentation/swiftui/windowresizability)
- [SceneStorage — SwiftUI](https://developer.apple.com/documentation/swiftui/scenestorage)

## Limites desta análise

- A pesquisa avaliou a UI pelo snapshot de implementação e documentação do
  baseline; a matriz pós-implementação foi conferida estaticamente e não
  substitui teste com usuários.
- Os riscos de acessibilidade são inferências estáticas e precisam ser confirmados no app empacotado com Accessibility Inspector e VoiceOver.
- `ContentUnavailableView` precisa de fallback/availability porque o projeto mantém macOS 13.
- Não foi proposta uma reescrita visual proprietária: a direção favorece controles e comportamentos nativos para preservar compatibilidade com diferentes versões do macOS.
