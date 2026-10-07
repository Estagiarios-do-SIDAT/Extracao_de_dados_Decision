# Extração de dados — Decision

Repositório com consultas SQL, documentações e planilhas de validação usadas para apurar os indicadores **FAIA** e **FARC** da **Decision** a partir da base do **CA Service Desk Manager**.

O objetivo do projeto é manter, em um só lugar, as consultas usadas na apuração dos indicadores, a explicação das regras aplicadas e os arquivos de conferência contra os relatórios recebidos.

Este repositório atende **somente a Decision**. COI e A2B/Protect4 têm repositórios próprios (`Extracao_de_dados_COI` e `Extracao_de_dados_A2B`) e nada deles vive aqui. A antiga pasta `Queries`, onde os três núcleos conviviam, **não é mais fonte operacional** — desde 2026-09-18 a fonte oficial da Decision é este repositório.

## Estrutura do repositório

```text
.
├── queries/
│   ├── consulta_faia_farc.sql              consulta de referência: FAIA e FARC, uma linha por chamado
│   └── consulta_faia_farc_painel.sql       consulta de referência do painel (fonte do .m; últimos 12 meses)
├── powerbi/
│   ├── consulta_faia_farc_power_bi.m       A consulta do painel (Power Query M, única): feriados do SharePoint + SQL
│   ├── powerbi-query.md                    documentação do painel: período, manutenção, saída, SharePoint
│   └── documentacao-powerbi-decision.html  leitura dentro do painel (visual HTML Content)
├── tools/
│   ├── executar_consulta.ps1               executa queries/ com os feriados do arquivo
│   ├── gerar_powerbi_m.ps1                 gera powerbi/*.m a partir do SQL de referência do painel
│   ├── verificar_feriados.ps1              valida o arquivo e a sincronia dos repositórios
│   └── feriados.ps1                        leitura e validação do arquivo (uso interno)
├── docs/
│   ├── faia-farc-calculation.md            como cada coluna é calculada
│   └── feriados.txt                        calendário de feriados e pontos facultativos (igual na Virtual TI, Decision e A2B)
├── analysis/
│   └── planilhas de comparação por ciclo de validação
├── logs/
│   └── logs consolidados por ciclo de validação e categoria
├── project-context/
│   └── DECISION-HISTORICO-CONTEXTO-MESTRE.md   Histórico Mestre da Decision
├── support/
│   ├── consulta_logs_chamados_listados.sql
│   ├── consulta_status_chamados.sql
│   ├── consulta_status_hold.sql
│   └── consulta_tipos_chamado.sql
├── README.md
└── .git/
```

> **Nota histórica.** Até 07/2026 a Decision tinha duas consultas separadas (`consulta_faia.sql` e `consulta_farc.sql`). Elas foram **substituídas** pela consulta única `consulta_faia_farc.sql` e não devem mais ser usadas como referência. O histórico delas permanece no Git.

## O que é FAIA

O **FAIA** mede o prazo de **primeiro atendimento**.

Em termos práticos, a consulta identifica quando o chamado passou para o fornecedor e quando ocorreu o primeiro andamento do atendimento. Depois compara esse tempo com a meta definida para a severidade do chamado.

Quando o tempo passa da meta, a consulta calcula:

- tempo excedido;
- `nHR_FAIA`;
- valor final do FAIA.

## O que é FARC

O **FARC** mede o prazo de **atendimento/resolução**.

A consulta calcula o tempo considerado válido para o atendimento do chamado e compara esse total com a meta aplicável. Contam só os status ativos ("Em andamento", "Aberto, aguarda atendimento" e "Reaberto") em posse da Decision; a ida para homologação (gravada como `ST` ou `RE`) e o registro da solução (`SOLN`) param o relógio. As regras estão em [`docs/faia-farc-calculation.md`](docs/faia-farc-calculation.md). Quando há extrapolação, calcula:

- tempo excedido;
- `nHR_FARC`;
- valor final do FARC.

## Consultas principais

### Decision

| Arquivo | Finalidade |
|---|---|
| `queries/consulta_faia_farc.sql` | Calcula o FAIA **e** o FARC da Decision numa única execução |

É uma consulta só, com **uma linha por chamado**. A ordem das colunas é:

1. dados compartilhados e colunas do FAIA;
2. colunas específicas do FAIA;
3. somente as colunas exclusivas do FARC.

Quando os dois indicadores representavam o **mesmo conceito** (data de abertura, data de captura, encerramento da Decision, Tempo Total Decision, Tempo suspenso), ficou a **versão do FAIA** — ela é a fonte de verdade para conceitos compartilhados. As colunas próprias do cálculo do FARC (`Tempo de Atendimento`, `Tempo Atendimento Excedido`, `Meta Atendimento`, `nHR_FARC`, `FARC` e `Data Resolução`) continuam preservadas.

