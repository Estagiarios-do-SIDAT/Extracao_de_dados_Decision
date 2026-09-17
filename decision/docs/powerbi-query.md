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

O período é **automático**. Não há data para editar.

- A consulta devolve sempre os **seis últimos ciclos completos**.
- Um ciclo vai do **dia 24** de um mês até o **dia 23** do mês seguinte.
- O ciclo **em andamento não entra** — só entram ciclos já fechados.
- As datas são interpretadas no **horário do Brasil (GMT-3)**. O SDM grava em
  UTC; a consulta converte.
- O intervalo é **semiaberto**: `>= início` e `< fim`, o que evita erro de borda
  no último segundo do dia 23.

**Exemplo real, medido em 20/08/2026:**

```text
janela = 24/01/2026 00:00:00  até  24/07/2026 00:00:00 (exclusivo)

ciclos completos:  24/01 a 23/02
                   24/02 a 23/03
                   24/03 a 23/04
                   24/04 a 23/05
                   24/05 a 23/06
                   24/06 a 23/07

ciclo em andamento, EXCLUÍDO:  24/07 a 23/08
```

**O filtro usa a data de fechamento do chamado** (`close_date`): entra no
resultado todo chamado que **fechou** dentro da janela.

Um ponto importante:

> O período **seleciona quais chamados entram**. Ele **não corta** os tempos
> calculados.

Se um chamado fechou dentro da janela mas foi aberto antes dela, o FAIA e o FARC
são calculados sobre a vida inteira do chamado.

**Meses de borda.** Como o ciclo começa no dia 24, a janela corta o primeiro e o
último mês ao meio. Ao agrupar o painel por mês, as duas pontas aparecem com
volume menor que um mês cheio. Não é defeito — é consequência de cruzar janela
por ciclo com agrupamento por mês.

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
| Período | **Digitado à mão** (`@InicioBrasil` / `@FimBrasil`) | **Automático**: seis ciclos completos |
| Saída | Várias janelas opcionais por categoria, mais bloco de diagnóstico | **Um** result set, sem filtro de categoria |
| Uso | Execução e análise pontual de um período | Atualização do painel |
| Regra de cálculo | **A mesma** | **A mesma** |

O recorte por G1, G2, SAN, Servidores ou LibQuantum, que na manual é feito por
flags, no Power BI é feito **no próprio painel**, pela coluna `Categoria`, que já
vem no resultado.

Não há diferença funcional entre as duas para nenhuma das 29 colunas.

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

> Estes números são **medições do ambiente testado**, com a janela de seis ciclos
> e 732 chamados. Não são SLA de execução: variam com volume, carga do servidor e
> plano escolhido pelo otimizador.

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

**2. Quantidade de linhas.** Compare com o esperado para seis ciclos. Uma
variação grande de um mês para o outro merece investigação.

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
  senão os números passam a divergir.

---

## 12. Limitações

**Validado em execução no SQL Server:**

- a consulta executa com sucesso e devolve um único result set;
- a janela de seis ciclos é calculada corretamente
  (`24/01/2026` a `24/07/2026` exclusivo, medido em 20/08/2026);
- 732 linhas e 732 SDMs distintos no período, sem duplicidade;
- a correção de `Data de Encerramento Decision` não alterou nenhuma das outras
  28 colunas.

**Validado no código** (leitura e conferência estática):

- um único lote, sem `GO`, começando com `USE mdb;`;
- todas as temporárias são criadas antes de serem usadas;
- os nomes das temporárias não colidem com os das outras consultas do
  repositório;
- `nHR_FAIA` e `nHR_FARC` usam divisão proporcional, sem `CEILING`.

**Limitações conhecidas:**

- os feriados e pontos facultativos vão **até 2026**. A partir de janeiro de 2027
  o calendário comercial fica incompleto até que as datas do ano sejam incluídas.
- os tempos da [seção 9](#9-desempenho) são medições pontuais do ambiente
  testado, não garantia de execução.
- `dbo.audit_log` e `dbo.View_Audit_Group` são tratadas como **opcionais**. Se
  existirem nesta instalação com esquema diferente do esperado, o reforço de
  histórico de grupo pode falhar — a consulta testa a existência do objeto, mas
  não o esquema dele.
