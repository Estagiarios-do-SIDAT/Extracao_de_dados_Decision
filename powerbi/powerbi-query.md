# Consulta consolidada do Power BI — Decision

Documentação da fonte de dados usada no painel de FAIA e FARC da Decision.

Escrita para quem vai **usar** o painel, não para quem escreveu o SQL. A regra de
cálculo de cada indicador está em [faia-farc-calculation.md](../docs/faia-farc-calculation.md).

---

## Índice

1. [Finalidade](#1-finalidade)
2. [Consulta de referência](#2-consulta-de-referência)
3. [Como usar no Power BI](#3-como-usar-no-power-bi)
4. [Power BI e SQL Server](#4-power-bi-e-sql-server)
5. [Período da consulta](#5-período-da-consulta)
6. [Saída](#6-saída) — inclui [Data Entrada Grupo Decision](#61-data-entrada-grupo-decision)
7. [Diferença para a consulta manual](#7-diferença-para-a-consulta-manual)
8. [`Data de Encerramento Decision`](#8-data-de-encerramento-decision)
9. [Desempenho](#9-desempenho)
10. [Conferência](#10-conferência)
11. [Cuidados](#11-cuidados)
12. [Limitações](#12-limitações)
13. [Manutenção no Power Query](#13-manutenção-no-power-query)
14. [Feriados e SharePoint](#14-feriados-e-sharepoint)

Há uma versão desta documentação em HTML, para exibir dentro do painel no visual
**HTML Content**: `powerbi/documentacao-powerbi-decision.html`. Ela deriva
deste arquivo; se os dois divergirem, **vale este**.

---

## 1. Finalidade

A consulta reúne, em **uma linha por chamado**:

```text
dados do chamado
resultado do FAIA
resultado do FARC
```

Ela devolve **um único resultado**, com **31 colunas**. Não traz tabelas de
diagnóstico nem resultados intermediários.

Arquivos:

```text
powerbi/consulta_faia_farc_power_bi.m     A consulta do painel (Power Query M) — a única que vai para o Power BI
queries/consulta_faia_farc_painel.sql     consulta de referência do painel: o SQL que o .m executa (fonte do .m; testes)
```

O `.m` lê o `feriados.txt` no SharePoint, valida e executa o SQL com o
parâmetro `@Feriados`. Ele é **gerado** a partir de
`queries/consulta_faia_farc_painel.sql` por `tools/gerar_powerbi_m.ps1`; o SQL
não se cola no Power BI, e o `tools/verificar_feriados.ps1` acusa `.m`
desatualizado. Para gerar de novo:

```powershell
.\tools\gerar_powerbi_m.ps1 -Consulta .\queries\consulta_faia_farc_painel.sql -Saida .\powerbi\consulta_faia_farc_power_bi.m
```

---

## 2. Consulta de referência

A **referência funcional** continua sendo a consulta manual:

```text
queries/consulta_faia_farc.sql
```

A versão do Power BI **não reimplementa** nenhum cálculo. O motor — FAIA, FARC,
motores de rotina e de status, suspensões, calendário, feriados, terminais,
posse/reposse — é o mesmo. O que muda é o período e o formato de saída
(ver [seção 7](#7-diferença-para-a-consulta-manual)).

Quando houver dúvida sobre **como** um número é calculado, a resposta está na
consulta manual e em [faia-farc-calculation.md](../docs/faia-farc-calculation.md).

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

O SQL não é mais colado em **Instrução SQL**: os feriados vêm de um arquivo no
SharePoint, que o SQL Server não lê. A consulta do painel é o `.m`:

1. **Página Inicial → Nova Fonte → Consulta Nula → Editor Avançado.**
2. Cole o conteúdo inteiro de `consulta_faia_farc_power_bi.m`.
3. Preencha `SharePointFeriadosUrl` (no topo do `.m`) com o link direto do
   `feriados.txt` no SharePoint (o mesmo da Virtual TI e da A2B; ver
   [seção 14](#14-feriados-e-sharepoint)).
4. Credenciais: SQL Server como hoje; SharePoint com **conta organizacional**.
   Privacidade das duas fontes: **Organizacional**. No gateway, permitir fontes
   de nuvem.
5. Carregue e, na primeira vez, confira a quantidade de chamados
   (ver [seção 10](#10-conferência)).
6. Nas próximas vezes, basta **Atualizar**: o período se ajusta sozinho
   (ver [seção 5](#5-período-da-consulta)) e o arquivo de feriados é lido de novo.
7. Na primeira atualização depois de qualquer mudança no texto SQL, o Power BI
   pede para **aprovar a execução da consulta nativa**. Isso é esperado.

Não é preciso ajustar datas a cada mês. Arquivo de feriados inacessível,
placeholder não preenchido ou linha inválida **falham a atualização** com
mensagem; o painel nunca é calculado sem feriados. Requisitos do serviço e
checklist do primeiro refresh na [seção 14](#14-feriados-e-sharepoint).

---

## 4. Power BI e SQL Server

### Quem executa a consulta

O `.sql` é **T-SQL puro**. O `.m` só lê e valida o arquivo de feriados e envia
o SQL com o parâmetro `@Feriados`.

```text
A consulta é usada pelo Power BI, mas é executada pelo SQL Server.
O Power BI envia o script pelo conector, com o parâmetro @Feriados, e importa o resultado.
```

O Power BI **não calcula nada**: abre a conexão, manda o texto do script e a
lista de feriados, espera e recebe o result set final. O mesmo script roda
integralmente no SSMS, com `@Feriados` declarado (ver abaixo).

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
3. Gere uma cópia com os feriados declarados
   (`.\tools\executar_consulta.ps1 -Consulta .\queries\consulta_faia_farc_painel.sql -GerarSql C:\temp\painel.sql`),
   abra-a **inteira** e execute **sem selecionar trecho**. Executar só um
   pedaço quebra a consulta: as temporárias dos blocos anteriores não existiriam.
   O arquivo original, sem `@Feriados`, falha com
   `Must declare the scalar variable "@Feriados"`.
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
| `Must declare the scalar variable "@Feriados"` | Arquivo executado sem a lista de feriados | Gerar a cópia com `tools/executar_consulta.ps1 -GerarSql` |
| `Feriados: @Feriados vazio ou invalido` / `data fora do formato` | Lista de feriados vazia ou com data inválida | Corrigir o `feriados.txt` ([seção 14](#14-feriados-e-sharepoint)) |
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
feriados do período mais antigo estão no `feriados.txt` — ver
[`docs/feriados.txt`](../docs/feriados.txt).

---

## 6. Saída

```text
1 result set
1 linha por SDM
31 colunas
FAIA e FARC juntos, na mesma linha
```

As 31 colunas, na ordem em que saem:

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
| 9 | `Item de Configuração` | compartilhada |
| 10 | `Data de Abertura` | compartilhada |
| 11 | `Data Entrada Grupo Decision` | compartilhada — ver [seção 6.1](#61-data-entrada-grupo-decision) |
| 12 | `Data de Encerramento Total do Chamado` | compartilhada |
| 13 | `Data de Encerramento Decision` | compartilhada — ver [seção 8](#8-data-de-encerramento-decision) |
| 14 | `Tempo Total Decision` | compartilhada |
| 15 | `Tempo suspenso` | compartilhada |
| 16 | `Data Captura` | FAIA |
| 17 | `Tempo Primeiro Atendimento` | FAIA |
| 18 | `Primeiro Atendimento Excedido` | FAIA |
| 19 | `Meta Primeiro Atendimento` | FAIA |
| 20 | `Indicador Reabertura` | FAIA |
| 21 | `Acordo Prazo` | FAIA (reservada, sempre `-`) |
| 22 | `Acordo Qualidade` | FAIA (reservada, sempre `-`) |
| 23 | `Justificativa` | FAIA (reservada, sempre `-`) |
| 24 | `nHR_FAIA` | FAIA |
| 25 | `FAIA` | FAIA |
| 26 | `Data Resolução` | FARC |
| 27 | `Tempo de Atendimento` | FARC |
| 28 | `Tempo Atendimento Excedido` | FARC |
| 29 | `Meta Atendimento` | FARC |
| 30 | `nHR_FARC` | FARC |
| 31 | `FARC` | FARC |

`Item de Configuração` é o IC associado ao chamado no SDM — o campo *Item de
configuração* da tela do chamado. Chamado sem IC fica com a coluna vazia.

Um chamado que exista só no escopo do FARC aparece com as colunas do FAIA
**vazias** — ele não some do resultado.

### 6.1 Data Entrada Grupo Decision

Marca **quando o chamado caiu no grupo Fornecedores - Decision**, sempre na
**primeira** entrada. Se o chamado saiu e voltou ao grupo, a coluna continua
mostrando a primeira vez.

É uma coluna diferente de `Data Captura`, e não a substitui:

| Coluna | O que marca |
|---|---|
| `Data de Abertura` | Abertura do chamado no SDM, em qualquer grupo |
| `Data Entrada Grupo Decision` | Quando o chamado passou a ser da Decision |
| `Data Captura` | Primeira ida para "Em andamento", quando alguém começou a atuar |

Quando o chamado **nasce** no grupo, a entrada coincide com a abertura. Quando
chega por transferência, fica entre a abertura e o momento em que a Decision
assumiu o atendimento.

No período conferido as três aparecem em ordem crescente em todos os chamados,
mas isso é um **resultado observado**, não uma restrição imposta pela consulta:
cada coluna vem de uma fonte própria.

Chamado sem registro de entrada no histórico fica com a coluna **vazia**, do
mesmo modo que `Data Captura` fica vazia quando não houve captura.

A coluna é informativa: nenhum tempo, meta, `nHR` ou valor de FAIA/FARC muda por
causa dela.

---

## 7. Diferença para a consulta manual

| | Consulta manual | Consulta Power BI |
|---|---|---|
| Arquivo | `queries/consulta_faia_farc.sql` | `queries/consulta_faia_farc_painel.sql` (executada pelo `powerbi/consulta_faia_farc_power_bi.m`) |
| Período | **Digitado à mão** (`@InicioBrasil` / `@FimBrasil`, fim inclusivo `23:59:59`) | **Automático**: últimos `@CoberturaMeses` meses até hoje, fim exclusivo em amanhã 00:00 |
| Saída | Várias janelas opcionais por categoria, mais bloco de diagnóstico | **Um** result set, sem filtro de categoria |
| Uso | Execução e análise pontual de um período | Atualização do painel |
| Regra de cálculo | **A mesma** | **A mesma** |

O recorte por G1, G2, SAN, Servidores ou LibQuantum, que na manual é feito por
flags, no Power BI é feito **no próprio painel**, pela coluna `Categoria`, que já
vem no resultado.

Não há diferença funcional entre as duas para nenhuma das 31 colunas.

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

### Entrada em homologação gravada como `RE`

Alguns chamados registram a entrada em "Em homologação" com um tipo de evento
diferente do usual (`RE`). A linha de status lê esse evento, e o marco é
reconhecido como qualquer outra entrada em homologação: vale a última
**entrada** em posse da Decision. Um `SOLN` posterior, com o chamado já em
homologação, não é nova entrada.

O mesmo evento é lido pelos motores do `Tempo Total Decision` e do
`Tempo de Atendimento` (FARC): a partir dele o chamado está em homologação, que
é pausa.

O fallback abaixo, criado quando a linha de status ainda não lia `RE`, continua
na consulta como rede de segurança:

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
`project-context/DECISION-HISTORICO-CONTEXTO-MESTRE.md`.

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

**3. Datas.** O esperado é `Data de Abertura` ≤ `Data Entrada Grupo Decision` ≤
`Data Captura` ≤ `Data de Encerramento Total do Chamado`. Um chamado fora dessa
ordem não é erro automático: vale checar o histórico de grupo dele. Chamado sem
captura fica com `Data Captura` vazia — é normal, e o mesmo vale para a entrada
no grupo quando o histórico não a registra.

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
- **Manter 31 colunas e uma linha por SDM.** Toda tabela que pode multiplicar
  linhas é agregada antes da junção final; alterar isso quebra o contrato de
  saída.
- **Preservar a equivalência funcional com a consulta manual.** As duas devem
  produzir os mesmos valores para o mesmo período.
- **Feriados e pontos facultativos** ficam no arquivo de feriados, e não no
  SQL. Painel e consulta manual leem o mesmo conteúdo (SharePoint e
  `docs/feriados.txt`, mantidos iguais). Passo a passo na
  [seção 13](#13-manutenção-no-power-query).
- **O período é uma janela móvel**, calculada a cada atualização a partir da
  data corrente. Trocar `@CoberturaMeses` muda quantos meses ela cobre; datas
  fixas descaracterizam a regra e exigem nova validação.

---

## 12. Limitações

**Validado em execução no SQL Server, em 18/09/2026:**

- a consulta executa com sucesso e devolve um único result set;
- a janela móvel é calculada corretamente: `18/09/2025 00:00` até
  `19/09/2026 00:00` exclusivo; o chamado encerrado mais cedo fechou em
  18/09/2025 às 10:38, o que confirma a inclusão do dia inicial, e nenhum dos
  1.478 chamados está fora da janela;
- 1.478 linhas e 1.478 SDMs distintos, sem duplicidade;
- **equivalência com a consulta manual**: executada com o mesmo período, a
  manual devolveu **exatamente o mesmo resultado** — as mesmas colunas na mesma
  ordem, os mesmos 1.478 SDMs, nenhuma divergência em nenhuma coluna de nenhum
  chamado. Os dois arquivos exportados são **byte a byte idênticos** (mesmo
  SHA256). Somas conferidas: `FAIA` 4,73; `FARC` 149,55; `nHR_FAIA` 47,35;
  `nHR_FARC` 416,40, iguais nas duas.
- a conferência foi repetida com o calendário vigente, com o mesmo resultado:
  mesma janela, mesmos 1.478 SDMs e 0 divergências entre as duas consultas.

**Conferência de `Data Entrada Grupo Decision`**, na janela de 22/09/2025 a
22/09/2026:

- as 1.478 linhas trazem a coluna preenchida; nenhuma ficou vazia;
- 1.429 chamados nasceram no grupo (entrada = abertura) e 49 chegaram por
  transferência (entrada posterior à abertura);
- em todos eles a entrada no grupo ficou antes ou no mesmo instante da
  `Data Captura`, e nunca antes da `Data de Abertura`;
- nos chamados que entraram, saíram e voltaram ao grupo, a coluna mostra a
  **primeira** entrada. Em `1725544`, que entrou em 19/08 às 18:13:03, saiu em
  20/08 às 10:55:16 e voltou às 10:56:41, a coluna traz 19/08 18:13:03;
- os valores conferidos contra o `act_log` bruto coincidem ao segundo;
- painel e consulta de referência devolvem a coluna com o mesmo valor em todos
  os 1.478 chamados.

**Validado no código** (leitura e conferência estática):

- um único lote, sem `GO`, começando com `USE mdb;`; parser do SQL Server 2016
  sem erros;
- `@CoberturaMeses` é declarado uma única vez, na primeira instrução;
- todas as temporárias são criadas antes de serem usadas;
- os nomes das temporárias não colidem com os das outras consultas do
  repositório;
- as duas consultas leem os feriados do mesmo arquivo, pelo parâmetro
  `@Feriados` (desde 2026-10-07);
- `nHR_FAIA` e `nHR_FARC` usam divisão proporcional, sem `CEILING`.

**Limitações conhecidas:**

- os feriados móveis e pontos facultativos estão no arquivo de feriados para
  **2025 e 2026**, conforme as portarias do TCU. Os de **2027 ainda não
  existem**: a partir de janeiro de 2027 o calendário comercial fica incompleto
  até que a portaria daquele ano seja cadastrada no arquivo — ver
  [seção 13](#13-manutenção-no-power-query);
- o `.m` foi validado com o motor do Power BI Desktop, fora do PBIX e com o
  arquivo de feriados servido localmente: executa com as duas fontes como
  Organizacional e o firewall de privacidade ativo, e devolve o mesmo resultado
  do SQL. A primeira versão gerada (um passo por etapa) era recusada pelo
  firewall (*Formula.Firewall*); a atual faz tudo num único passo (`Fonte`). O
  acesso ao SharePoint Online real (OAuth2), o gateway e o refresh no serviço
  ainda dependem de validação no PBIX ([seção 14](#14-feriados-e-sharepoint));
- os tempos da [seção 9](#9-desempenho) são medições pontuais do ambiente
  testado, não garantia de execução;
- `dbo.audit_log` e `dbo.View_Audit_Group` são tratadas como **opcionais**. Se
  existirem nesta instalação com esquema diferente do esperado, o reforço de
  histórico de grupo pode falhar — a consulta testa a existência do objeto, mas
  não o esquema dele.

---

## 13. Manutenção no Power Query

O texto SQL fica dentro da consulta M, no valor `SqlTexto`. A cobertura é uma
linha desse SQL. **Os feriados não ficam no SQL**: ficam no arquivo de feriados
no SharePoint.

### Onde fica o texto SQL

1. No Power BI Desktop: **Página Inicial → Transformar dados**. Abre o Power
   Query.
2. No painel **Consultas**, à esquerda, selecione a consulta da Decision.
3. **Página Inicial → Editor Avançado.** O SQL está no texto `SqlTexto`.
4. Depois de editar: **Concluído → Fechar e aplicar**. Na primeira atualização
   o Power BI pede para **aprovar a consulta nativa** — aprove.

O caminho recomendado é alterar `queries/consulta_faia_farc_painel.sql` no
repositório, gerar o `.m` de novo
(`.\tools\gerar_powerbi_m.ps1 -Consulta .\queries\consulta_faia_farc_painel.sql -Saida .\powerbi\consulta_faia_farc_power_bi.m`)
e colar o `.m` inteiro no Editor Avançado, preenchendo de novo
`SharePointFeriadosUrl`. O `.m` gerado é versionado no repositório.

### Mudar a cobertura (6, 12, 18, 24 meses)

A primeira instrução do SQL, logo abaixo de `SET TRANSACTION ...`, é:

```sql
DECLARE @CoberturaMeses int = 12;
```

1. Abra o **Editor Avançado** como acima.
2. No começo do texto `SqlTexto`, troque `12` pelo número de meses.
3. **Concluído → Fechar e aplicar**, e aprove a consulta nativa.

É o único número que muda. Não altere mais nada do texto para mudar o período.

A consulta usada pelo painel fica incorporada ao próprio relatório, então a
troca vale a partir da próxima atualização. Existe um repositório interno, usado
para versionamento e manutenção técnica, onde a mesma alteração é registrada
pela equipe responsável quando a cobertura muda em definitivo.

### Atualizar feriados e pontos facultativos

**Onde estão.** No **calendário** `feriados.txt`, e não no SQL: no SharePoint
para o painel e em `docs/feriados.txt` para a consulta manual. É o calendário
do TCU, o mesmo para Virtual TI, Decision e A2B (não há lista por projeto). Texto
simples, em três seções, uma data por linha; as regras de preenchimento estão
no próprio [`docs/feriados.txt`](../docs/feriados.txt):

| Seção do arquivo | O que guarda | Data |
|---|---|---|
| `## Feriados Fixos` | Feriados nacionais que caem no mesmo dia todo ano (Natal, Tiradentes, Finados…) | `DD-MM` — ex.: `25-12` |
| `## Feriados móveis/diferenciados` | Feriados de data variável (Paixão de Cristo) | `DD-MM-AAAA` — ex.: `03-04-2026` |
| `## Pontos Facultativos` | **Pontos facultativos do TCU** do ano | `DD-MM-AAAA` — ex.: `21-11-2025` |

No SQL, o bloco `[FERIADOS E PONTOS FACULTATIVOS]` só recebe a lista
(`@Feriados`), valida e monta `#FeriadosFixos_DEC` e `#FeriadosPorData_DEC`,
usadas pelos cálculos como antes.

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
| 2026 | Portaria-TCU nº 1, de 08/01/2026 (02/01 também pela nº 179, de 19/12/2025) | nº 93 (25/06/2026) |

Os textos foram conferidos no Boletim do TCU pelos códigos de autenticidade
(lista no histórico do projeto, `project-context/`).

O que entra em cada tipo:

- **feriado nacional de data fixa** → `DD-MM`, uma vez só, vale para todos os
  anos;
- **feriado nacional móvel** (Paixão de Cristo) e **ponto facultativo** →
  `DD-MM-AAAA`, com o ano, cada um na sua seção;
- ponto facultativo de **meio expediente**, se algum dia houver, precisa de
  decisão antes de ser cadastrado: o arquivo só representa o dia inteiro.

**Como fazer.** Sem mexer no SQL nem republicar o relatório:

1. Abra o `feriados.txt` no SharePoint.
2. **Adicionar:** inclua a data, sozinha na linha, na seção certa. Ex., o ponto
   facultativo de 21/11/2025 (Portaria-TCU nº 157/2025), em
   `## Pontos Facultativos`:
   ```text
   21-11-2025
   ```
   Registre a Portaria (número e código de autenticidade) no histórico do
   projeto (`project-context/`). Não repita os feriados fixos (`DD-MM`): eles
   já valem todo ano.
3. **Corrigir:** edite a data na linha existente.
4. **Remover:** apague a linha da data.
5. Salve. A próxima atualização do painel já usa a lista nova.
6. Copie o mesmo arquivo para o `docs/feriados.txt` dos repositórios
   Virtual TI, Decision e A2B e para `Documentos e Relatórios/feriados.txt`,
   e rode `tools/verificar_feriados.ps1`; a consulta manual passa a usar a
   lista nova.

**Cuidados.**

- Data inexistente (`30-02-2026`), linha que parece data fora do formato
  (`2026-02-30`, `26/11/2026`), data repetida ou fora da seção certa **falham a
  atualização** com a linha do problema; nada é calculado com uma lista pela
  metade nem com zero feriados.
- Um feriado que cai em sábado ou domingo não muda o tempo comercial, porque
  fim de semana já fica fora dele. Na Decision, ele só aparece como motivo no
  diagnóstico de rotina aberta nesse dia.
- O ano de um feriado fixo não se escreve: `DD-MM` vale para todos os anos.

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
móveis e os pontos facultativos estão no arquivo para **2025 e 2026 completos**,
conferidos contra as portarias da tabela acima. **2027 ainda não está
cadastrado.**

**Quando revisar.** Sempre que a janela passar a cobrir um ano novo — com a
cobertura padrão de 12 meses, isso acontece a partir de **1º de janeiro** —, e
sempre que o TCU publicar uma portaria que altere o calendário do ano corrente.
Aumentar `@CoberturaMeses` além de 12 também exige conferir se o ano mais antigo
alcançado está cadastrado.

## 14. Feriados e SharePoint

O cálculo do Horário TCU é feito no SQL Server, que **não lê** o SharePoint.
A consulta do Power BI (`.m`) lê o calendário `feriados.txt` do SharePoint a
cada atualização, valida todas as linhas, converte as datas para o formato do
SQL (`DD-MM` → `MM-DD`, `DD-MM-AAAA` → `AAAA-MM-DD`) e envia a lista ao SQL no
parâmetro `@Feriados` (JSON). Nenhum texto do arquivo é concatenado no SQL.

**Qual arquivo.** O calendário é o `feriados.txt`, o mesmo para Virtual TI,
Decision e A2B. A cópia versionada é [`docs/feriados.txt`](../docs/feriados.txt)
(as regras de preenchimento estão no próprio arquivo); a do SharePoint é a que
o painel lê. Mantenha as duas iguais, e também as cópias dos outros
repositórios e de `Documentos e Relatórios/feriados.txt`; o
`tools/verificar_feriados.ps1` confere.

**Onde trocar o link.** Para trocar o endereço do SharePoint, altere apenas
`SharePointFeriadosUrl`. É a primeira linha depois de `let` no `.m`, dentro do
bloco `CONFIGURACAO - SHAREPOINT`; o endereço não aparece em nenhum outro lugar
do arquivo:

```powerquery
SharePointFeriadosUrl = "INSERIR_URL_DO_ARQUIVO_FERIADOS_NO_SHAREPOINT",
```

**PENDENTE DO LINK REAL DO SHAREPOINT.** O endereço definitivo do
`feriados.txt` ainda não foi registrado (2026-10-07: nenhum link do arquivo
foi encontrado nos repositórios nem em `Documentos e Relatórios`). Enquanto o
placeholder estiver no `.m`, a atualização falha com *Preencha
SharePointFeriadosUrl...*. Use o link **direto** do arquivo, no formato
`https://<empresa>.sharepoint.com/sites/<site>/Shared%20Documents/<pasta>/feriados.txt`
(no SharePoint: `...` do arquivo > *Detalhes* > *Caminho*; tirar o final
`?web=1`, se houver; o link de compartilhamento `/:t:/r/...` não serve), o
mesmo nos três relatórios. Ao gerar o `.m` de novo, o placeholder volta: troque
de novo, ou registre o link definitivo no `tools/gerar_powerbi_m.ps1` (único
ponto, comum aos três repositórios).

**Configuração no Power BI.**

- **Privacidade:** SharePoint e SQL Server como **Organizacional**. Com uma das
  fontes Privada ou Pública, ou sem nível definido, o Power Query recusa a
  combinação. Não é preciso (nem recomendado) ignorar os níveis de
  privacidade.
- **Credenciais:** SQL Server como hoje (Windows/gateway); SharePoint com
  *Conta organizacional*.
- **Gateway:** o SQL Server é local e o SharePoint Online é fonte de nuvem; a
  consulta combina as duas e é avaliada no gateway: habilitar *Permitir que as
  fontes de dados de nuvem do usuário sejam atualizadas por este cluster de
  gateway*.
- **Consulta nativa:** no Desktop, aprovar a execução da consulta nativa na
  primeira vez (e a cada mudança do SQL).
- **Formula.Firewall:** a leitura do SharePoint e o SQL ficam num único passo
  (`Fonte`); não separe os passos. `SharePointFeriadosUrl` é só um texto e
  pode ficar no topo.

**Falhas que interrompem a atualização** (com a mensagem e, quando for o caso,
a linha do arquivo): link não preenchido; arquivo inacessível (ex.: 404);
arquivo vazio ou fora de UTF-8; data inexistente (`31-02-2026`); linha que
parece data fora do formato (`2026-04-03`, `3-4-2026`); data repetida; data
fora da seção certa; seção diferente das três do arquivo; arquivo sem nenhuma
data. O relatório nunca é calculado com zero feriados.

**Primeiro refresh (checklist).**

1. Copiar `docs/feriados.txt` para a biblioteca do SharePoint escolhida.
2. Criar a consulta a partir do `.m` (*Nova Fonte > Consulta Nula > Editor
   Avançado*, colar o arquivo inteiro).
3. Trocar o placeholder de `SharePointFeriadosUrl` pelo link direto.
4. Credenciais, privacidade (Organizacional + Organizacional) e gateway, como
   acima.
5. Atualizar no Desktop e conferir número de linhas e totais de FAIA e FARC.
6. Publicar e acompanhar o primeiro refresh agendado no serviço.
7. Teste de manutenção: incluir no SharePoint uma data de teste num dia útil
   recente, atualizar, ver as horas no Horário TCU mudarem, apagar a data e
   atualizar de novo.

O motor do Power BI Desktop desta máquina executou o `.m` com as duas fontes
como Organizacional e o firewall ativo (arquivo servido por HTTP local). O
acesso ao SharePoint Online real, o PBIX, o gateway e o refresh no serviço
ainda dependem do ambiente.