A Decision tem **duas** consultas, com a mesma regra de cálculo e finalidades diferentes:

| Arquivo | Finalidade | Período |
|---|---|---|
| [`queries/consulta_faia_farc.sql`](queries/consulta_faia_farc.sql) | Execução e análise pontual. É a **referência funcional** | Digitado à mão |
| [`queries/consulta_faia_farc_painel.sql`](queries/consulta_faia_farc_painel.sql) | Consulta de referência do painel: o SQL que a consulta do Power BI executa. Fonte do `.m` e usada em testes | **Automático** |

A **única** consulta do Power BI é [`powerbi/consulta_faia_farc_power_bi.m`](powerbi/consulta_faia_farc_power_bi.m), gerada de `queries/consulta_faia_farc_painel.sql` pelo `tools/gerar_powerbi_m.ps1`. O SQL não se cola no Power BI. Para trocar o endereço do SharePoint, altere apenas `SharePointFeriadosUrl`, no topo do `.m` (link real ainda **pendente**).

A versão do Power BI carrega sempre os **últimos 12 meses até hoje**, pela data de encerramento do chamado. Não há data para editar: a janela é recalculada a cada atualização do painel. Para aumentar ou reduzir a cobertura, altera-se um único número — `@CoberturaMeses`, na primeira instrução do SQL. O passo a passo, inclusive para atualizar feriados, está em [`powerbi/powerbi-query.md`](powerbi/powerbi-query.md#5-período-da-consulta).

O período da Decision é uma **janela móvel de meses**, e não um ciclo de faturamento com dia fixo de virada.

A documentação fica em `docs/` (regras e cálculo) e em `powerbi/` (painel):

| Documento | O que explica |
|---|---|
| [`docs/faia-farc-calculation.md`](docs/faia-farc-calculation.md) | Como cada coluna é calculada, em linguagem simples |
| [`docs/feriados.txt`](docs/feriados.txt) | O calendário de feriados e pontos facultativos do TCU, em texto simples (`DD-MM` fixos, `DD-MM-AAAA` por ano), igual na Virtual TI, Decision e A2B |
| [`powerbi/powerbi-query.md`](powerbi/powerbi-query.md) | A versão do painel: arquitetura, janela móvel, manutenção de cobertura e de feriados, desempenho e as particularidades da coluna `Data de Encerramento Decision` |
| [`powerbi/documentacao-powerbi-decision.html`](powerbi/documentacao-powerbi-decision.html) | A mesma documentação do painel, em HTML, para exibir no visual **HTML Content** do Power BI. Deriva de `powerbi-query.md` e não pode contradizê-lo |

> Uma nota que evita confusão frequente: `Data de Encerramento Decision` **não é** o fechamento do chamado. Ela marca quando a Decision concluiu a atuação dela, e fica **vazia** quando não houve conclusão — por exemplo, numa rotina que não foi executada por causa de ponto facultativo. Isso é explicado em [`powerbi/powerbi-query.md`](powerbi/powerbi-query.md#8-data-de-encerramento-decision).

As planilhas em `analysis/` guardam as comparações feitas por ciclo e por frente de atendimento.

## Consultas de apoio

A pasta `support/` contém consultas auxiliares usadas durante análise e depuração.

| Arquivo | Uso |
|---|---|
| `support/consulta_logs_chamados_listados.sql` | Lista todos os logs dos chamados informados |
| `support/consulta_status_chamados.sql` | Lista os status cadastrados no SDM |
| `support/consulta_status_hold.sql` | Mostra cada status e o flag `cr_stat.hold`, que indica se ele para o relógio do SLA. Os cálculos não usam esse flag: os status que contam são listas explícitas (ver [cálculo do FAIA e do FARC](docs/faia-farc-calculation.md)) |
| `support/consulta_tipos_chamado.sql` | Lista os tipos de chamado e suas quantidades |

Essas consultas não calculam FAIA nem FARC. Elas servem para investigar chamados, conferir códigos e entender registros da base.

## Como usar as consultas

1. Abra o arquivo SQL do fornecedor e indicador desejado.
2. Ajuste o período de apuração nos parâmetros de data.
3. Mantenha `@MostrarDiagnostico = 0` para uso normal no relatório.
4. Execute pelo script, que lê os feriados de `docs/feriados.txt` e já grava
   o resultado em CSV:
   `.\tools\executar_consulta.ps1 -Consulta .\queries\consulta_faia_farc.sql -Saida C:\temp\decision`
   (para usar o SSMS: `-GerarSql C:\temp\decision_ssms.sql` gera uma cópia com
   os feriados declarados). Aberto direto no SSMS, sem o script, o arquivo falha
   com *Must declare the scalar variable "@Feriados"*.
5. Abra o resultado exportado.
6. Compare com os arquivos recebidos do fornecedor.
7. Salve a análise na pasta `analysis/` correspondente.

Quando houver divergência, use `@MostrarDiagnostico = 1` para retornar tabelas intermediárias de conferência.

## Parâmetros comuns

**Consulta manual** (`queries/consulta_faia_farc.sql`):

```sql
DECLARE @InicioBrasil datetime2(0) = '2026-03-01 00:00:00';  -- inclusivo
DECLARE @FimBrasil    datetime2(0) = '2026-03-31 23:59:59';  -- INCLUSIVO
DECLARE @MostrarDiagnostico bit = 0
```

- `@InicioBrasil` e `@FimBrasil` definem o período, pela data de encerramento. Nesta consulta o fim é **inclusivo** (`<=`), por isso termina em `23:59:59`.
- `@MostrarDiagnostico = 0` retorna apenas o resultado final; `1` retorna informações extras para investigação.
- `@ResultadoTudo`, `@G1`, `@G2`, `@SAN`, `@Servidores`, `@LibQuantum` escolhem quais janelas de resultado aparecem.

**Consulta do Power BI** (`powerbi/consulta_faia_farc_power_bi.m`, que executa `queries/consulta_faia_farc_painel.sql`):

- `@CoberturaMeses` — cobertura da janela em meses, padrão `12`. É o único parâmetro de período.
- Feriados e pontos facultativos: vêm do **arquivo de feriados**, e não do SQL. No painel, o `.m` lê o `feriados.txt` no SharePoint a cada atualização e o envia ao SQL no parâmetro `@Feriados`; nas consultas de `queries/`, o `tools/executar_consulta.ps1` faz o mesmo com `docs/feriados.txt`. Para incluir um feriado basta editar o arquivo no SharePoint e salvar: não se muda o SQL nem se republica o relatório. As datas vêm **somente** das portarias do TCU que definem o expediente de cada ano e das que as alteram. Regras de preenchimento no próprio [`docs/feriados.txt`](docs/feriados.txt); SharePoint, privacidade e gateway em [`powerbi/powerbi-query.md`](powerbi/powerbi-query.md#14-feriados-e-sharepoint).

## Fluxo de validação

O fluxo esperado é:

```text
consulta SQL → resultado exportado → comparação com relatório do fornecedor → planilha em analysis/ → ajuste ou confirmação da regra
```

As planilhas de análise servem para registrar se os resultados da consulta bateram com os arquivos usados como referência.

## Convenções do projeto

- `queries/`: consultas de referência da Decision (a manual e a do painel).
- `powerbi/`: a consulta do painel (`.m`) e a documentação do painel, inclusive a versão HTML.
- `docs/`: explicações das regras e dos cálculos, e o calendário `feriados.txt`.
- `analysis/` e `logs/`: arquivos de comparação e validação.
- `project-context/`: Histórico Mestre da Decision.
- `support/`: consultas auxiliares.

Ao alterar uma regra de cálculo, atualize também a documentação correspondente em `docs/` e `powerbi/`, e gere o `.m` de novo.

Ao validar um novo ciclo, salve a planilha na pasta `analysis/`. Os "ciclos" das pastas de análise (`Ciclo 30_04 - 29_05`, …) são os períodos de validação usados pela Decision, do dia 30 ao dia 29, e são independentes da janela móvel que alimenta o painel.

## Histórico Mestre

O histórico do projeto fica em
[`project-context/DECISION-HISTORICO-CONTEXTO-MESTRE.md`](project-context/DECISION-HISTORICO-CONTEXTO-MESTRE.md).

- Ele é **append-only**: cada intervenção vira uma seção nova, e seções antigas não são reescritas.
- Trabalhos da Decision atualizam **somente** este histórico. COI e A2B mantêm o seu, nos respectivos repositórios.
- As seções anteriores à separação dos repositórios foram herdadas do documento compartilhado da época de `Queries` e contêm registros de COI e Protect4. Elas são mantidas como **legado histórico**, sem reescrita. Caminhos citados nelas (`decision/…`, `docs/project-context/`, …) descrevem a estrutura da época.
- O arquivo se chamava `FAIA-FARC-HISTORICO-CONTEXTO-MESTRE.md`, nome herdado do documento compartilhado; foi renomeado em 2026-09-18.
- Os comentários de cabeçalho das consultas ainda citam `decision/queries/…`. Não foram alterados para que os SQL continuem byte a byte iguais aos publicados; hoje esses arquivos ficam em `queries/` e `powerbi/`.
