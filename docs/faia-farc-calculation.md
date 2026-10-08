# FAIA e FARC da Decision — como a consulta consolidada calcula cada coluna

Explicação em linguagem simples da única consulta da Decision:

```text
queries/consulta_faia_farc.sql
```

Ela devolve **uma linha por chamado**, com os dois indicadores lado a lado. Antes existiam duas consultas separadas (`consulta_faia.sql` e `consulta_farc.sql`); elas foram substituídas e não devem mais ser usadas.

Este documento é para quem precisa **entender e conferir os números**, não para quem vai mexer no SQL. Por isso ele evita detalhar tabelas temporárias e não reproduz trechos longos de código.

---

## Índice

1. [O que a consulta faz](#1-o-que-a-consulta-faz)
2. [Colunas compartilhadas](#2-colunas-compartilhadas) — inclui [Data Entrada Grupo Decision](#21-data-entrada-grupo-decision)
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
| `Item de Configuração` | IC associado ao chamado no SDM: o campo *Item de configuração* da tela do chamado. Vazio quando o chamado não tem IC |
| `Data de Abertura` | Abertura do chamado no SDM |
| `Data Entrada Grupo Decision` | Quando o chamado entrou no grupo Fornecedores - Decision — ver [seção 2.1](#21-data-entrada-grupo-decision) |
| `Data de Encerramento Total do Chamado` | Fechamento para o cliente |
| `Data de Encerramento Decision` | Quando a Decision concluiu a atuação dela. **Não é o mesmo que o fechamento do chamado** — ver [seção 9](#9-data-de-encerramento-decision) |
| `Data Captura` | Primeira ida para "Em andamento" |
| `Data Resolução` | Data de resolução registrada |
| `Indicador Reabertura` | `Sim` / `Não` |
| `Acordo Prazo`, `Acordo Qualidade`, `Justificativa` | Reservados, sempre `-` |

### 2.1 Data Entrada Grupo Decision

É o momento em que o chamado **caiu no grupo Fornecedores - Decision**. Vale a
**primeira** entrada: se o chamado saiu e voltou, a coluna continua mostrando a
primeira vez, não a reentrada.

Não se confunde com `Data Captura`, que segue a regra própria da Decision: a
primeira ida para "Em andamento", o momento em que alguém assumiu o chamado. São
marcos diferentes — um diz **de quem o chamado passou a ser**, o outro **quando
começaram a trabalhar nele**.

No período conferido, a entrada no grupo ocorreu antes ou no mesmo instante da
captura em todos os chamados. A consulta, porém, não impõe essa ordem: as duas
colunas vêm de fontes independentes, e um histórico de grupo incompleto pode
produzir um caso fora dela.

Também não se confunde com `Data de Abertura`, que é a abertura do chamado no
SDM. Quando o chamado nasce fora da Decision e é transferido depois, a entrada é
**posterior** à abertura — a diferença é justamente o tempo que ele passou em
outro grupo.

Os três casos possíveis:

| Situação | O que a coluna mostra |
|---|---|
| Chamado nasceu no grupo | A própria abertura — entrada e abertura coincidem |
| Chamado foi transferido para o grupo | A data da primeira transferência de entrada |
| Sem registro de entrada no histórico | Vazia |

A coluna é **informativa**. Nenhum tempo, meta, `nHR` ou valor de FAIA/FARC é
calculado a partir dela.

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
| `Tempo Suspenso` | Tempo em que o relógio ficou parado |
| `Tempo de Atendimento` | Base de tempo do FARC |
| `Tempo Atendimento Excedido` | Quanto passou da meta |
| `Meta Atendimento` | `Atende` ou `Não Atende` |
| `nHR_FARC` | Horas de atraso, proporcionais |
| `FARC` | `nHR_FARC` × fator do contrato |

O calendário depende da severidade: **P1 e P2 contam corrido** (24 h por dia, incluindo fim de semana e feriado); **P3, P4 e P5 contam comercial** (segunda a sexta, 08:00 às 20:00, sem feriados nem pontos facultativos do TCU). Os feriados vêm do arquivo de feriados ([feriados.txt](feriados.txt)), e não ficam no SQL: é o calendário do TCU, o mesmo da Virtual TI e da A2B, com os feriados nacionais fixos valendo todo ano e as datas móveis e pontos facultativos cadastrados por ano, conforme a Portaria do TCU.

> **Correção (2026-10-08).** O motor de status do FARC (bloco `[9.2]` do SQL) excluía o dia de feriado ou ponto facultativo também na contagem corrida, ao contrário da regra acima. Agora a corrida conta as 24 h de todos os dias, inclusive feriado e ponto facultativo; só a comercial perde fim de semana, feriado e ponto facultativo. Mudam apenas o `Tempo de Atendimento` e, quando passa da meta, o excedido, o `nHR_FARC` e o `FARC` de chamados P1/P2 com tempo ativo em feriado. As rotinas mantêm a regra própria (rotina aberta em feriado ou ponto facultativo: tempo zero).

Rotinas (checklists, produção de relatórios, documentação) usam um motor próprio, que mede o intervalo da abertura até o encerramento da Decision e **desconta os períodos suspensos**. Os demais chamados usam o motor de status, que soma apenas os intervalos em que o chamado esteve realmente ativo.

**Status ativos.** Conta-se só o tempo de posse da Decision nestes status:

| Status | `Tempo Total Decision` | `Tempo de Atendimento` (FARC) |
|---|---|---|
| "Em andamento" | conta | conta |
| "Aberto, aguarda atendimento" | conta | conta |
| "Reaberto" | conta | conta |
| "Aguarda atendimento" | conta | pausa |
| demais (Agendado, Em homologação, Aguardando fornecedor...) | pausa | pausa |

As duas listas são explícitas, e não o campo `cr_stat.hold`: o cadastro também
marca com `hold = 0` status terminais, administrativos e de problema/mudança,
que não são atendimento. "Aguarda atendimento" tem `hold = 0` e não conta no
FARC: foi avaliado e reprovado pelo impacto (em 12 meses, FARC total +11,98% e
um chamado de "Atende" para "Não Atende"; até +56 h num único chamado).

"Reaberto" conta por orientação do gerente (2026-10-06). Quando o analista encerra o chamado por engano como "Resolvido, concluído", o correto é reabrir e pôr o status certo, e esse tempo é de atendimento. O SDM grava a reabertura como evento `RO` ("Resolvido, concluído" → "Reaberto"), lido pelos dois motores.

**Ida para homologação gravada como `RE`.** O SDM costuma gravar a entrada em "Em homologação" como evento `RE` ("Em andamento" → "Em homologação"), e não como `ST`. Os dois motores leem esse evento: a partir dele o chamado está em homologação, que é pausa, e o trecho ativo anterior termina ali. No `Tempo de Atendimento`, só entra `RE` com a transição de status no texto; um `RE` sem transição não para o relógio.

- **Com `SOLN`.** O `SOLN` também pausa. Se o `RE` vem antes, o intervalo `RE` → `SOLN` é homologação e não conta. Exemplo: 1664791, rotina com `RE` em 16/12 20:08:56 e `SOLN` em 17/12 19:09:14; o `Tempo de Atendimento` vai de 33:09:15 para 10:08:57. Se os dois caem no mesmo segundo, nada muda.
- **Com `RO`/"Reaberto".** A reabertura volta a contar. Um `RE` que sai de "Reaberto" encerra o trecho reaberto e, no último ciclo, é o próprio terminal (1710057).

**`Tempo Total Decision` x `Tempo de Atendimento`.** Os dois somam só status ativos, mas terminam em pontos diferentes. O `Tempo Total Decision` vai até o encerramento da Decision ou o fechamento do chamado. O `Tempo de Atendimento` vai até o terminal do FARC: o primeiro `SOLN`, o encerramento do último ciclo quando há reabertura, ou então a `Data Resolução`, que nos chamados sem `SOLN` costuma ficar segundos depois do `RE`. Por isso, sem a leitura do `RE`, o `Tempo Total Decision` contava até o fechamento (dias), enquanto o `Tempo de Atendimento` contava, em geral, segundos ou minutos a mais.

**Último ciclo.** O `Tempo de Atendimento` acompanha todos os ciclos de atuação da Decision. Sem reabertura, termina no primeiro `SOLN`, como sempre. Quando o chamado é reaberto depois desse encerramento, o terminal passa a ser o primeiro encerramento depois da **última** reabertura: um `SOLN` ou uma entrada em "Em homologação". Sem esse encerramento, vale a `Data Resolução`; sem ela, o fechamento.

**SOLN → reabertura é pausa.** O `SOLN` encerra o trecho ativo, e o chamado fica parado até a reabertura (`RO`); "Reaberto" volta a contar. Exemplo: 1710057.

| Instante | Evento | Conta? |
|---|---|---|
| 18:26:32 | `SOLN` | até aqui conta |
| 18:26:32 → 18:27:07 | "Resolvido, concluído" | não (35 s) |
| 18:27:07 → 18:27:24 | "Reaberto" | sim (17 s) |
| 18:27:24 | `RE` → "Em homologação" | encerramento do último ciclo |

O resultado é `Tempo de Atendimento` 0:51:05 → 0:51:22 e `Tempo Total Decision` +17 s.

O `Indicador Reabertura` continua só indicando que houve reabertura; não soma tempo.

---

## 5. Os três tempos que mais confundem

São três colunas parecidas e **não intercambiáveis**:

| Coluna | O que mede | Conta o intervalo SOLN → SRVY_SENT? |
|---|---|---|
| `Tempo Total Decision` | Tempo trabalhado, já descontado o que ficou parado | **Não** |
| `Tempo Suspenso` | Tempo com o relógio parado | **Sim** |
| `Tempo de Atendimento` | Base usada para comparar com a meta do FARC | **Sim** (a partir desta versão) |

`Tempo Total Decision` continua **sem** considerar esse intervalo — isso não mudou e não deve mudar.

---

## 6. O intervalo entre SOLN e SRVY_SENT

Quando o atendente registra a solução, o SDM grava um evento **`SOLN`**. Logo depois, o sistema dispara a pesquisa de satisfação e grava um **`SRVY_SENT`**. Entre os dois passam alguns segundos.

O problema: o marco de encerramento do FARC é o **próprio `SOLN`** (o do último ciclo, quando há reabertura). Ou seja, o envio da pesquisa acontece **depois** do fim da janela medida, e por isso esses segundos não entravam no `Tempo de Atendimento` — embora já entrassem no `Tempo Suspenso`.

A partir desta versão:

```text
Tempo de Atendimento anterior
+ intervalo entre SOLN e SRVY_SENT
= novo Tempo de Atendimento
```

**A regra é geral.** Ela vale para qualquer chamado que tenha um par válido, e não depende do número do chamado. Não existe nenhum tratamento específico por SDM na consulta.

**Quando não há par válido, soma-se zero.** É o caso, por exemplo, de chamados encerrados sem `SOLN`, ou sem pesquisa enviada. O chamado não é excluído nem recebe valor estimado: simplesmente não ganha nada.

**Como a dupla contagem é evitada.** O pareamento segue exatamente a mesma regra que já alimentava o `Tempo Suspenso`:

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
`logs/Ciclo 30_05 - 29_06/servidores/request/logs.xlsx`:

| Marco | Valor |
|---|---|
| Data de Abertura (`INIT`) | 01/06/2026 10:00:00 |
| Data de Encerramento Decision (`SOLN`) | 01/06/2026 10:28:30 |
| Envio da pesquisa (`SRVY_SENT`) | 01/06/2026 10:28:33 |
| Intervalo entre os dois | **3 segundos** |
| `Tempo Suspenso` | 0:00:03 |

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
Tempo Suspenso
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
Tempo Suspenso
Tempo Primeiro Atendimento
Tempo de Atendimento
FAIA
FARC
nHR_FAIA
nHR_FARC
```

Detalhes de arquitetura, período e desempenho da versão usada no painel estão em [powerbi-query.md](../powerbi/powerbi-query.md).
