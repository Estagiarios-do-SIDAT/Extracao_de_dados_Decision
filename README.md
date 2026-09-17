# Extração de dados — Decision

Repositório com consultas SQL, documentações e planilhas de validação usadas para apurar os indicadores **FAIA** e **FARC** da **Decision** a partir da base do **CA Service Desk Manager**.

O objetivo do projeto é manter, em um só lugar, as consultas usadas na apuração dos indicadores, a explicação das regras aplicadas e os arquivos de conferência contra os relatórios recebidos.

## Estrutura do repositório

```text
.
├── decision/
│   ├── queries/
│   │   └── consulta_faia_farc.sql        FAIA e FARC juntos, uma linha por chamado
│   ├── powerbi/
│   │   └── consulta_faia_farc_power_bi.sql   fonte do painel, seis ciclos dinâmicos
│   ├── docs/
│   │   ├── faia-farc-calculation.md      como cada coluna é calculada
│   │   └── powerbi-query.md              a versão do painel: período, saída e desempenho
│   ├── analysis/
│   │   └── planilhas de comparação por ciclo
│   └── logs/
│       └── logs consolidados por ciclo e categoria
│
├── docs/
│   └── project-context/
│       └── FAIA-FARC-HISTORICO-CONTEXTO-MESTRE.md   histórico cumulativo do projeto
│
├── support/
│   ├── consulta_logs_chamados_listados.sql
│   ├── consulta_status_chamados.sql
│   ├── consulta_status_hold.sql
│   └── consulta_tipos_chamado.sql
│
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

A consulta calcula o tempo considerado válido para o atendimento do chamado e compara esse total com a meta aplicável. Quando há extrapolação, calcula:

- tempo excedido;
- `nHR_FARC`;
- valor final do FARC.

## Consultas principais

### Decision

| Arquivo | Finalidade |
|---|---|
| `decision/queries/consulta_faia_farc.sql` | Calcula o FAIA **e** o FARC da Decision numa única execução |

É uma consulta só, com **uma linha por chamado**. A ordem das colunas é:

1. dados compartilhados e colunas do FAIA;
2. colunas específicas do FAIA;
3. somente as colunas exclusivas do FARC.

Quando os dois indicadores representavam o **mesmo conceito** (data de abertura, data de captura, encerramento da Decision, Tempo Total Decision, Tempo suspenso), ficou a **versão do FAIA** — ela é a fonte de verdade para conceitos compartilhados. As colunas próprias do cálculo do FARC (`Tempo de Atendimento`, `Tempo Atendimento Excedido`, `Meta Atendimento`, `nHR_FARC`, `FARC` e `Data Resolução`) continuam preservadas.

A Decision tem **duas** consultas, com a mesma regra de cálculo e finalidades diferentes:

| Arquivo | Finalidade | Período |
|---|---|---|
| [`decision/queries/consulta_faia_farc.sql`](decision/queries/consulta_faia_farc.sql) | Execução e análise pontual. É a **referência funcional** | Digitado à mão |
| [`decision/powerbi/consulta_faia_farc_power_bi.sql`](decision/powerbi/consulta_faia_farc_power_bi.sql) | Fonte do painel | **Automático** |

A versão do Power BI carrega sempre os **seis últimos ciclos completos** — o ciclo vai do dia 24 ao dia 23 do mês seguinte, e o **ciclo em andamento fica de fora**. Não há data para editar: a janela é recalculada a cada atualização do painel.

A documentação fica em `decision/docs/`:

| Documento | O que explica |
|---|---|
| [`decision/docs/faia-farc-calculation.md`](decision/docs/faia-farc-calculation.md) | Como cada coluna é calculada, em linguagem simples |
| [`decision/docs/powerbi-query.md`](decision/docs/powerbi-query.md) | A versão do painel: arquitetura, janela de seis ciclos, desempenho e as particularidades da coluna `Data de Encerramento Decision` |

> Uma nota que evita confusão frequente: `Data de Encerramento Decision` **não é** o fechamento do chamado. Ela marca quando a Decision concluiu a atuação dela, e fica **vazia** quando não houve conclusão — por exemplo, numa rotina que não foi executada por causa de ponto facultativo. Isso é explicado em [`decision/docs/powerbi-query.md`](decision/docs/powerbi-query.md#8-data-de-encerramento-decision).

As planilhas em `decision/analysis/` guardam as comparações feitas por ciclo e por frente de atendimento.

## Consultas de apoio

A pasta `support/` contém consultas auxiliares usadas durante análise e depuração.

| Arquivo | Uso |
|---|---|
| `support/consulta_logs_chamados_listados.sql` | Lista todos os logs dos chamados informados |
| `support/consulta_status_chamados.sql` | Lista os status cadastrados no SDM |
| `support/consulta_status_hold.sql` | Mostra cada status e o flag `cr_stat.hold`, que indica se ele para o relógio do SLA |
| `support/consulta_tipos_chamado.sql` | Lista os tipos de chamado e suas quantidades |

Essas consultas não calculam FAIA nem FARC. Elas servem para investigar chamados, conferir códigos e entender registros da base.

## Como usar as consultas

1. Abra o arquivo SQL do fornecedor e indicador desejado.
2. Ajuste o período de apuração nos parâmetros de data.
3. Mantenha `@MostrarDiagnostico = 0` para uso normal no relatório.
4. Execute a consulta na base `mdb`.
5. Exporte o resultado.
6. Compare com os arquivos recebidos do fornecedor.
7. Salve a análise na pasta `analysis/` correspondente.

Quando houver divergência, use `@MostrarDiagnostico = 1` para retornar tabelas intermediárias de conferência.

## Parâmetros comuns

As consultas normalmente possuem parâmetros como:

```sql
DECLARE @InicioBrasil datetime2(0)
DECLARE @FimBrasil    datetime2(0)
DECLARE @MostrarDiagnostico bit = 0
```

- `@InicioBrasil` e `@FimBrasil` definem o período analisado.
- `@MostrarDiagnostico = 0` retorna apenas o resultado final.
- `@MostrarDiagnostico = 1` retorna informações extras para investigação.

## Fluxo de validação

O fluxo esperado é:

```text
consulta SQL → resultado exportado → comparação com relatório do fornecedor → planilha em analysis/ → ajuste ou confirmação da regra
```

As planilhas de análise servem para registrar se os resultados da consulta bateram com os arquivos usados como referência.

## Convenções do projeto

- `decision/queries/`: consultas executáveis do indicador da Decision.
- `decision/docs/`: explicações das regras e dos cálculos.
- `decision/analysis/`: arquivos de comparação e validação.
- `support/`: consultas auxiliares.

Ao alterar uma regra de cálculo, atualize também a documentação correspondente em `decision/docs/`.

Ao validar um novo ciclo, salve a planilha na pasta `decision/analysis/`.
