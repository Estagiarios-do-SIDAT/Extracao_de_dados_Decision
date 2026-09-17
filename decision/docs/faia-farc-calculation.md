# FAIA e FARC da Decision — como a consulta consolidada calcula cada coluna

Explicação em linguagem simples da única consulta da Decision:

```text
decision/queries/consulta_faia_farc.sql
```

Ela devolve **uma linha por chamado**, com os dois indicadores lado a lado. Antes existiam duas consultas separadas (`consulta_faia.sql` e `consulta_farc.sql`); elas foram substituídas e não devem mais ser usadas.

Este documento é para quem precisa **entender e conferir os números**, não para quem vai mexer no SQL. Por isso ele evita detalhar tabelas temporárias e não reproduz trechos longos de código.

---

## Índice

1. [O que a consulta faz](#1-o-que-a-consulta-faz)
2. [Colunas compartilhadas](#2-colunas-compartilhadas)
3. [Colunas do FAIA](#3-colunas-do-faia)
4. [Colunas do FARC](#4-colunas-do-farc)
5. [Os três tempos que mais confundem](#5-os-três-tempos-que-mais-confundem)
6. [O intervalo entre SOLN e SRVY_SENT](#6-o-intervalo-entre-soln-e-srvy_sent)
7. [Exemplo](#7-exemplo)
8. [O que não mudou](#8-o-que-não-mudou)
9. [`Data de Encerramento Decision`](#9-data-de-encerramento-decision)

---

## 1. O que a consulta faz

O **FAIA** mede o **começo**: quanto tempo passou até alguém pegar o chamado depois que ele entrou na Decision.

O **FARC** mede a **duração do trabalho**: quanto tempo o chamado ficou efetivamente em atendimento até ser resolvido.

Um chamado pode atender o FAIA (alguém pegou em 5 minutos) e estourar o FARC (só ficou pronto três dias depois), e vice-versa. São indicadores independentes, com metas e fatores de penalidade diferentes.

Quando o tempo passa da meta, a consulta calcula o excedente, o `nHR` correspondente e o valor final do indicador. O `nHR` é **proporcional**: uma hora e meia de atraso vira `1,50`, nunca `2`.

---

## 2. Colunas compartilhadas

São os dados do chamado. Aparecem uma vez só, mesmo quando os dois indicadores usariam a mesma informação.

| Coluna | O que é |
|---|---|
| `SDM` | Número do chamado |
| `Tipo Chamado` | Incidente, Solicitação, Problema ou Mudança |
| `Severidade` | De `1 - Máxima` a `5 - Mínima` |
| `Status` | Status final |
| `Categoria` | Categoria do SDM (`Decision.*`) |
| `Responsável Abertura` / `Responsável Atendimento` | Quem abriu e quem atendeu |
| `Resumo` | Título do chamado |
| `Data de Abertura` | Abertura do chamado no SDM |
| `Data de Encerramento Total do Chamado` | Fechamento para o cliente |
| `Data de Encerramento Decision` | Quando a Decision concluiu a atuação dela. **Não é o mesmo que o fechamento do chamado** — ver [seção 9](#9-data-de-encerramento-decision) |
| `Data Captura` | Primeira ida para "Em andamento" |
| `Data Resolução` | Data de resolução registrada |
| `Indicador Reabertura` | `Sim` / `Não` |
| `Acordo Prazo`, `Acordo Qualidade`, `Justificativa` | Reservados, sempre `-` |

---

## 3. Colunas do FAIA

| Coluna | O que é |
|---|---|
| `Tempo Primeiro Atendimento` | Da entrada na Decision até a captura |
| `Primeiro Atendimento Excedido` | Quanto passou da meta |
| `Meta Primeiro Atendimento` | `Atende` ou `Não Atende` |
| `nHR_FAIA` | Horas de atraso, proporcionais |
| `FAIA` | `nHR_FAIA` × fator do contrato |

A contagem **não começa na abertura do chamado**, e sim quando ele entra na posse do grupo Fornecedores - Decision. Se ele já nasceu no grupo, aí sim vale a abertura.

---

## 4. Colunas do FARC

| Coluna | O que é |
|---|---|
| `Tempo Total Decision` | Tempo trabalhado, líquido |
| `Tempo suspenso` | Tempo em que o relógio ficou parado |
| `Tempo de Atendimento` | Base de tempo do FARC |
| `Tempo Atendimento Excedido` | Quanto passou da meta |
| `Meta Atendimento` | `Atende` ou `Não Atende` |
| `nHR_FARC` | Horas de atraso, proporcionais |
| `FARC` | `nHR_FARC` × fator do contrato |

O calendário depende da severidade: **P1 e P2 contam corrido** (24 h por dia, incluindo fim de semana e feriado); **P3, P4 e P5 contam comercial** (segunda a sexta, 08:00 às 20:00, sem feriados nem pontos facultativos do TCU).

Rotinas (checklists, produção de relatórios, documentação) usam um motor próprio, que mede o intervalo da abertura até o encerramento da Decision e **desconta os períodos suspensos**. Os demais chamados usam o motor de status, que soma apenas os intervalos em que o chamado esteve realmente ativo.

---

## 5. Os três tempos que mais confundem

São três colunas parecidas e **não intercambiáveis**:

| Coluna | O que mede | Conta o intervalo SOLN → SRVY_SENT? |
|---|---|---|
| `Tempo Total Decision` | Tempo trabalhado, já descontado o que ficou parado | **Não** |
| `Tempo suspenso` | Tempo com o relógio parado | **Sim** |
| `Tempo de Atendimento` | Base usada para comparar com a meta do FARC | **Sim** (a partir desta versão) |

`Tempo Total Decision` continua **sem** considerar esse intervalo — isso não mudou e não deve mudar.

---

## 6. O intervalo entre SOLN e SRVY_SENT

Quando o atendente registra a solução, o SDM grava um evento **`SOLN`**. Logo depois, o sistema dispara a pesquisa de satisfação e grava um **`SRVY_SENT`**. Entre os dois passam alguns segundos.

O problema: o marco de encerramento do FARC é o **próprio `SOLN`**. Ou seja, o envio da pesquisa acontece **depois** do fim da janela medida, e por isso esses segundos não entravam no `Tempo de Atendimento` — embora já entrassem no `Tempo suspenso`.

A partir desta versão:

```text
Tempo de Atendimento anterior
+ intervalo entre SOLN e SRVY_SENT
= novo Tempo de Atendimento
```

**A regra é geral.** Ela vale para qualquer chamado que tenha um par válido, e não depende do número do chamado. Não existe nenhum tratamento específico por SDM na consulta.

**Quando não há par válido, soma-se zero.** É o caso, por exemplo, de chamados encerrados sem `SOLN`, ou sem pesquisa enviada. O chamado não é excluído nem recebe valor estimado: simplesmente não ganha nada.

**Como a dupla contagem é evitada.** O pareamento segue exatamente a mesma regra que já alimentava o `Tempo suspenso`:

- cada `SOLN` é considerado uma única vez;
- para cada `SOLN`, vale apenas o **primeiro** `SRVY_SENT` posterior a ele;
- esse `SRVY_SENT` precisa vir **antes do próximo `SOLN`**, o que impede que dois pares se sobreponham;
- só entram pares em que o `SRVY_SENT` é **posterior** ao `SOLN`, o que descarta intervalo negativo;
- o total é agregado **por chamado**, então o número de linhas do resultado não muda.

Reabertura não quebra a regra: um chamado reaberto tem mais de um `SOLN`, e cada ciclo é pareado com a sua própria pesquisa, sem misturar.

---

## 7. Exemplo

O chamado **1705403** (`Decision.Servidores. Realizar Checklist/ HealthCheck`, ciclo de 30/05/2026 a 29/06/2026) é uma rotina simples: abre, é trabalhada e encerra no mesmo dia, sem nenhum status de suspensão.

Os marcos abaixo vêm do log de eventos do próprio chamado, em
`decision/logs/Ciclo 30_05 - 29_06/servidores/request/logs.xlsx`:

| Marco | Valor |
|---|---|
| Data de Abertura (`INIT`) | 01/06/2026 10:00:00 |
| Data de Encerramento Decision (`SOLN`) | 01/06/2026 10:28:30 |
| Envio da pesquisa (`SRVY_SENT`) | 01/06/2026 10:28:33 |
| Intervalo entre os dois | **3 segundos** |
| `Tempo suspenso` | 0:00:03 |

O chamado tem um único `SOLN` e um único `SRVY_SENT`, então existe exatamente um par válido.

```text
Tempo de Atendimento anterior ...... 0:28:30
intervalo SOLN -> SRVY_SENT ........ 0:00:03
novo Tempo de Atendimento .......... 0:28:33
```

O intervalo desse chamado é de 3 segundos, mas **isso não é uma constante**: cada chamado tem o seu, e alguns não têm nenhum.

---

## 8. O que não mudou

A correção foi isolada de propósito. Só o `Tempo de Atendimento` mudou.

Continuam **exatamente iguais**:

```text
Tempo suspenso
Tempo Total Decision
Tempo Atendimento Excedido
Meta Atendimento
nHR_FARC
FARC
FAIA
nHR_FAIA
```

Em particular, o excedente do FARC continua sendo calculado a partir do tempo medido pelos motores de rotina e de status, **sem** os segundos da pesquisa. Isso é deliberado: o objetivo era corrigir a coluna exibida, sem alterar a apuração da penalidade.

Uma consequência prática que vale conhecer: em um chamado que esteja exatamente no limite da meta, o `Tempo de Atendimento` exibido pode ficar alguns segundos acima dela enquanto o `Meta Atendimento` ainda diz `Atende`. Isso é esperado, e não um erro de cálculo.

Também não mudaram a ordem das colunas, a quantidade de colunas, a quantidade de linhas nem qualquer regra de terminal, suspensão, calendário, posse ou reposse.

---

## 9. `Data de Encerramento Decision`

### Não é o fechamento do chamado

```text
Data de Encerramento Total do Chamado  ->  quando o chamado fechou no SDM
Data de Encerramento Decision          ->  quando a Decision concluiu a atuação dela
```

São coisas diferentes. Podem ter valores diferentes, e uma pode estar preenchida enquanto a outra não.

O marco da Decision é a **entrada em "Em homologação"**: o momento em que a equipe terminou o trabalho e entregou o chamado para homologação.

### Quando o marco é gravado de outra forma

Alguns chamados registram essa entrada com um tipo de evento diferente do usual. Para não perder o marco, existe um **fallback**:

```text
Se a regra original já encontrou um encerramento válido:
    preserva exatamente o valor.

Se a regra original resultaria em NULL:
    aceita um evento RE cuja transição tenha como DESTINO um status
    classificado como homologação da Decision.
```

O fallback usa **as mesmas regras** do marco original — mesmo catálogo de status, mesma janela de abertura/fechamento, mesma exigência de posse da Decision. Havendo mais de um evento válido, vale o **último**. Nenhum valor já preenchido é sobrescrito.

Um detalhe que confunde: um evento que **menciona** "Em homologação" não é necessariamente uma entrada. O fechamento `de 'Em homologação' para 'Resolvido, concluído'` cita a expressão, mas é uma **saída** — o que vale é o **destino** da transição.

### `NULL` é um valor legítimo

> Um chamado pode estar **fechado no sistema** e ainda ter `Data de Encerramento Decision` vazia.

Isso acontece quando **não houve conclusão da atividade pela Decision**. O caso típico são checklists e rotinas semanais que **não foram executados** por causa de um feriado ou ponto facultativo: o chamado é encerrado como *"Não resolvido, fechado"*, sem nunca passar por "Em homologação".

Nesses casos o vazio está **certo**. Preencher a coluna com o fechamento do chamado, com a `Data Resolução` ou com o evento de encerramento passaria a afirmar que a Decision concluiu uma atividade que os próprios logs registram como não executada.

Um vazio nessa coluna é **informação**, não falha de dados.

### O que essa regra NÃO afeta

A correção do fallback mexe **apenas** nesta coluna. Continuam idênticos:

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

Detalhes de arquitetura, período e desempenho da versão usada no painel estão em [powerbi-query.md](powerbi-query.md).
