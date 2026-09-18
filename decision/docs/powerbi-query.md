# Consulta consolidada do Power BI — Decision

Documentação da fonte de dados usada no painel de FAIA e FARC da Decision.

Escrita para quem vai **usar** o painel, não para quem escreveu o SQL. A regra de
cálculo de cada indicador está em [faia-farc-calculation.md](faia-farc-calculation.md).

---

## Índice

1. [Finalidade](#1-finalidade)
2. [Consulta de referência](#2-consulta-de-referência)
3. [Como usar no Power BI](#3-como-usar-no-power-bi)
4. [Power BI e SQL Server](#4-power-bi-e-sql-server)
5. [Período da consulta](#5-período-da-consulta)
6. [Saída](#6-saída)
7. [Diferença para a consulta manual](#7-diferença-para-a-consulta-manual)
8. [`Data de Encerramento Decision`](#8-data-de-encerramento-decision)
9. [Desempenho](#9-desempenho)
10. [Conferência](#10-conferência)
11. [Cuidados](#11-cuidados)
12. [Limitações](#12-limitações)
13. [Manutenção no Power Query](#13-manutenção-no-power-query)

Há uma versão desta documentação em HTML, para exibir dentro do painel no visual
**HTML Content**: `docs/powerbi/documentacao-powerbi-decision.html`. Ela deriva
deste arquivo; se os dois divergirem, **vale este**.

---

## 1. Finalidade

A consulta reúne, em **uma linha por chamado**:

```text
dados do chamado
resultado do FAIA
resultado do FARC
```

Ela devolve **um único resultado**, com **29 colunas**. Não traz tabelas de
diagnóstico nem resultados intermediários.

Arquivo:

```text
decision/powerbi/consulta_faia_farc_power_bi.sql
```

---

## 2. Consulta de referência

A **referência funcional** continua sendo a consulta manual:

```text
decision/queries/consulta_faia_farc.sql
```

A versão do Power BI **não reimplementa** nenhum cálculo. O motor — FAIA, FARC,
motores de rotina e de status, suspensões, calendário, feriados, terminais,
posse/reposse — é o mesmo. O que muda é o período e o formato de saída
(ver [seção 7](#7-diferença-para-a-consulta-manual)).

Quando houver dúvida sobre **como** um número é calculado, a resposta está na
consulta manual e em [faia-farc-calculation.md](faia-farc-calculation.md).

### De onde vêm os dados

| Tabela | Papel |
|---|---|
| `dbo.call_req` | O chamado: tipo, severidade, status, categoria, abertura, fechamento |
| `dbo.act_log` | O histórico de eventos: mudanças de status, transferências de grupo, solução, envio de pesquisa. É daqui que saem quase todos os marcos de tempo |
| `dbo.ca_contact` | Nomes de pessoas e grupos |
| `dbo.cr_stat`, `dbo.pri`, `dbo.prob_ctg` | Dicionários de status, severidade e categoria |
| `dbo.grpmem` | Composição dos grupos |
| `dbo.audit_log`, `dbo.View_Audit_Group` | Histórico de grupo, **quando existirem** na instalação. São opcionais: a consulta testa a existência antes de usar |

Todo o processamento intermediário acontece em **tabelas temporárias** com
sufixo `_DEC`. Nada é gravado em tabela permanente — a consulta é **somente
leitura**.

---

## 3. Como usar no Power BI

1. **Obter dados → SQL Server.**
2. Informe o servidor e o banco de dados **`mdb`**.
3. Escolha o modo **Importação**.
4. Abra **Opções avançadas** e cole o conteúdo inteiro de
   `consulta_faia_farc_power_bi.sql` no campo **Instrução SQL**.
5. Deixe **"Adicionar colunas de relação" desmarcado**.
6. Carregue e, na primeira vez, confira a quantidade de chamados
   (ver [seção 10](#10-conferência)).
7. Nas próximas vezes, basta **Atualizar**: o período se ajusta sozinho
   (ver [seção 5](#5-período-da-consulta)).
8. Na primeira atualização depois de qualquer mudança no texto SQL, o Power BI
   pede para **aprovar a execução da consulta nativa**. Isso é esperado.

Não é preciso ajustar datas a cada mês. Não é preciso rodar nenhum script antes.

---

## 4. Power BI e SQL Server

### Quem executa a consulta

O arquivo é **T-SQL puro**. Não é Power Query M, não é DAX.

```text
A consulta é usada pelo Power BI, mas é executada pelo SQL Server.
O Power BI envia o script pelo conector e importa o resultado.
```

O Power BI **não calcula nada**: abre a conexão, manda o texto do script, espera
e recebe o result set final. Em condições equivalentes, o mesmo script roda
integralmente no SSMS.

### O banco precisa ser o `mdb`

Todas as referências a tabelas são de **duas partes** (`dbo.call_req`,
`dbo.act_log`, …), e nomes de duas partes se resolvem no **banco atual da
sessão**. Por isso o script começa com `USE mdb;` — assim ele não depende do
cliente. No Power BI a instrução é inofensiva, porque a conexão já aponta para o
`mdb`.

Fora do `mdb`, o lote inteiro falharia na compilação com
`Msg 208 — Invalid object name`, e **nada** seria devolvido.

### Como rodar no SSMS

1. Conecte no mesmo servidor usado pelo Power BI.
2. Confirme `mdb` na caixa de banco de dados.
3. Abra o arquivo **inteiro** e execute **sem selecionar trecho**. Executar só um
   pedaço quebra a consulta: as temporárias dos blocos anteriores não existiriam.
4. Basta permissão de leitura nas tabelas acima e de criar temporária em
   `tempdb`.
5. Não é preciso sessão limpa: as temporárias têm sufixo `_DEC` e cada bloco
   começa com `IF OBJECT_ID(...) DROP TABLE`.

### Se der erro no SSMS

| Erro | Causa provável | O que fazer |
|---|---|---|
| `Msg 208 — Invalid object name 'dbo.call_req'` | Sessão em outro banco | Selecionar `mdb`; conferir se o `USE mdb;` foi colado junto |
| `Msg 207 — Invalid column name` | Temporária antiga de outra versão do script ainda viva na sessão | Abrir sessão nova e repetir; se persistir, é defeito do arquivo |
| `Msg 1088 / objeto #... não existe` | Foi executado só um trecho selecionado | Executar o arquivo inteiro |
| Demora muito | Volume ou bloqueio | Ver [seção 9](#9-desempenho) |

Ao relatar um problema, informe **cliente**, **banco atual**, **usuário**,
**mensagem completa com o número da linha** e se o arquivo foi executado inteiro.

---

## 5. Período da consulta

O período é **automático**. Não há data para editar a cada mês.

- A consulta devolve os chamados **encerrados nos últimos 12 meses até hoje**.
- A cobertura é controlada por um único número, `@CoberturaMeses`, que é a
  **primeira instrução** do SQL. O padrão é `12`.
- As datas são interpretadas no **horário do Brasil (GMT-3)**. O SDM grava em
  UTC; a consulta converte.
- Não há data fixa no código: tudo deriva do relógio do servidor no momento da
  atualização.

### Limites exatos

```text
início  INCLUSIVO   hoje menos @CoberturaMeses meses, às 00:00:00
fim     EXCLUSIVO   AMANHÃ às 00:00:00
```

O intervalo é **semiaberto** — `>= início` e `< fim`. O fim é **amanhã**, e não
hoje, porque o filtro é por instante de fechamento: com o fim em "hoje 00:00" o
dia corrente ficaria inteiro de fora, e com "hoje 23:59:59" perder-se-ia o último
segundo. Assim **tudo que fechou hoje entra**, sem duplicar a borda.

**Exemplo, atualizando em 18/09/2026:**

```text
janela = 18/09/2025 00:00:00  até  19/09/2026 00:00:00 (exclusivo)
       = chamados encerrados de 18/09/2025 até 18/09/2026, inclusive
```

No dia seguinte a janela anda um dia, sozinha.

### O que o período faz e o que não faz

**O filtro usa a data de fechamento do chamado** (`close_date`): entra no
resultado todo chamado que **fechou** dentro da janela.

> O período **seleciona quais chamados entram**. Ele **não corta** os tempos
> calculados.

Se um chamado fechou dentro da janela mas foi aberto antes dela, o FAIA e o FARC
são calculados sobre a vida inteira do chamado.

**Meses de borda.** A janela começa no mesmo dia do mês em que se atualiza. Ao
agrupar o painel por mês, o **primeiro** mês aparece parcial (do dia de início
em diante) e o **mês corrente** também, porque ainda não terminou. Não é defeito.

### Não existe ciclo 24-24 na Decision

Até 18/09/2026 esta consulta devolvia os "seis últimos ciclos completos", com
ciclo do dia 24 ao dia 23. **Essa é a regra de faturamento da A2B/Protect4**, e
entrou aqui quando o modelo de janela daquele núcleo foi reaproveitado. A
Decision não tem ciclo 24-24. O efeito prático do erro era descartar até 30 dias
já encerrados, com cobertura oscilando conforme o dia da atualização.

A troca mexeu **somente** no período. Nenhuma regra de cálculo mudou — ver
[seção 7](#7-diferença-para-a-consulta-manual).

### Mudar a cobertura

Para 6, 18 ou 24 meses, troca-se só o número de `@CoberturaMeses`. O passo a
passo no Power Query está na [seção 13](#13-manutenção-no-power-query).

| Cobertura desejada | Linha do SQL |
|---|---|
| 6 meses | `DECLARE @CoberturaMeses int = 6;` |
| 12 meses (padrão) | `DECLARE @CoberturaMeses int = 12;` |
| 18 meses | `DECLARE @CoberturaMeses int = 18;` |
| 24 meses | `DECLARE @CoberturaMeses int = 24;` |

Nenhuma regra de negócio depende desse número. Cobertura maior significa mais
chamados e mais tempo de atualização. Antes de ir além de 12 meses, confira se os
feriados do período mais antigo estão cadastrados — ver
[seção 13](#13-manutenção-no-power-query).

---

## 6. Saída

```text
1 result set
1 linha por SDM
29 colunas
FAIA e FARC juntos, na mesma linha
```

As 29 colunas, na ordem em que saem:

| # | Coluna | Origem |
|---|---|---|
| 1 | `SDM` | compartilhada |
| 2 | `Tipo Chamado` | compartilhada |
| 3 | `Severidade` | compartilhada |
| 4 | `Status` | compartilhada |
| 5 | `Categoria` | compartilhada |
| 6 | `Responsável Abertura` | compartilhada |
| 7 | `Responsável Atendimento` | compartilhada |
| 8 | `Resumo` | compartilhada |
| 9 | `Data de Abertura` | compartilhada |
| 10 | `Data de Encerramento Total do Chamado` | compartilhada |
| 11 | `Data de Encerramento Decision` | compartilhada — ver [seção 8](#8-data-de-encerramento-decision) |
| 12 | `Tempo Total Decision` | compartilhada |
| 13 | `Tempo suspenso` | compartilhada |
| 14 | `Data Captura` | FAIA |
| 15 | `Tempo Primeiro Atendimento` | FAIA |
| 16 | `Primeiro Atendimento Excedido` | FAIA |
| 17 | `Meta Primeiro Atendimento` | FAIA |
| 18 | `Indicador Reabertura` | FAIA |
| 19 | `Acordo Prazo` | FAIA (reservada, sempre `-`) |
| 20 | `Acordo Qualidade` | FAIA (reservada, sempre `-`) |
| 21 | `Justificativa` | FAIA (reservada, sempre `-`) |
| 22 | `nHR_FAIA` | FAIA |
| 23 | `FAIA` | FAIA |
| 24 | `Data Resolução` | FARC |
| 25 | `Tempo de Atendimento` | FARC |
| 26 | `Tempo Atendimento Excedido` | FARC |
| 27 | `Meta Atendimento` | FARC |
| 28 | `nHR_FARC` | FARC |
| 29 | `FARC` | FARC |

Um chamado que exista só no escopo do FARC aparece com as colunas do FAIA
**vazias** — ele não some do resultado.

---

## 7. Diferença para a consulta manual

| | Consulta manual | Consulta Power BI |
|---|---|---|
| Arquivo | `decision/queries/consulta_faia_farc.sql` | `decision/powerbi/consulta_faia_farc_power_bi.sql` |
| Período | **Digitado à mão** (`@InicioBrasil` / `@FimBrasil`, fim inclusivo `23:59:59`) | **Automático**: últimos `@CoberturaMeses` meses até hoje, fim exclusivo em amanhã 00:00 |
| Saída | Várias janelas opcionais por categoria, mais bloco de diagnóstico | **Um** result set, sem filtro de categoria |
| Uso | Execução e análise pontual de um período | Atualização do painel |
| Regra de cálculo | **A mesma** | **A mesma** |

O recorte por G1, G2, SAN, Servidores ou LibQuantum, que na manual é feito por
flags, no Power BI é feito **no próprio painel**, pela coluna `Categoria`, que já
vem no resultado.

Não há diferença funcional entre as duas para nenhuma das 29 colunas.

As diferenças de texto entre os dois arquivos são de três tipos, nenhum deles de
regra:

- **período** — digitado na manual, automático no painel;
- **saída** — janelas opcionais na manual, um único result set no painel;
- **desempenho** — o painel lê `dbo.act_log` uma única vez, na temporária
  `#AtosDEC`, e os blocos caros leem dela; a manual lê a tabela diretamente.
  O texto de cada evento e os filtros são os mesmos (ver [seção 9](#9-desempenho)).

O fim inclusivo da manual (`<= 23:59:59`) e o exclusivo do painel
(`< amanhã 00:00`) selecionam exatamente os mesmos chamados, porque `close_date`
tem resolução de segundos.

Para conferir a equivalência, execute as duas para a **mesma janela** e compare
chamado a chamado. O resultado da última conferência está na
[seção 12](#12-limitações).

---

## 8. `Data de Encerramento Decision`

Esta coluna merece seção própria porque é a que mais gera dúvida.

### Não é o `close_date`

```text
Data de Encerramento Total do Chamado  ->  quando o chamado fechou no SDM
Data de Encerramento Decision          ->  quando a Decision concluiu a atuação dela
```

São coisas diferentes e podem ter valores diferentes — ou uma pode estar
preenchida e a outra não.

O marco da Decision é a **entrada em "Em homologação"**: o momento em que a
equipe terminou o trabalho e entregou o chamado para homologação. A consulta
reconhece esse marco a partir dos eventos do `act_log`.

### O fallback por evento `RE`

Alguns chamados registram a entrada em "Em homologação" com um tipo de evento
diferente do usual. A regra vigente é:

```text
Se a lógica original já encontrou um encerramento válido:
    preserva exatamente o valor.

Se a lógica original resultaria em NULL:
    procura um evento RE cuja transição tenha como DESTINO um status
    classificado como homologação da Decision.
```

O fallback respeita **as mesmas regras** do marco original: o mesmo parser de
origem/destino, o mesmo catálogo de status, a janela `open_date..close_date` e a
posse da Decision. Havendo mais de um evento válido, vale o **último**.

```text
RE -> Em homologação é FALLBACK somente para NULL.
Nenhum valor já preenchido é sobrescrito.
```

Detalhe que costuma confundir: um evento cujo texto **menciona** "Em homologação"
não é necessariamente uma **entrada**. O fechamento
`de 'Em homologação' para 'Resolvido, concluído'` menciona a palavra, mas é uma
**saída** — e não conta. O que vale é o **destino** da transição.

### `NULL` legítimo

> Um chamado pode estar **fechado no sistema** e ainda ter
> `Data de Encerramento Decision = NULL`.

Isso acontece quando **não houve conclusão da atividade pela Decision**. O
exemplo típico são checklists e rotinas semanais que **não foram executados** por
causa de um feriado ou ponto facultativo: o chamado é encerrado como *"Não
resolvido, fechado"*, sem nunca passar por "Em homologação".

Nesses casos o `NULL` está **certo**. Preencher a coluna com `close_date`, com
`Data Resolução` ou com o evento de fechamento passaria a afirmar que a Decision
concluiu uma atividade que os próprios logs registram como **não executada**.

Um `NULL` nessa coluna, portanto, é **informação**, não falha de dados. A
evidência detalhada dos casos investigados está no histórico do projeto, em
`docs/project-context/FAIA-FARC-HISTORICO-CONTEXTO-MESTRE.md`.

### Isolamento comprovado

A regressão da correção comparou o resultado antes e depois, chamado a chamado:

```text
732 linhas antes  ->  732 linhas depois
732 SDMs antes    ->  732 SDMs depois
0 SDMs ausentes   |   0 SDMs extras
0 divergências nas outras 28 colunas
0 valores não-NULL sobrescritos
```

**A correção não alterou nenhum cálculo de tempo.** Permaneceram idênticos:

```text
Tempo Total Decision
Tempo suspenso
Tempo Primeiro Atendimento
Tempo de Atendimento
FAIA
FARC
nHR_FAIA
nHR_FARC
```

---

## 9. Desempenho

**O problema.** A consulta lia `dbo.act_log` várias vezes, e em alguns blocos uma
vez **por linha** (subconsultas correlacionadas). Como o texto de cada evento é
reconstruído e vasculhado caractere a caractere, isso dominava o tempo total.

**A solução.**

- **`#AtosDEC`** — os eventos relevantes de `act_log` são materializados **uma
  única vez**, já com o texto pronto, com índice local.
- **Pré-cálculo compartilhado** dos pares `SOLN → SRVY_SENT`, feito uma vez e
  reaproveitado pelos dois motores em vez de calculado duas vezes.
- Índices locais nas temporárias que entram nos cruzamentos.

**O resultado medido:**

| Momento | Tempo |
|---|---|
| Antes da otimização | ~662 s |
| Depois da otimização | ~42 s |
| Depois da correção de encerramento via `RE` | ~1 min 20 s |

> Estes números são **medições do ambiente testado em 08/2026**, com a janela
> anterior (732 chamados). Não são SLA de execução: variam com volume, carga do
> servidor e plano escolhido pelo otimizador. Com a janela de 12 meses o volume é
> maior, e o tempo cresce junto.

Nenhum índice permanente foi criado no banco. Toda a otimização vive em
tabelas temporárias da sessão.

---

## 10. Conferência

Depois de carregar, vale conferir:

**1. Não há chamado duplicado.** É a checagem mais importante:

```text
COUNT(*) deve ser igual a COUNT(DISTINCT SDM)
```

Se os dois números diferirem, existe duplicidade e o resultado não deve ser
usado.

**2. Quantidade de linhas.** Compare com a atualização anterior: a janela anda
um dia por dia, então o total deve variar pouco de uma atualização para outra.
Uma variação grande merece investigação.

**3. Datas.** `Data de Abertura` ≤ `Data Captura` ≤ `Data de Encerramento Total
do Chamado`. Chamado sem captura fica com `Data Captura` vazia — é normal.

**4. `Data de Encerramento Decision` vazia.** Não é erro por si só. Confira se o
chamado é uma rotina não executada antes de tratar como defeito
(ver [seção 8](#8-data-de-encerramento-decision)).

**5. `nHR_FAIA` e `nHR_FARC`.** Devem aparecer **com casas decimais**. São
proporcionais: um atraso de 1h30 aparece como `1,50`, nunca como `2`.

**6. Tipos de chamado.** Devem aparecer `Incidente`, `Solicitação` e `Problema`.

---

## 11. Cuidados

- **Não substituir `NULL` legítimo de `Data de Encerramento Decision` por
  `close_date`.** Ver [seção 8](#8-data-de-encerramento-decision).
- **Não alterar filtros de status sem validar regressão.** A lista de status é
  lida por código (sigla), nunca por texto, e mudanças ali afetam o escopo
  inteiro.
- **Mudanças no tratamento de `act_log` devem preservar o desempenho.**
  Reintroduzir leitura crua da tabela já custou minutos de execução uma vez.
- **Manter 29 colunas e uma linha por SDM.** Toda tabela que pode multiplicar
  linhas é agregada antes da junção final; alterar isso quebra o contrato de
  saída.
- **Preservar a equivalência funcional com a consulta manual.** As duas devem
  produzir os mesmos valores para o mesmo período.
- **Feriados e pontos facultativos** ficam cadastrados dentro da própria
  consulta. Ao incluir uma data nova, inclua **também** na consulta manual,
  senão os números passam a divergir. Passo a passo na
  [seção 13](#13-manutenção-no-power-query).
- **Não reintroduzir ciclo 24-24.** É regra da A2B/Protect4, não da Decision.
- **Não trocar `@CoberturaMeses` por datas fixas.** A janela tem de andar
  sozinha.

---

## 12. Limitações

**Validado em execução no SQL Server, em 18/09/2026:**

- a consulta executa com sucesso e devolve um único result set;
- a janela móvel é calculada corretamente: `18/09/2025 00:00` até
  `19/09/2026 00:00` exclusivo; o chamado encerrado mais cedo fechou em
  18/09/2025 às 10:38, o que confirma a inclusão do dia inicial, e nenhum dos
  1.478 chamados está fora da janela;
- 1.478 linhas e 1.478 SDMs distintos, sem duplicidade;
- **equivalência com a consulta manual**: executada com
  `@InicioBrasil = 2025-09-18 00:00:00` e `@FimBrasil = 2026-09-18 23:59:59`, a
  manual devolveu **exatamente o mesmo resultado** — mesmas 29 colunas na mesma
  ordem, os mesmos 1.478 SDMs, nenhuma divergência em nenhuma coluna de nenhum
  chamado. Os dois arquivos exportados são **byte a byte idênticos** (mesmo
  SHA256). Somas conferidas: `FAIA` 4,73; `FARC` 149,55; `nHR_FAIA` 47,35;
  `nHR_FARC` 416,40, iguais nas duas.
- **revalidada no mesmo dia depois do calendário de 2025 e de 29/06/2026**:
  mesma janela, mesmos 1.478 SDMs, 0 divergências, exportados de novo byte a
  byte idênticos. As duas consultas mudaram juntas — 43 chamados tiveram tempos
  recalculados, nenhum mudou de meta, `nHR`, FAIA ou FARC.

**Validado no código** (leitura e conferência estática):

- um único lote, sem `GO`, começando com `USE mdb;`; parser do SQL Server 2016
  sem erros;
- `@CoberturaMeses` é declarado uma única vez, na primeira instrução;
- todas as temporárias são criadas antes de serem usadas;
- os nomes das temporárias não colidem com os das outras consultas do
  repositório;
- as tabelas de feriados das duas consultas são idênticas;
- `nHR_FAIA` e `nHR_FARC` usam divisão proporcional, sem `CEILING`.

**Limitações conhecidas:**

- os feriados móveis e pontos facultativos estão cadastrados para **2025 e
  2026**, conforme as portarias do TCU. Os de **2027 ainda não existem**: a partir
  de janeiro de 2027 o calendário comercial fica incompleto até que a portaria
  daquele ano seja cadastrada — ver [seção 13](#13-manutenção-no-power-query);
- os tempos da [seção 9](#9-desempenho) são medições pontuais do ambiente
  testado, não garantia de execução;
- `dbo.audit_log` e `dbo.View_Audit_Group` são tratadas como **opcionais**. Se
  existirem nesta instalação com esquema diferente do esperado, o reforço de
  histórico de grupo pode falhar — a consulta testa a existência do objeto, mas
  não o esquema dele.

---

## 13. Manutenção no Power Query

O texto SQL da consulta fica guardado na etapa **Fonte** do Power Query. É ali
que se mexe tanto na cobertura quanto nos feriados.

### Onde fica o texto SQL

1. No Power BI Desktop: **Página Inicial → Transformar dados**. Abre o Power
   Query.
2. No painel **Consultas**, à esquerda, selecione a consulta da Decision.
3. No painel **Configurações da consulta**, à direita, em **Etapas aplicadas**,
   clique na **engrenagem** da etapa **Fonte**.
4. Abre a janela **Banco de dados SQL Server**. Em **Opções avançadas**, o campo
   **Instrução SQL** contém a consulta inteira.
5. Depois de editar: **OK → Fechar e aplicar**. Na primeira atualização o Power
   BI pede para **aprovar a consulta nativa** — aprove.

> Não existe um parâmetro do Power BI separado para a cobertura: ela é uma linha
> do próprio SQL. Isso é deliberado. Montar o SQL por concatenação em M para
> expor um parâmetro faria a engrenagem da etapa Fonte deixar de mostrar o texto
> editável, e o painel passaria a depender de código M que não está versionado
> neste repositório.

### Mudar a cobertura (6, 12, 18, 24 meses)

A primeira instrução do SQL, logo abaixo de `SET TRANSACTION ...`, é:

```sql
DECLARE @CoberturaMeses int = 12;
```

1. Abra a etapa **Fonte** como acima.
2. No começo do campo **Instrução SQL**, troque `12` pelo número de meses.
3. **OK → Fechar e aplicar**, e aprove a consulta nativa.

É o único número que muda. Não altere mais nada do texto para mudar o período.

Se a cobertura nova for **permanente**, faça a mesma troca em
`decision/powerbi/consulta_faia_farc_power_bi.sql` e registre no Histórico
Mestre, para o repositório continuar igual ao painel.

### Atualizar feriados e pontos facultativos

**Onde estão.** Dentro do próprio SQL, no bloco
`[FERIADOS E PONTOS FACULTATIVOS]`, em duas tabelas:

| Tabela | O que guarda | Formato da data |
|---|---|---|
| `#FeriadosFixos_DEC` | Feriados nacionais que caem no mesmo dia todo ano (Natal, Tiradentes, Finados…) | `'MM-DD'` — ex.: `'12-25'` |
| `#FeriadosPorData_DEC` | Feriados móveis (Paixão de Cristo) e **pontos facultativos do TCU**, que mudam de ano para ano | `'YYYY-MM-DD'` — ex.: `'2025-11-21'` |

**De onde vêm as datas.** Só de fonte **oficial do TCU**: a portaria anual do
Presidente do TCU que "divulga os feriados nacionais e define os dias de ponto
facultativo" do ano, publicada no **Boletim do TCU (BTCU)**, e **todas as
portarias que a alterarem**. As alterações durante o ano são comuns — em 2025
foram três, que acrescentaram 02/05, 21/11 e 26/12; em 2026, uma, que
acrescentou 29/06 (jogo da Seleção na Copa). Não use calendário civil genérico, blog nem
calendário de outro órgão: o que vale é o expediente do TCU.

Onde procurar: `pesquisa.apps.tcu.gov.br`, base **Normas**, buscando "ponto
facultativo" e o ano. A ficha da portaria anual lista, em "Alterada por", todas as
alterações. Cada ato traz um código de autenticidade verificável em
`www.tcu.gov.br/autenticidade`.

Fontes do cadastro atual:

| Ano | Portaria anual | Alterações |
|---|---|---|
| 2025 | Portaria-TCU nº 10, de 13/01/2025 | nº 67 (28/04/2025), nº 157 (30/10/2025), nº 176 (19/12/2025) |
| 2026 | Portaria-TCU nº 1, de 08/01/2026 | nº 93 (25/06/2026) |

O que entra em cada tabela:

- **feriado nacional de data fixa** → `#FeriadosFixos_DEC`, uma vez só, vale para
  todos os anos;
- **feriado nacional móvel** (Paixão de Cristo) e **ponto facultativo** →
  `#FeriadosPorData_DEC`, com o ano;
- ponto facultativo de **meio expediente**, se algum dia houver, precisa de
  decisão antes de ser cadastrado: a tabela só representa o dia inteiro.

Cada linha é `('data', N'descrição')`, separada da próxima por vírgula. A última
linha de cada `VALUES` termina em `;` e não em vírgula.

**Como fazer.** O bloco fica no meio de um texto longo, e a caixa **Instrução
SQL** não tem busca. O caminho seguro é editar o **arquivo** e colar de volta:

1. Abra `decision/powerbi/consulta_faia_farc_power_bi.sql` num editor e procure
   `[FERIADOS E PONTOS FACULTATIVOS]`.
2. **Adicionar:** inclua uma linha na tabela certa, no bloco do ano. Ex., o
   ponto facultativo de 21/11/2025 (Portaria-TCU nº 157/2025):
   ```sql
   ('2025-11-21', N'Ponto facultativo - sexta-feira após Consciência Negra'),
   ```
   Registre no comentário do bloco a portaria de origem.
3. **Corrigir:** edite a data ou a descrição na linha existente.
4. **Remover:** apague a linha inteira e confira a vírgula da linha anterior.
5. Faça **exatamente a mesma alteração** em
   `decision/queries/consulta_faia_farc.sql`. As duas consultas têm de ter a
   mesma lista, senão os números passam a divergir.
6. Copie o arquivo do Power BI **inteiro** e cole no campo **Instrução SQL** da
   etapa **Fonte**, substituindo o texto anterior.
7. **OK → Fechar e aplicar**, aprove a consulta nativa e **atualize**.

**Cuidados.**

- Cada data aparece **uma vez só** por tabela. Uma data repetida faz a
  atualização falhar com `Violation of PRIMARY KEY constraint`, e a mensagem cita
  a data repetida — nada é carregado até que a linha duplicada seja removida.
- Não cadastre o mesmo dia nas duas tabelas.
- Um feriado que cai em sábado ou domingo não muda o tempo comercial, porque
  fim de semana já fica fora dele. Cadastrá-lo não causa problema.
- O ano de um feriado fixo não se escreve: `'MM-DD'` vale para todos os anos.

**Efeito nos cálculos.** Um dia cadastrado deixa de contar como tempo
**comercial**. Isso afeta:

- as metas de FAIA e FARC contadas em horário comercial (segunda a sexta,
  08:00–20:00) — as metas em tempo **corrido** não mudam;
- o início da contagem quando o chamado é aberto num feriado;
- a classificação e o motor das rotinas;
- o tempo suspenso do FARC.

Os valores só mudam depois de **atualizar** o painel. Como o cálculo usa a vida
inteira de cada chamado, um feriado novo pode alterar chamados já carregados
antes, se a vida deles passar pela data.

**Situação atual do cadastro.** Os feriados fixos valem para todos os anos. Os
móveis e os pontos facultativos estão cadastrados para **2025 e 2026 completos**,
conferidos contra as portarias da tabela acima. **2027 ainda não está
cadastrado.**

**Quando revisar.** Sempre que a janela passar a cobrir um ano novo — com a
cobertura padrão de 12 meses, isso acontece a partir de **1º de janeiro** —, e
sempre que o TCU publicar uma portaria que altere o calendário do ano corrente.
Aumentar `@CoberturaMeses` além de 12 também exige conferir se o ano mais antigo
alcançado está cadastrado.
