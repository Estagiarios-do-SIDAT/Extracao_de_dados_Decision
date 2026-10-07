USE mdb;
SET NOCOUNT ON;
SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

-- =============================================================================
-- PARAMETRO EDITAVEL  (no Power BI: Editor Avancado da consulta, no inicio do
-- texto SqlTexto; no repositorio: altere aqui e gere de novo powerbi/consulta_faia_farc_power_bi.m)
--
--   Cobertura da janela, em MESES, contados para tras a partir de HOJE.
--   Padrao: 12. Exemplos: 6, 18, 24.
--
--   E o unico numero que precisa mudar para aumentar ou reduzir o periodo.
--   Nenhuma regra de negocio depende dele. Detalhes no bloco [JANELA DINAMICA].
-- =============================================================================
DECLARE @CoberturaMeses int = 12;

/*
================================================================================
VERSAO POWER BI DA CONSULTA CONSOLIDADA FAIA + FARC - DECISION
================================================================================

Uso:
  - Power BI Desktop
  - Conector: SQL Server
  - Banco de dados: mdb
  - Modo: Importacao
  - NAO colar este arquivo em "Instrucao SQL": a consulta do relatorio e
    powerbi/consulta_faia_farc_power_bi.m (Consulta Nula > Editor Avancado), que le os
    feriados do SharePoint e envia o parametro @Feriados a este SQL.
  - "Adicionar colunas de relacao": desmarcado

Origem: decision/queries/consulta_faia_farc.sql (consulta consolidada vigente).

Este arquivo NAO recalcula nada. Todo o motor - FAIA, FARC, motores de rotina e
de status, suspensoes, calendarios, feriados, pontos facultativos, terminais,
posse/reposse, pareamento SOLN -> SRVY_SENT, Tempo Suspenso, Tempo Total
Decision e o Tempo de Atendimento ja corrigido - e byte a byte identico ao da
consulta manual. Diferem apenas TRES pontos, todos de periodo/saida:

  1) o periodo deixa de ser digitado e passa a ser a janela movel dos ultimos
     @CoberturaMeses meses ate hoje (bloco [JANELA DINAMICA] logo abaixo);
  2) o filtro de close_date em [1] passa a usar intervalo SEMIABERTO
     (>= inicio, < fim exclusivo) no lugar do antigo <= 23:59:59;
  3) a secao [11] deixa de ter janelas opcionais por categoria e o bloco de
     diagnostico [12] nao existe: sai UM UNICO result set.

Periodo:
  - Janela MOVEL: os ultimos @CoberturaMeses meses ate HOJE. Padrao 12 meses.
  - Inicio INCLUSIVO, fim EXCLUSIVO em amanha 00:00 - assim o dia corrente
    entra inteiro e nenhum registro de hoje se perde.
  - Para mudar a cobertura basta alterar @CoberturaMeses. Nenhuma regra de
    negocio depende desse numero.
  - Nao existe data fixa neste arquivo: nada precisa ser editado a cada mes.
  - O ciclo 24-24 que existia aqui ate 2026-09-18 era regra da Protect4/A2B,
    trazida junto com o modelo de janela daquele nucleo. A Decision nao tem
    ciclo de faturamento 24-24 e nao deve voltar a te-lo.

Saida:
  - UM UNICO result set, uma linha por chamado (SDM).
  - FAIA e FARC no mesmo resultado, com as MESMAS colunas, na MESMA ordem e com
    os MESMOS aliases da consulta consolidada.
  - Sem filtro de categoria: o recorte por G1, G2, SAN, Servidores ou LibQuantum
    e feito no Power BI pela coluna [Categoria], que ja vem no resultado.
  - Nenhum bloco de diagnostico.

Temporarias: mantem o sufixo _DEC da consulta manual, DE PROPOSITO. O esquema
de cada temporaria e identico ao da consulta manual, entao nao ha o risco de
Msg 207 descrito na secao [NOMES EXCLUSIVOS DE TEMPORARIA] abaixo - esse risco
vem de tabela de mesmo nome com esquema DIFERENTE. Manter os nomes tambem faz
com que um diff entre este arquivo e a consulta manual mostre apenas os tres
pontos listados acima, que e o que mantem os dois em sincronia ao longo do
tempo.

Somente leitura. Batch unico. Nao existe GO neste arquivo.
================================================================================
*/


--------------------------------------------------------------------------------
-- Consulta CONSOLIDADA FAIA + FARC - Decision
--
-- Substitui, em uma unica execucao e com UMA LINHA POR CHAMADO, as duas consultas
-- anteriores:
--     decision/queries/consulta_faia.sql   (FAIA + Tempo Total Decision + Tempo suspenso)
--     decision/queries/consulta_farc.sql   (FARC + Tempo de Atendimento)
--
-- Os dois motores continuam SEPARADOS. Nada foi simplificado para reduzir o SQL:
-- o FAIA mantem o motor NMS (posse x status x calendario, marco SOLN/LOG, regra
-- hibrida das rotinas) e o FARC mantem o motor proprio (terminal Decision, motor
-- de rotina por intervalo e motor de status ativo). O que foi unificado sao
-- apenas as estruturas de MESMA origem, semantica, tipo, granularidade e regra:
-- periodo, conversao Brasil/UTC, #CRPeriodo, #Base, escopo, feriados, #Nums,
-- reabertura e identificacao do chamado.
--
-- ESCOPO (diferenca real entre os dois indicadores, medida no codigo anterior):
--   FARC:  grupo atual = Decision + type IN ('I','R','P') + status terminal.
--   FAIA:  o mesmo, MAIS a exigencia de ENCERRAR no grupo Decision
--          (nasceu no grupo sem transferencia, ou a ultima transferencia de grupo
--          foi uma entrada em 'Fornecedores - Decision').
--   Logo FAIA e um SUBCONJUNTO estrito de FARC. Por isso o escopo e unificado no
--   escopo do FARC (o mais amplo) e o FAIA recebe a flag #EscopoFAIA_DEC. Um
--   chamado fora do escopo FAIA aparece na linha com as colunas de FAIA em NULL,
--   em vez de sumir do resultado. Nao ha FULL OUTER JOIN: ele seria desnecessario
--   (nao existe chamado so no lado FAIA) e arriscado.
--
-- CHAVE DE ASSOCIACAO: call_req.id (int). Todas as temporarias que entram nos
-- JOINs finais tem indice UNICO por id ou por persid, portanto nenhum log,
-- intervalo, status, contrato ou categoria multiplica a linha do chamado.
--
-- ORDEM DAS COLUNAS: primeiro TODAS as colunas do SELECT final do FAIA, na ordem
-- original; depois somente as colunas EXCLUSIVAS do FARC, na ordem relativa
-- original. Colunas de mesmo nome e mesmo significado aparecem uma unica vez
-- (as do FAIA). Colunas de mesmo nome e significado DIFERENTE foram preservadas
-- com nome distinto e sufixo FARC.
--
-- NOMES EXCLUSIVOS DE TEMPORARIA (sufixo _DEC)
--   Uma tabela # vive ate o fim da SESSAO e o SQL Server compila o lote inteiro
--   antes de executa-lo; o "IF OBJECT_ID(...) DROP TABLE" so roda na execucao.
--   Se outra consulta ja deixou na sessao uma # de mesmo nome e esquema
--   diferente, a compilacao liga esta consulta a tabela velha e acusa
--   "Msg 207 - Invalid column name".
--   Como este arquivo e NOVO e substitui as duas consultas antigas da Decision,
--   todas as suas temporarias recebem o sufixo _DEC. Isso e uma escolha de
--   ESPACO DE NOMES feita uma unica vez na criacao do arquivo, e nao a
--   "renomeacao em massa" descartada em 2026-07-14 (que tentava usar renomeacao
--   como conserto cego de um erro nao diagnosticado). O efeito e que esta
--   consulta roda:
--     1) em sessao nova;
--     2) duas vezes seguidas na mesma sessao;
--     3) depois de qualquer consulta da Protect4;
--     4) depois de restos das consultas antigas da Decision;
--   sem script externo de limpeza, sem nova conexao e sem GO.
--
-- REGRA DE TEMPO SUSPENSO (revisada nesta versao, secao [8.4])
--   Nao usa TempoGastoSeg / act_log.time_spent / call_req.time_spent_sum como
--   fonte do total. Esses campos ficam apenas no diagnostico.
--   Tempo suspenso = UNIAO TEMPORAL de:
--     (a) intervalos em status suspenso dentro da posse da Decision; e
--     (b) o intervalo SOLN -> SRVY_SENT.
--   A uniao impede que o mesmo segundo seja contado duas vezes.
--   A "hora nao comercial" NAO entra mais no Tempo suspenso: ela vai para o
--   terceiro componente (fora da apuracao). Prova no chamado 1700873, secao [8.4].
--
-- Nesta versao Power BI nao existe @MostrarDiagnostico: o bloco de diagnostico
-- foi removido para que sobre um unico result set.
-- Nao existe GO neste arquivo.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- [PARAMETROS FACILMENTE ALTERAVEIS] - compartilhados pelos dois indicadores
--------------------------------------------------------------------------------
--------------------------------------------------------------------------------
-- [FORNECEDOR] - identico a consulta manual
--------------------------------------------------------------------------------
DECLARE @FornecedorNome      nvarchar(100) = N'Decision';
DECLARE @FornecedorGrupo     varbinary(16) = 0x24CD15F171FE7540BEACF45A53A305C5;
DECLARE @FornecedorGrupoNome nvarchar(200) = N'Fornecedores - Decision';

--------------------------------------------------------------------------------
-- [JANELA DINAMICA] - ultimos @CoberturaMeses meses ate HOJE
--
-- Substitui @InicioBrasil/@FimBrasil, que na consulta manual sao digitados.
--
-- COBERTURA - o UNICO numero que se mexe aqui
--
--   DECLARE @CoberturaMeses int = 12;   <- padrao, no TOPO do arquivo
--
--   Para 6, 18 ou 24 meses, troque so esse valor. Nenhuma regra de negocio
--   depende dele: ele move apenas o limite inferior da selecao por close_date.
--   No Power BI a alteracao e feita no Editor Avancado da consulta, no inicio
--   do texto SqlTexto (primeira instrucao depois do SET TRANSACTION).
--
-- POR QUE NAO HA MAIS CICLO 24-24
--
--   Ate 2026-09-18 este bloco devolvia os seis ultimos ciclos fechados, com o
--   ciclo indo do dia 24 ao dia 23 do mes seguinte. Essa e a regra de
--   faturamento da Protect4/A2B e veio junto quando o modelo de janela daquele
--   nucleo foi reaproveitado. A Decision NAO tem ciclo 24-24.
--
--   O efeito pratico do erro: o corte no dia 24 descartava ate 30 dias ja
--   encerrados, e a cobertura real oscilava conforme o dia da execucao.
--
-- LIMITES - inclusivo/exclusivo
--
--   inicio INCLUSIVO = hoje menos @CoberturaMeses meses, as 00:00:00
--   fim    EXCLUSIVO = AMANHA as 00:00:00
--
--   O fim e amanha, e nao hoje, porque close_date e um instante e nao uma
--   data: com o fim em hoje 00:00 o dia corrente ficaria inteiro de fora, e
--   com '23:59:59' perder-se-ia o ultimo segundo do dia. O intervalo e
--   semiaberto [inicio, fim), convencao usada em todo o projeto.
--
--   Nao ha data fixa no codigo: tudo deriva de SYSUTCDATETIME() convertido
--   para o fuso do Brasil.
--
-- O periodo SELECIONA os chamados (por close_date). Ele NAO recorta os
-- intervalos calculados: a linha do tempo de cada chamado vai de open_date a
-- close_date, mesmo quando parte dela ocorreu antes do inicio da janela (ver
-- secao [8.5]). Essa regra e da Decision e continua exatamente como estava.
--------------------------------------------------------------------------------
-- @CoberturaMeses e declarado na PRIMEIRA linha util do arquivo, para ficar
-- visivel logo no inicio do texto SqlTexto da consulta M.

-- Conversao para UTC/GMT usado pelo SDM em pdmtime/epoch.
DECLARE @HorasBrasilParaUTC int = 3;
DECLARE @Epoch datetime2(0) = '1970-01-01 00:00:00';

DECLARE @HojeBrasil date =
    CONVERT(date, DATEADD(HOUR, -@HorasBrasilParaUTC, SYSUTCDATETIME()));

-- Inicio INCLUSIVO da janela.
DECLARE @InicioBrasil datetime2(0) =
    CONVERT(datetime2(0), DATEADD(MONTH, -@CoberturaMeses, @HojeBrasil));

-- Fim EXCLUSIVO da janela = amanha 00:00, para o dia corrente entrar inteiro.
DECLARE @FimBrasilExclusivo datetime2(0) =
    CONVERT(datetime2(0), DATEADD(DAY, 1, @HojeBrasil));

DECLARE @FromUTC        datetime2(0) = DATEADD(HOUR, @HorasBrasilParaUTC, @InicioBrasil);
DECLARE @ToUTCExclusivo datetime2(0) = DATEADD(HOUR, @HorasBrasilParaUTC, @FimBrasilExclusivo);
DECLARE @FromEpoch        int = DATEDIFF(SECOND, @Epoch, @FromUTC);
DECLARE @ToEpochExclusivo int = DATEDIFF(SECOND, @Epoch, @ToUTCExclusivo);

-- Janela comercial usada nos SLAs comerciais dos dois indicadores.
DECLARE @HoraInicioComercial int = 8;
DECLARE @HoraFimComercial    int = 20;

--------------------------------------------------------------------------------
-- [SLA FAIA] por contrato / tipo de chamado / severidade  (motor do FAIA)
--
-- Contrato 53/2024 -> categoria LIKE '%LibQuantum%'
--   Incidentes (I):  P1 15 min corridos; P2 2 h corridas; P3 4 h TCU; P4 8 h TCU
--   Solicitacoes(R): P1 15 min corridos; P2 2 h corridas; P3 4 h TCU;
--                    P4 e P5 sem meta (linha ausente = NULL no resultado)
-- Contratos 68/2021, 22/2022, 15/2022 -> Decision.Servidores / Decision.Blade.G1
--   e G2 / Decision.SwitchSAN (demais)
--   P1 15 min corridos; P2 2 h corridas; P3 2 h uteis; P4 2 h uteis; P5 12 h uteis
--
-- A coluna contrato_sym e calculada em #Base_DEC.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#SLA_FAIA_DEC') IS NOT NULL DROP TABLE #SLA_FAIA_DEC;
CREATE TABLE #SLA_FAIA_DEC (
    contrato     varchar(20)  COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,  -- 'LibQuantum' | 'Demais'
    tipo_chamado char(1)      COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,  -- 'I' | 'R' | '*' (qualquer)
    prioridade   tinyint      NOT NULL,
    meta_inicio_seg int       NOT NULL,
    tipo_inicio  varchar(10)  COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,  -- CORRIDA | COMERCIAL
    fator_inicio decimal(3,2) NOT NULL,
    PRIMARY KEY (contrato, tipo_chamado, prioridade)
);

-- Contrato 53/2024 - Incidentes
INSERT INTO #SLA_FAIA_DEC (contrato, tipo_chamado, prioridade, meta_inicio_seg, tipo_inicio, fator_inicio) VALUES
    ('LibQuantum', 'I', 1,  15 * 60,          'CORRIDA',   0.40),
    ('LibQuantum', 'I', 2,   2 * 3600,         'CORRIDA',   0.40),
    ('LibQuantum', 'I', 3,   4 * 3600,         'COMERCIAL', 0.40),
    ('LibQuantum', 'I', 4,   8 * 3600,         'COMERCIAL', 0.40);

-- Contrato 53/2024 - Solicitacoes
INSERT INTO #SLA_FAIA_DEC (contrato, tipo_chamado, prioridade, meta_inicio_seg, tipo_inicio, fator_inicio) VALUES
    ('LibQuantum', 'R', 1,  15 * 60,          'CORRIDA',   0.40),
    ('LibQuantum', 'R', 2,   2 * 3600,         'CORRIDA',   0.40),
    ('LibQuantum', 'R', 3,   4 * 3600,         'COMERCIAL', 0.40);
-- P4 e P5 de Solicitacao no LibQuantum: sem meta (linha ausente = NULL no resultado)

-- Contratos 68/2021, 22/2022, 15/2022 - todos os tipos de chamado
INSERT INTO #SLA_FAIA_DEC (contrato, tipo_chamado, prioridade, meta_inicio_seg, tipo_inicio, fator_inicio) VALUES
    ('Demais', '*', 1,  15 * 60,          'CORRIDA',   0.10),
    ('Demais', '*', 2,   2 * 3600,         'CORRIDA',   0.10),
    ('Demais', '*', 3,   2 * 3600,         'COMERCIAL', 0.10),
    ('Demais', '*', 4,   2 * 3600,         'COMERCIAL', 0.10),
    ('Demais', '*', 5,  12 * 3600,         'COMERCIAL', 0.10);

--------------------------------------------------------------------------------
-- [SLA FARC] por tipo e severidade  (motor do FARC - preservado sem alteracao)
-- Continua sendo VARIAVEL DE TABELA, exatamente como na consulta FARC anterior.
-- Como variavel de tabela nao vive na sessao, ela nunca colide com outra consulta.
-- Metas e FATORES sao os do FARC e sao diferentes dos do FAIA.
--------------------------------------------------------------------------------
DECLARE @SLA_FARC TABLE (
    tipo_chamado          char(1)      COLLATE DATABASE_DEFAULT NOT NULL,
    prioridade            tinyint      NOT NULL,
    meta_inicio_seg       int          NULL,
    tipo_inicio           varchar(10)  COLLATE DATABASE_DEFAULT NULL,
    fator_inicio          decimal(3,2) NULL,
    meta_resolucao_seg    int          NULL,
    tipo_resolucao        varchar(10)  COLLATE DATABASE_DEFAULT NULL,
    fator_resolucao       decimal(3,2) NULL,
    PRIMARY KEY (tipo_chamado, prioridade)
);

INSERT INTO @SLA_FARC
    (tipo_chamado, prioridade, meta_inicio_seg, tipo_inicio, fator_inicio, meta_resolucao_seg, tipo_resolucao, fator_resolucao)
VALUES
    ('I', 1,  15 * 60,       'CORRIDA',   0.40,   8 * 60 * 60,        'CORRIDA',   0.40),
    ('I', 2,   2 * 60 * 60,  'CORRIDA',   0.40,  12 * 60 * 60,        'CORRIDA',   0.40),
    ('I', 3,   2 * 60 * 60,  'COMERCIAL', 0.40,  60 * 60 * 60,        'COMERCIAL', 0.20),
    ('I', 4,   2 * 60 * 60,  'COMERCIAL', 0.40,  60 * 60 * 60,        'COMERCIAL', 0.20),
    ('I', 5,  12 * 60 * 60,  'COMERCIAL', 0.40, 360 * 60 * 60,        'COMERCIAL', 0.20),

    ('R', 1,  15 * 60,       'CORRIDA',   0.40,   8 * 60 * 60,        'CORRIDA',   0.40),
    ('R', 2,   2 * 60 * 60,  'CORRIDA',   0.40,  12 * 60 * 60,        'CORRIDA',   0.40),
    ('R', 3,   2 * 60 * 60,  'COMERCIAL', 0.40,  60 * 60 * 60,        'COMERCIAL', 0.20),
    ('R', 4,   2 * 60 * 60,  'COMERCIAL', 0.40,  60 * 60 * 60,        'COMERCIAL', 0.20),
    ('R', 5,  12 * 60 * 60,  'COMERCIAL', 0.40, 360 * 60 * 60,        'COMERCIAL', 0.20),

    -- Mantido como estava, por enquanto, para nao alterar escopo/comportamento
    -- fora do criterio validado.
    ('P', 1,  15 * 60,       'CORRIDA',   0.40,  12 * 60 * 60,        'CORRIDA',   0.30),
    ('P', 2,  60 * 60,       'CORRIDA',   0.40,  24 * 60 * 60,        'CORRIDA',   0.30),
    ('P', 3, 240 * 60,       'COMERCIAL', 0.40,  36 * 60 * 60,        'COMERCIAL', 0.30),
    ('P', 4, 240 * 60,       'COMERCIAL', 0.40,  36 * 60 * 60,        'COMERCIAL', 0.30),
    ('P', 5, 720 * 60,       'COMERCIAL', 0.40, 360 * 60 * 60,        'COMERCIAL', 0.30);

--------------------------------------------------------------------------------
-- [STATUS QUE CONTROLAM O NMS DECISION]  (motor do FAIA)
--
-- A lista ATIVO e fechada: somente estes destinos autorizam o NMS a correr.
-- Qualquer status nao cadastrado como ATIVO e tratado como SUSPENSO. A coluna
-- status_conhecido dos intervalos permite diagnosticar nomes nao catalogados sem
-- transformar silenciosamente um status desconhecido em ativo.
--
-- eh_homologacao_decision = 1 identifica exclusivamente o destino que representa
-- o envio da Decision para homologacao. A comparacao usa collation CI/AI, mas e
-- de igualdade; uma saida "Em homologacao" -> "Reaberto" nao e confundida com
-- uma entrada em homologacao.
--
-- Os status suspensos citados pelo gestor (Agendado, Aguardando fornecedor,
-- Em homologacao, Aguardando documentacao, Aguardando publicacao) estao todos
-- cadastrados aqui, com as variacoes de grafia e as traducoes conhecidas. A
-- comparacao e CI/AI, portanto 'Aguardando Publicacao' e 'Aguardando publicacao'
-- casam com a mesma linha.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#RegrasStatus_DEC') IS NOT NULL DROP TABLE #RegrasStatus_DEC;
CREATE TABLE #RegrasStatus_DEC (
    status_nome nvarchar(200) COLLATE Latin1_General_CI_AI NOT NULL PRIMARY KEY,
    tipo_status varchar(10)   COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
    eh_homologacao_decision bit NOT NULL
);

INSERT INTO #RegrasStatus_DEC (status_nome, tipo_status, eh_homologacao_decision)
VALUES
    -- Status ativos oficiais e traducoes/variacoes conhecidas.
    (N'Aberto, aguarda atendimento', 'ATIVO', 0),
    (N'Open',                         'ATIVO', 0),
    (N'Open, awaiting service',       'ATIVO', 0),
    (N'Aguarda atendimento',          'ATIVO', 0),
    (N'Awaiting service',             'ATIVO', 0),
    (N'Em andamento',                 'ATIVO', 0),
    (N'In Progress',                  'ATIVO', 0),
    (N'Reaberto',                     'ATIVO', 0),
    (N'Reopened',                     'ATIVO', 0),

    -- Status suspensos conhecidos. Outros nomes tambem serao suspensos e
    -- aparecerao no diagnostico de status nao classificados.
    (N'Agendado',                     'SUSPENSO', 0),
    (N'Scheduled',                    'SUSPENSO', 0),
    (N'Aguarda fornecedor',           'SUSPENSO', 0),
    (N'Aguardando fornecedor',        'SUSPENSO', 0),
    (N'Awaiting vendor',              'SUSPENSO', 0),
    (N'Aguardando documentação',      'SUSPENSO', 0),
    (N'Awaiting documentation',       'SUSPENSO', 0),
    (N'Aguardando publicação',        'SUSPENSO', 0),
    (N'Awaiting publication',         'SUSPENSO', 0),
    (N'Em teste na TI',               'SUSPENSO', 0),
    (N'In IT testing',                'SUSPENSO', 0),
    (N'Em homologação pelo fiscal',   'SUSPENSO', 0),
    (N'Em homologação',               'SUSPENSO', 1),
    (N'Resolvido, concluído',          'SUSPENSO', 0),
    (N'Não resolvido, fechado',        'SUSPENSO', 0),
    (N'Fechado, Solução Implantada',   'SUSPENSO', 0),
    (N'Fechado, solução não implantada','SUSPENSO', 0),
    (N'Cancelado',                     'SUSPENSO', 0),
    (N'Cancelada',                     'SUSPENSO', 0),
    (N'Encerrado',                     'SUSPENSO', 0);

--------------------------------------------------------------------------------
-- [CADASTRO DE ROTINAS OPERACIONAIS - FAIA]
--
-- Regra especifica dos contratos 68/2021, 15/2022 e 22/2022: rotinas de
-- Servidores, Blade e SwitchSAN usam este cadastro tanto na regra do Tempo
-- Primeiro Atendimento quanto na regra hibrida do Tempo Total Decision.
-- Nao e aplicada a LibQuantum/Tape. Os padroes sao LIKE porque os resumos
-- normalmente terminam com datas.
--
-- ATENCAO: este cadastro NAO e o mesmo do FARC (abaixo). Os dois foram mantidos
-- separados de proposito: o FARC usa uma lista mais ampla e com semantica
-- diferente (OR entre categoria e resumo, em vez de AND). Unifica-los mudaria o
-- resultado dos dois indicadores.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#RotinasFAIA_DEC') IS NOT NULL DROP TABLE #RotinasFAIA_DEC;
CREATE TABLE #RotinasFAIA_DEC (
    categoria_like nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    resumo_like    nvarchar(400) COLLATE DATABASE_DEFAULT NULL
);

INSERT INTO #RotinasFAIA_DEC (categoria_like, resumo_like)
VALUES
    -- Contrato Servidores de Rack 68/2021
    (N'%Servidores%', N'%Checklist Diário - Servidores PowerEdge%'),
    (N'%Servidores%', N'%R750%R840%Rotina semanal%revisão%planilha%servidores%'),
    (N'%Servidores%', N'%Rotina Semanal%Contrato Servidores%Relatório de Manutenções Sistemática%'),
    (N'%Servidores%', N'%Rotina Semanal%Contrato Servidores%Relatório com manutenções sistemáticas%'),

    -- Contrato Servidores de Lamina 15/2022 - Blade G1/G2
    (N'%Blade%', N'%Checklist Diário - Chassis%'),
    (N'%Blade%', N'%Contrato Chassis%Envio semanal de relatório%manutenções sistemáticas%'),
    (N'%Blade%', N'%MX750%Rotina semanal%revisão%planilha%servidores%'),
    (N'%Blade%', N'%MX840%Rotina semanal%revisão%planilha%servidores%'),

    -- Contrato SwitchSAN 22/2022
    (N'%SwitchSAN%', N'%Checklist Diário - Switch SAN%'),
    (N'%SwitchSAN%', N'%Rotina Semanal%Contrato SAN%Relatório de Manutenções Sistemática%'),
    (N'%SwitchSAN%', N'%Rotina Semanal%Contrato SAN%Relatório com manutenções sistemáticas%'),

    -- Fallbacks por classificacao usada no catalogo Decision.
    -- Mantidos restritos a contrato_sym = 'Demais' no calculo final.
    (N'%Realizar Checklist/ HealthCheck%', NULL),
    (N'%Produção de relatórios%', N'%Envio semanal de relatório%'),
    (N'%Elaboração e manutenção de documentação%', N'%Rotina semanal%');

--------------------------------------------------------------------------------
-- [CADASTRO DE ROTINAS OPERACIONAIS - FARC]
--
-- O relatorio do fornecedor trata rotinas operacionais por intervalo:
--   Data Abertura/Inicio -> Data de Fechamento Decision.
-- Nao zera a rotina pelo resumo. Ela so zera naturalmente quando todo o intervalo
-- cai fora do calendario contado (ex.: feriado/ponto facultativo).
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#RotinasFARC_DEC') IS NOT NULL DROP TABLE #RotinasFARC_DEC;
CREATE TABLE #RotinasFARC_DEC (
    categoria_like nvarchar(400) COLLATE DATABASE_DEFAULT NULL,
    resumo_like    nvarchar(400) COLLATE DATABASE_DEFAULT NULL
);

INSERT INTO #RotinasFARC_DEC (categoria_like, resumo_like)
VALUES
    (N'%Realizar Checklist/ HealthCheck%', NULL),
    (N'%Produção de relatórios%', NULL),
    (N'%Elaboração e manutenção de documentação%', NULL),
    (NULL, N'%Checklist Diário%'),
    (NULL, N'%Rotina semanal%'),
    (NULL, N'%Rotina Semanal%'),
    (NULL, N'%Envio semanal de relatório%'),
    (NULL, N'%Relatório de Manutenções Sistemática%'),
    (NULL, N'%Relatório com manutenções sistemáticas%');

--------------------------------------------------------------------------------
-- [FERIADOS E PONTOS FACULTATIVOS] - COMPARTILHADOS
--
-- A lista de feriados NAO fica mais neste arquivo. Ela vem do arquivo de
-- feriados (docs/feriados.txt; no Power BI, a copia no SharePoint), o mesmo
-- calendario do TCU para Virtual, Decision e A2B, pelo parametro @Feriados
-- (JSON):
--   [{"data":"12-25","descricao":"Natal"},{"data":"2026-04-03","descricao":"..."}]
--   MM-DD      = feriado fixo, vale todo ano;
--   AAAA-MM-DD = data unica (feriado movel ou ponto facultativo).
-- Quem preenche @Feriados: tools/executar_consulta.ps1 (consultas de queries/)
-- e o codigo M de powerbi/*.m (Power BI). Sem @Feriados a consulta nem compila;
-- lista vazia, JSON ou data invalida param com erro: nunca se calcula com zero
-- feriados. Data repetida entra uma vez.
--
-- Regra de contagem (inalterada):
--   - CORRIDA: conta 24h, sem desconto de feriado/facultativo.
--   - COMERCIAL: conta somente segunda a sexta, 08:00-20:00, zerando os dias
--     listados como feriado/facultativo.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#FeriadosEntrada_DEC') IS NOT NULL DROP TABLE #FeriadosEntrada_DEC;
CREATE TABLE #FeriadosEntrada_DEC (data nvarchar(100) NULL, descricao nvarchar(200) NULL);
IF ISJSON(@Feriados) = 1
    INSERT INTO #FeriadosEntrada_DEC (data, descricao)
    SELECT LTRIM(RTRIM(j.data)), LTRIM(RTRIM(j.descricao))
    FROM OPENJSON(@Feriados) WITH (data nvarchar(100) '$.data', descricao nvarchar(200) '$.descricao') AS j;
IF ISNULL(ISJSON(@Feriados), 0) = 0 OR NOT EXISTS (SELECT 1 FROM #FeriadosEntrada_DEC)
BEGIN
    ;THROW 50001, N'Feriados: @Feriados vazio ou invalido. Execute pelo tools/executar_consulta.ps1 (queries/) ou pelo Power BI (powerbi/*.m).', 1;
END;
IF EXISTS (
    SELECT 1
    FROM #FeriadosEntrada_DEC AS f
    WHERE f.data IS NULL
       OR NOT (   (LEN(f.data) = 10 AND f.data LIKE N'[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]' AND TRY_CONVERT(date, f.data, 23) IS NOT NULL)
               OR (LEN(f.data) = 5  AND f.data LIKE N'[0-9][0-9]-[0-9][0-9]' AND TRY_CONVERT(date, N'2000-' + f.data, 23) IS NOT NULL))
)
BEGIN
    ;THROW 50002, N'Feriados: @Feriados tem data fora do formato AAAA-MM-DD ou MM-DD.', 1;
END;

IF OBJECT_ID('tempdb..#FeriadosFixos_DEC') IS NOT NULL DROP TABLE #FeriadosFixos_DEC;
CREATE TABLE #FeriadosFixos_DEC (
    mes_dia   char(5)        NOT NULL PRIMARY KEY, -- MM-DD
    descricao nvarchar(200)  NOT NULL
);
INSERT INTO #FeriadosFixos_DEC (mes_dia, descricao)
SELECT f.data, MIN(COALESCE(NULLIF(f.descricao, N''), N'Feriado'))
FROM #FeriadosEntrada_DEC AS f
WHERE LEN(f.data) = 5
GROUP BY f.data;

IF OBJECT_ID('tempdb..#FeriadosPorData_DEC') IS NOT NULL DROP TABLE #FeriadosPorData_DEC;
CREATE TABLE #FeriadosPorData_DEC (
    data      date           NOT NULL PRIMARY KEY,
    descricao nvarchar(200)  NOT NULL
);
INSERT INTO #FeriadosPorData_DEC (data, descricao)
SELECT CONVERT(date, f.data, 23), MIN(COALESCE(NULLIF(f.descricao, N''), N'Feriado'))
FROM #FeriadosEntrada_DEC AS f
WHERE LEN(f.data) = 10
GROUP BY CONVERT(date, f.data, 23);

--------------------------------------------------------------------------------
-- [0] Membros do grupo do fornecedor  (herdado do FARC)
--
-- Observacao registrada, sem alteracao de comportamento: esta tabela alimenta
-- somente #CapturaAtivFornecFARC_DEC, que por sua vez nao e consumida pela
-- escolha final de captura do FARC. Foi preservada exatamente como estava para
-- nao introduzir mudanca funcional no FARC alem da correcao do decimal.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#FornecedorMembros_DEC') IS NOT NULL DROP TABLE #FornecedorMembros_DEC;
CREATE TABLE #FornecedorMembros_DEC (
    contact_uuid varbinary(16) NOT NULL PRIMARY KEY
);

INSERT INTO #FornecedorMembros_DEC(contact_uuid)
SELECT DISTINCT gm.member
FROM dbo.grpmem AS gm
WHERE gm.group_id = @FornecedorGrupo
  AND gm.member IS NOT NULL;

--------------------------------------------------------------------------------
-- [1] Pre-filtro por periodo de fechamento - COMPARTILHADO
-- Identico nas duas consultas anteriores: mesma origem, mesmas colunas, mesma
-- granularidade (1 linha por chamado) e mesma regra.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#CRPeriodo_DEC') IS NOT NULL DROP TABLE #CRPeriodo_DEC;

SELECT
    r.id,
    r.persid,
    r.ref_num,
    r.[type],
    r.priority,
    r.status,
    r.category,
    r.group_id,
    r.assignee,
    r.log_agent,
    r.customer,
    r.open_date,
    r.close_date,
    r.resolve_date,
    r.time_spent_sum,
    CONVERT(nvarchar(4000), r.summary) AS summary_txt
INTO #CRPeriodo_DEC
FROM dbo.call_req AS r
WHERE r.close_date IS NOT NULL
  AND r.close_date >= @FromEpoch
  AND r.close_date <  @ToEpochExclusivo;

CREATE UNIQUE CLUSTERED INDEX IX_CRPeriodo_DEC_id ON #CRPeriodo_DEC(id);
CREATE INDEX IX_CRPeriodo_DEC_persid ON #CRPeriodo_DEC(persid);
CREATE INDEX IX_CRPeriodo_DEC_close ON #CRPeriodo_DEC(close_date);
CREATE INDEX IX_CRPeriodo_DEC_category ON #CRPeriodo_DEC(category);
CREATE INDEX IX_CRPeriodo_DEC_group ON #CRPeriodo_DEC(group_id);
CREATE INDEX IX_CRPeriodo_DEC_assignee ON #CRPeriodo_DEC(assignee);

--------------------------------------------------------------------------------
-- [2] Base enriquecida - COMPARTILHADA
--
-- Uniao das duas bases anteriores. As colunas eram identicas, exceto por
-- contrato_sym e tipo_chamado_faia, que existiam apenas no FAIA e continuam
-- servindo apenas ao JOIN de #SLA_FAIA_DEC. Nenhuma coluna do FARC foi perdida.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Base_DEC') IS NOT NULL DROP TABLE #Base_DEC;

SELECT
    r.id,
    r.persid,
    r.ref_num,
    r.[type],
    r.priority,
    TRY_CONVERT(tinyint, pri.sym) AS prioridade_por_sym,
    CASE
        WHEN TRY_CONVERT(tinyint, pri.sym) BETWEEN 1 AND 5 THEN TRY_CONVERT(tinyint, pri.sym)
        WHEN r.priority BETWEEN 1 AND 5 THEN CONVERT(tinyint, r.priority)
        ELSE NULL
    END AS prioridade_nivel,
    r.status,
    r.category,
    r.group_id,
    r.assignee,
    r.log_agent,
    r.customer,
    r.open_date,
    r.close_date,
    r.resolve_date,
    r.time_spent_sum,
    r.summary_txt,
    st.sym AS status_sym,
    pc.sym AS categoria_sym,

    LTRIM(RTRIM(
        CASE
            WHEN (ISNULL(la.first_name, N'') <> N'' OR ISNULL(la.last_name, N'') <> N'')
                THEN CONCAT(ISNULL(la.first_name, N''), N' ', ISNULL(la.last_name, N''))
            WHEN ISNULL(la.userid, N'') <> N'' THEN la.userid
            ELSE N'N/A'
        END
    )) AS responsavel_abertura,

    LTRIM(RTRIM(
        CASE
            WHEN (ISNULL(asg.first_name, N'') <> N'' OR ISNULL(asg.last_name, N'') <> N'')
                THEN CONCAT(ISNULL(asg.first_name, N''), N' ', ISNULL(asg.last_name, N''))
            WHEN ISNULL(asg.userid, N'') <> N'' THEN asg.userid
            ELSE N'N/A'
        END
    )) AS responsavel_atendimento,

    -- Contrato derivado da categoria, usado para selecionar a linha de SLA do FAIA.
    --   'LibQuantum' -> contrato 53/2024 (Decision.LibQuantum.*)
    --   'Demais'     -> contratos 68/2021, 22/2022, 15/2022
    CASE
        WHEN pc.sym COLLATE Latin1_General_CI_AI LIKE N'%LibQuantum%'
            THEN CONVERT(varchar(20), 'LibQuantum') COLLATE SQL_Latin1_General_CP1_CI_AS
        ELSE CONVERT(varchar(20), 'Demais') COLLATE SQL_Latin1_General_CP1_CI_AS
    END AS contrato_sym,

    -- Tipo de chamado normalizado para o JOIN de SLA do FAIA:
    --   LibQuantum distingue I vs R; P e preservado e fica sem SLA enquanto nao
    --   houver regra documentada. Demais usa '*' para qualquer tipo.
    CASE
        WHEN pc.sym COLLATE Latin1_General_CI_AI LIKE N'%LibQuantum%'
            THEN CONVERT(char(1), r.[type]) COLLATE SQL_Latin1_General_CP1_CI_AS
        ELSE CONVERT(char(1), '*') COLLATE SQL_Latin1_General_CP1_CI_AS
    END AS tipo_chamado_faia
INTO #Base_DEC
FROM #CRPeriodo_DEC AS r
LEFT JOIN dbo.cr_stat AS st
    ON st.code = r.status
LEFT JOIN dbo.prob_ctg AS pc
    ON pc.persid = r.category
LEFT JOIN dbo.pri AS pri
    ON pri.enum = r.priority
LEFT JOIN dbo.ca_contact AS la
    ON la.contact_uuid = r.log_agent
LEFT JOIN dbo.ca_contact AS asg
    ON asg.contact_uuid = r.assignee;

CREATE UNIQUE CLUSTERED INDEX IX_Base_DEC_id ON #Base_DEC(id);
CREATE INDEX IX_Base_DEC_persid ON #Base_DEC(persid);
CREATE INDEX IX_Base_DEC_assignee ON #Base_DEC(assignee);
CREATE INDEX IX_Base_DEC_group ON #Base_DEC(group_id);

--------------------------------------------------------------------------------
-- [3] Escopo UNIFICADO (regra do FARC, que e a mais ampla)
--
-- Chamado pertence ao fornecedor quando o grupo atual do chamado e o grupo
-- Decision. A categoria NAO e usada como filtro. Os status finais sao lidos por
-- CODIGO (sigla), nunca por texto: lista estavel, apenas estados TERMINAIS.
--
-- Este e o escopo do FARC e tambem o conjunto de linhas do resultado final.
-- A restricao adicional do FAIA e aplicada em [3.2].
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#EscopoIds_DEC') IS NOT NULL DROP TABLE #EscopoIds_DEC;
CREATE TABLE #EscopoIds_DEC (
    id int NOT NULL PRIMARY KEY,
    FonteFornecedor nvarchar(120) NOT NULL
);

INSERT INTO #EscopoIds_DEC(id, FonteFornecedor)
SELECT b.id, CONCAT(N'Grupo atual ', @FornecedorNome)
FROM #Base_DEC AS b
WHERE b.group_id = @FornecedorGrupo
  AND b.[type] IN ('I', 'R', 'P')
  AND b.status IN (
        'CL',        -- Resolvido, concluido
        'CLD',       -- Fechado, Solucao Implantada
        'CLUNRSLV',  -- Nao resolvido, fechado
        'CNCL',      -- Cancelada
        'ATGR',      -- Cancelado
        'END',       -- Encerrado
        'PC',        -- Fechado, solucao nao implantada
        'RE',        -- Resolvido, Solucao Definida
        'VARES'      -- Resolvido pelo VA
      );
--------------------------------------------------------------------------------
-- [3.1] Historico de transferencia de GRUPO  (parser do FAIA, reutilizado)
--
-- Materializa somente o trecho iniciado por uma ancora explicita de mudanca de
-- grupo ("Grupo de", "Grupo alterado de", "Grupo transferido de" e equivalentes
-- em ingles). Isso evita confundir transferencia de responsavel com grupo.
--
-- As janelas completas de posse (entrada, saida e retorno) sao construidas em
-- [8.1] a partir destes mesmos eventos.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#GrupoRaw_DEC') IS NOT NULL DROP TABLE #GrupoRaw_DEC;

SELECT
    b.id,
    al.system_time AS evento_epoch,
    CONVERT(nvarchar(400), SUBSTRING(txt.texto_log, ancora.posicao, 400)) AS resto
INTO #GrupoRaw_DEC
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
CROSS APPLY (
    SELECT texto_log =
        CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
        CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
) AS txt
CROSS APPLY (
    SELECT posicao = CASE
        WHEN CHARINDEX(N'Grupo de', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'Grupo de', txt.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'Grupo de')
        WHEN CHARINDEX(N'Grupo alterado de', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'Grupo alterado de', txt.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'Grupo alterado de')
        WHEN CHARINDEX(N'Grupo transferido de', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'Grupo transferido de', txt.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'Grupo transferido de')
        WHEN CHARINDEX(N'Group from', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'Group from', txt.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'Group from')
        WHEN CHARINDEX(N'Group changed from', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'Group changed from', txt.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'Group changed from')
        ELSE 0
    END
) AS ancora
WHERE al.system_time IS NOT NULL
  AND al.type = 'TR'
  AND ancora.posicao > 0
  AND (b.open_date  IS NULL OR al.system_time >= b.open_date)
  AND (b.close_date IS NULL OR al.system_time <= b.close_date);

CREATE INDEX IX_GrupoRaw_DEC_id_epoch
    ON #GrupoRaw_DEC(id, evento_epoch);

-- Extrai os dois primeiros valores entre aspas apos a ancora: grupo de origem
-- e grupo de destino.
IF OBJECT_ID('tempdb..#GrupoEventos_DEC') IS NOT NULL DROP TABLE #GrupoEventos_DEC;

SELECT
    g.id,
    g.evento_epoch,
    CONVERT(nvarchar(200), LTRIM(RTRIM(origem.nome))) AS grupo_origem,
    CONVERT(nvarchar(200), LTRIM(RTRIM(destino.nome))) AS grupo_destino,
    CONVERT(bit, CASE
        WHEN LTRIM(RTRIM(origem.nome)) COLLATE Latin1_General_CI_AI = LTRIM(RTRIM(@FornecedorGrupoNome)) COLLATE Latin1_General_CI_AI
            THEN 1 ELSE 0
    END) AS origem_decision,
    CONVERT(bit, CASE
        WHEN LTRIM(RTRIM(destino.nome)) COLLATE Latin1_General_CI_AI = LTRIM(RTRIM(@FornecedorGrupoNome)) COLLATE Latin1_General_CI_AI
            THEN 1 ELSE 0
    END) AS destino_decision
INTO #GrupoEventos_DEC
FROM #GrupoRaw_DEC AS g
CROSS APPLY (SELECT q1 = CHARINDEX(N'''', g.resto)) AS c1
CROSS APPLY (SELECT q2 = CASE WHEN c1.q1 > 0 THEN CHARINDEX(N'''', g.resto, c1.q1 + 1) ELSE 0 END) AS c2
CROSS APPLY (
    SELECT nome = CASE
        WHEN c2.q2 > c1.q1 THEN SUBSTRING(g.resto, c1.q1 + 1, c2.q2 - c1.q1 - 1)
        ELSE N''
    END
) AS origem
CROSS APPLY (
    SELECT posicao = CASE
        WHEN c2.q2 > 0 AND CHARINDEX(N' para ', g.resto COLLATE Latin1_General_CI_AI, c2.q2) > 0
            THEN CHARINDEX(N' para ', g.resto COLLATE Latin1_General_CI_AI, c2.q2)
        WHEN c2.q2 > 0
            THEN CHARINDEX(N' to ', g.resto COLLATE Latin1_General_CI_AI, c2.q2)
        ELSE 0
    END
) AS separador
CROSS APPLY (SELECT q3 = CASE WHEN separador.posicao > 0 THEN CHARINDEX(N'''', g.resto, separador.posicao) ELSE 0 END) AS c3
CROSS APPLY (SELECT q4 = CASE WHEN c3.q3 > 0 THEN CHARINDEX(N'''', g.resto, c3.q3 + 1) ELSE 0 END) AS c4
CROSS APPLY (
    SELECT nome = CASE
        WHEN c4.q4 > c3.q3 THEN SUBSTRING(g.resto, c3.q3 + 1, c4.q4 - c3.q3 - 1)
        ELSE N''
    END
) AS destino
WHERE c1.q1 > 0
  AND c2.q2 > c1.q1
  AND separador.posicao > 0
  AND c3.q3 > 0
  AND c4.q4 > c3.q3
  AND NULLIF(LTRIM(RTRIM(origem.nome)), N'') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(destino.nome)), N'') IS NOT NULL;

-- Mantem compatibilidade com logs antigos sem aspas:
--   Grupo de COI para Fornecedores - Decision
INSERT INTO #GrupoEventos_DEC
    (id, evento_epoch, grupo_origem, grupo_destino, origem_decision, destino_decision)
SELECT
    g.id,
    g.evento_epoch,
    CONVERT(nvarchar(200), LEFT(LTRIM(RTRIM(partes.origem)), 200)) AS grupo_origem,
    CONVERT(nvarchar(200), LEFT(LTRIM(RTRIM(partes.destino)), 200)) AS grupo_destino,
    CONVERT(bit, CASE
        WHEN LTRIM(RTRIM(partes.origem)) COLLATE Latin1_General_CI_AI
             LIKE LTRIM(RTRIM(@FornecedorGrupoNome)) COLLATE Latin1_General_CI_AI + N'%'
            THEN 1 ELSE 0
    END) AS origem_decision,
    CONVERT(bit, CASE
        WHEN LTRIM(RTRIM(partes.destino)) COLLATE Latin1_General_CI_AI
             LIKE LTRIM(RTRIM(@FornecedorGrupoNome)) COLLATE Latin1_General_CI_AI + N'%'
            THEN 1 ELSE 0
    END) AS destino_decision
FROM #GrupoRaw_DEC AS g
CROSS APPLY (
    SELECT
        posicao = CASE
            WHEN CHARINDEX(N' para ', g.resto COLLATE Latin1_General_CI_AI) > 0
                THEN CHARINDEX(N' para ', g.resto COLLATE Latin1_General_CI_AI)
            ELSE CHARINDEX(N' to ', g.resto COLLATE Latin1_General_CI_AI)
        END,
        largura = CASE
            WHEN CHARINDEX(N' para ', g.resto COLLATE Latin1_General_CI_AI) > 0
                THEN LEN(N' para ')
            ELSE LEN(N' to ')
        END
) AS separador_sem_aspas
CROSS APPLY (
    SELECT
        origem = CASE
            WHEN separador_sem_aspas.posicao > 1
                THEN SUBSTRING(g.resto, 1, separador_sem_aspas.posicao - 1)
            ELSE N''
        END,
        destino = CASE
            WHEN separador_sem_aspas.posicao > 0
                THEN SUBSTRING(g.resto, separador_sem_aspas.posicao + separador_sem_aspas.largura, 400)
            ELSE N''
        END
) AS partes
WHERE CHARINDEX(N'''', g.resto) = 0
  AND separador_sem_aspas.posicao > 1
  AND NULLIF(LTRIM(RTRIM(partes.origem)), N'') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(partes.destino)), N'') IS NOT NULL;

CREATE INDEX IX_GrupoEventos_DEC_id_epoch
    ON #GrupoEventos_DEC(id, evento_epoch);

IF OBJECT_ID('tempdb..#TransfGrupo_DEC') IS NOT NULL DROP TABLE #TransfGrupo_DEC;

SELECT
    g.id,
    COUNT(*) AS qtd_transf_grupo,
    MAX(g.evento_epoch) AS ultima_transf_grupo_epoch,
    MIN(CASE WHEN g.destino_decision = 1 THEN g.evento_epoch END) AS primeira_entrada_fornecedor_epoch,
    MAX(CASE WHEN g.destino_decision = 1 THEN g.evento_epoch END) AS ultima_entrada_fornecedor_epoch
INTO #TransfGrupo_DEC
FROM #GrupoEventos_DEC AS g
GROUP BY g.id;

CREATE UNIQUE CLUSTERED INDEX IX_TransfGrupo_DEC_id ON #TransfGrupo_DEC(id);

--------------------------------------------------------------------------------
-- [3.2] Escopo do FAIA: chamados que ENCERRARAM no grupo Decision
--
-- Restricao ADICIONAL do FAIA sobre o escopo unificado. Vale quando:
--   (a) o chamado nasceu no grupo e nunca sofreu transferencia de grupo; ou
--   (b) a ULTIMA transferencia de grupo de todas, ate o fechamento, foi uma
--       entrada em 'Fornecedores - Decision'.
--
-- Chamados fora desta tabela continuam no resultado (o FARC os cobre), porem com
-- todas as colunas de FAIA em NULL.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#EscopoFAIA_DEC') IS NOT NULL DROP TABLE #EscopoFAIA_DEC;
CREATE TABLE #EscopoFAIA_DEC (
    id int NOT NULL PRIMARY KEY,
    FonteFornecedorFAIA nvarchar(160) NOT NULL
);

INSERT INTO #EscopoFAIA_DEC(id, FonteFornecedorFAIA)
SELECT
    e.id,
    CASE
        WHEN tg.id IS NULL
            THEN CONCAT(N'Nasceu e permaneceu no grupo ', @FornecedorNome, N' (sem transferência de grupo)')
        ELSE CONCAT(N'Encerrou no grupo ', @FornecedorNome, N' (última transferência de grupo foi para ', @FornecedorGrupoNome, N')')
    END AS FonteFornecedorFAIA
FROM #EscopoIds_DEC AS e
LEFT JOIN #TransfGrupo_DEC AS tg
    ON tg.id = e.id
WHERE
    tg.id IS NULL
    OR (
        tg.ultima_entrada_fornecedor_epoch IS NOT NULL
        AND tg.ultima_entrada_fornecedor_epoch = tg.ultima_transf_grupo_epoch
    );

--------------------------------------------------------------------------------
-- [4] FAIA - inicio da contagem e captura do primeiro atendimento
--
-- A contagem comeca quando o chamado passa para a posse do grupo
-- Fornecedores - Decision. Se nasceu no grupo, o fallback e a abertura original.
-- A captura e a primeira alteracao de status para 'Em andamento' DEPOIS da
-- entrada no grupo; nao depende de quem atua, apenas de o chamado ja estar na
-- posse do grupo.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#InicioContagemFAIA_DEC') IS NOT NULL DROP TABLE #InicioContagemFAIA_DEC;

CREATE TABLE #InicioContagemFAIA_DEC (
    id int NOT NULL PRIMARY KEY,
    inicio_contagem_epoch int NULL,
    fonte_inicio_contagem nvarchar(120) NOT NULL
);

INSERT INTO #InicioContagemFAIA_DEC (id, inicio_contagem_epoch, fonte_inicio_contagem)
SELECT
    e.id,
    CASE
        -- Sem transferencia, nasceu e permaneceu na Decision.
        WHEN primeiro.evento_epoch IS NULL THEN b.open_date
        -- Se a origem da primeira transferencia era a Decision, o chamado ja
        -- estava em posse do grupo desde a abertura.
        WHEN primeiro.origem_decision = 1 THEN b.open_date
        -- Caso contrario, a contagem comeca na primeira entrada na Decision.
        ELSE tg.primeira_entrada_fornecedor_epoch
    END AS inicio_contagem_epoch,
    CASE
        WHEN primeiro.evento_epoch IS NULL THEN CONCAT(N'Fallback: chamado nasceu no grupo ', @FornecedorNome)
        WHEN primeiro.origem_decision = 1 THEN CONCAT(N'Chamado nasceu no grupo ', @FornecedorNome, N' e possui histórico de transferências')
        WHEN tg.primeira_entrada_fornecedor_epoch IS NOT NULL THEN CONCAT(N'Primeira transferência para ', @FornecedorGrupoNome)
        WHEN b.open_date IS NOT NULL THEN CONCAT(N'Fallback: chamado nasceu no grupo ', @FornecedorNome)
        ELSE N'Sem início de contagem identificado'
    END AS fonte_inicio_contagem
FROM #EscopoFAIA_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
LEFT JOIN #TransfGrupo_DEC AS tg
    ON tg.id = b.id
OUTER APPLY (
    SELECT TOP (1)
        g.evento_epoch,
        g.origem_decision
    FROM #GrupoEventos_DEC AS g
    WHERE g.id = b.id
    ORDER BY g.evento_epoch ASC, g.destino_decision DESC
) AS primeiro;

--------------------------------------------------------------------------------
-- [3.3.1] Entrada no grupo Fornecedores - Decision (marco de relatorio)
--
-- Momento em que o chamado CAIU no grupo. Vale a PRIMEIRA entrada, nunca uma
-- reentrada posterior. E um conceito distinto de [Data Captura]: a captura e a
-- primeira ida para 'Em andamento' e so pode ocorrer depois que o chamado ja
-- esta no grupo, entao a entrada e sempre igual ou anterior a captura.
--
-- Cobre o escopo unificado (#EscopoIds_DEC), e nao apenas o escopo do FAIA, para
-- que a coluna exista tambem nos chamados que entram somente pelo FARC.
--
-- Regras, na ordem:
--   (a) sem nenhum evento de grupo -> o chamado nasceu no grupo e ali ficou,
--       logo a entrada e a propria abertura (open_date);
--   (b) o primeiro evento de grupo SAIU da Decision -> o chamado ja estava no
--       grupo desde a abertura, e vale open_date;
--   (c) caso contrario -> a menor data entre os eventos cujo destino e a
--       Decision, ou seja #TransfGrupo_DEC.primeira_entrada_fornecedor_epoch;
--   (d) sem evidencia de entrada -> NULL, e a coluna sai vazia.
--
-- E a mesma regra que ja define o inicio da contagem do FAIA, aqui calculada
-- para todo o escopo e publicada como coluna propria. A leitura do primeiro
-- evento usa agregacao sobre o menor segundo, e nao TOP (1) sobre uma ordenacao
-- de chave repetida, para que o valor nao dependa da ordem fisica escolhida pelo
-- SQL Server quando ha varios eventos no mesmo segundo.
--
-- Nenhuma metrica existente le esta tabela: ela so alimenta a coluna nova.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#EntradaGrupoDecision_DEC') IS NOT NULL DROP TABLE #EntradaGrupoDecision_DEC;

CREATE TABLE #EntradaGrupoDecision_DEC (
    id int NOT NULL PRIMARY KEY,
    entrada_grupo_decision_epoch int NULL,
    fonte_entrada_grupo_decision nvarchar(120) NOT NULL
);

INSERT INTO #EntradaGrupoDecision_DEC
    (id, entrada_grupo_decision_epoch, fonte_entrada_grupo_decision)
SELECT
    e.id,
    CASE
        -- (a) nunca houve transferencia de grupo
        WHEN primeiro.primeiro_epoch IS NULL THEN b.open_date
        -- (b) o primeiro evento partiu da propria Decision
        WHEN primeiro.origem_decision_no_primeiro = 1 THEN b.open_date
        -- (c) primeira entrada comprovada no grupo
        ELSE tg.primeira_entrada_fornecedor_epoch
    END AS entrada_grupo_decision_epoch,
    CASE
        WHEN primeiro.primeiro_epoch IS NULL
            THEN CONCAT(N'Chamado nasceu no grupo ', @FornecedorNome)
        WHEN primeiro.origem_decision_no_primeiro = 1
            THEN CONCAT(N'Chamado nasceu no grupo ', @FornecedorNome, N' e possui histórico de transferências')
        WHEN tg.primeira_entrada_fornecedor_epoch IS NOT NULL
            THEN CONCAT(N'Primeira transferência para ', @FornecedorGrupoNome)
        ELSE N'Sem entrada no grupo identificada'
    END AS fonte_entrada_grupo_decision
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
LEFT JOIN #TransfGrupo_DEC AS tg
    ON tg.id = b.id
OUTER APPLY (
    -- Primeiro evento de grupo do chamado. Quando ha mais de um evento no mesmo
    -- segundo, a origem conta como Decision se QUALQUER um deles partiu do
    -- grupo - criterio fixo, independente da ordem de leitura.
    SELECT
        primeiro_epoch = MIN(g.evento_epoch),
        origem_decision_no_primeiro = MAX(CONVERT(int, g.origem_decision))
    FROM #GrupoEventos_DEC AS g
    WHERE g.id = b.id
      AND g.evento_epoch = (
            SELECT MIN(g2.evento_epoch)
            FROM #GrupoEventos_DEC AS g2
            WHERE g2.id = b.id
          )
) AS primeiro;

IF OBJECT_ID('tempdb..#CapturaStatusFAIA_DEC') IS NOT NULL DROP TABLE #CapturaStatusFAIA_DEC;

SELECT
    b.id,
    MIN(al.system_time) AS captura_status_epoch
INTO #CapturaStatusFAIA_DEC
FROM #EscopoFAIA_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN #InicioContagemFAIA_DEC AS ic
    ON ic.id = b.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
WHERE al.system_time IS NOT NULL
  AND ic.inicio_contagem_epoch IS NOT NULL
  AND al.system_time >= ic.inicio_contagem_epoch
  AND al.type = 'ST'
  AND (
        CONVERT(nvarchar(max), ISNULL(al.description, N'')) COLLATE Latin1_General_CI_AI LIKE N'%para ''Em andamento''%'
     OR CONVERT(nvarchar(max), ISNULL(al.action_desc,  N'')) COLLATE Latin1_General_CI_AI LIKE N'%para ''Em andamento''%'
     OR CONVERT(nvarchar(max), ISNULL(al.description, N'')) COLLATE Latin1_General_CI_AI LIKE N'%to ''Em andamento''%'
     OR CONVERT(nvarchar(max), ISNULL(al.action_desc,  N'')) COLLATE Latin1_General_CI_AI LIKE N'%to ''Em andamento''%'
     OR CONVERT(nvarchar(max), ISNULL(al.description, N'')) COLLATE Latin1_General_CI_AI LIKE N'%to ''In Progress''%'
     OR CONVERT(nvarchar(max), ISNULL(al.action_desc,  N'')) COLLATE Latin1_General_CI_AI LIKE N'%to ''In Progress''%'
  )
GROUP BY b.id;

CREATE UNIQUE CLUSTERED INDEX IX_CapturaStatusFAIA_DEC_id ON #CapturaStatusFAIA_DEC(id);

-- Fallback de captura, tambem por GRUPO: primeira atividade registrada apos a
-- entrada no grupo, exceto as proprias transferencias de grupo (type 'TR').
IF OBJECT_ID('tempdb..#CapturaAtividadeFAIA_DEC') IS NOT NULL DROP TABLE #CapturaAtividadeFAIA_DEC;

SELECT
    b.id,
    MIN(al.system_time) AS primeira_atividade_epoch
INTO #CapturaAtividadeFAIA_DEC
FROM #EscopoFAIA_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN #InicioContagemFAIA_DEC AS ic
    ON ic.id = b.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
WHERE al.system_time IS NOT NULL
  AND ic.inicio_contagem_epoch IS NOT NULL
  AND al.system_time >= ic.inicio_contagem_epoch
  AND ISNULL(al.type, N'') <> 'TR'
GROUP BY b.id;

CREATE UNIQUE CLUSTERED INDEX IX_CapturaAtividadeFAIA_DEC_id ON #CapturaAtividadeFAIA_DEC(id);

IF OBJECT_ID('tempdb..#CapturaFAIA_DEC') IS NOT NULL DROP TABLE #CapturaFAIA_DEC;

SELECT
    e.id,
    COALESCE(cs.captura_status_epoch, caf.primeira_atividade_epoch) AS captura_epoch,
    CASE
        WHEN cs.captura_status_epoch IS NOT NULL THEN CONCAT(N'ST para Em andamento após entrada no grupo ', @FornecedorNome)
        WHEN caf.primeira_atividade_epoch IS NOT NULL THEN CONCAT(N'Fallback: primeira atividade após entrada no grupo ', @FornecedorNome)
        ELSE N'Sem captura identificada'
    END AS fonte_captura
INTO #CapturaFAIA_DEC
FROM #EscopoFAIA_DEC AS e
LEFT JOIN #CapturaStatusFAIA_DEC AS cs
    ON cs.id = e.id
LEFT JOIN #CapturaAtividadeFAIA_DEC AS caf
    ON caf.id = e.id;

CREATE UNIQUE CLUSTERED INDEX IX_CapturaFAIA_DEC_id ON #CapturaFAIA_DEC(id);
--------------------------------------------------------------------------------
-- [5] FARC - entrada efetiva no grupo Decision
--
-- Motor PROPRIO do FARC, preservado integralmente. Ele NAO e o mesmo do FAIA:
-- o FAIA reconstroi a posse por parsing textual do act_log 'TR'; o FARC usa uma
-- ordem de confianca com tres fontes. Os dois convivem porque produzem marcos
-- diferentes e cada indicador foi validado com o seu.
--
--   1) View_Audit_Group, quando existir: fonte propria de historico de grupo.
--   2) audit_log direto, quando existir.
--   3) act_log textual: fallback, com filtro estrito de transferencia de GRUPO.
--
-- Selecao final: usa primeiro o act_log.TR textual exato (prioridade 5), porque
-- e o mesmo marco que aparece nos logs detalhados. Dentro da mesma fonte, usa a
-- ultima entrada antes do fechamento.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#EntradaGrupoCand_DEC') IS NOT NULL DROP TABLE #EntradaGrupoCand_DEC;
IF OBJECT_ID('tempdb..#EntradaGrupo_DEC') IS NOT NULL DROP TABLE #EntradaGrupo_DEC;

CREATE TABLE #EntradaGrupoCand_DEC (
    id                   int NOT NULL,
    entrada_grupo_epoch  int NOT NULL,
    prioridade_fonte     tinyint NOT NULL,
    fonte_entrada        nvarchar(80) COLLATE DATABASE_DEFAULT NOT NULL,
    detalhe_entrada      nvarchar(4000) COLLATE DATABASE_DEFAULT NULL
);

DECLARE @FornecedorGrupoHex nvarchar(100) = CONVERT(nvarchar(100), @FornecedorGrupo, 1);
DECLARE @FornecedorGrupoHexSem0x nvarchar(100) = CASE
    WHEN CONVERT(nvarchar(100), @FornecedorGrupo, 1) LIKE N'0x%'
        THEN SUBSTRING(CONVERT(nvarchar(100), @FornecedorGrupo, 1), 3, 200)
    ELSE CONVERT(nvarchar(100), @FornecedorGrupo, 1)
END;

--------------------------------------------------------------------------------
-- Fonte 1: View_Audit_Group
--------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.View_Audit_Group', N'V') IS NOT NULL
BEGIN
    DECLARE @sqlViewAuditGroup nvarchar(max) = N'
        INSERT INTO #EntradaGrupoCand_DEC
            (id, entrada_grupo_epoch, prioridade_fonte, fonte_entrada, detalhe_entrada)
        SELECT
            b.id,
            TRY_CONVERT(int, vag.from_time) AS entrada_grupo_epoch,
            CONVERT(tinyint, 10) AS prioridade_fonte,
            N''View_Audit_Group'' AS fonte_entrada,
            CONCAT(N''to_val='', CONVERT(nvarchar(4000), vag.to_val)) AS detalhe_entrada
        FROM #EscopoIds_DEC AS e
        JOIN #Base_DEC AS b
            ON b.id = e.id
        JOIN dbo.View_Audit_Group AS vag
            ON (
                   CONVERT(nvarchar(100), vag.audobj_uniqueid) = CONVERT(nvarchar(100), b.id)
                OR CONVERT(nvarchar(100), vag.audobj_uniqueid) = CONVERT(nvarchar(100), b.persid)
                OR CONVERT(nvarchar(100), vag.audobj_uniqueid) = CONVERT(nvarchar(100), b.ref_num)
            )
        CROSS APPLY (
            SELECT to_val_txt = CONVERT(nvarchar(4000), ISNULL(vag.to_val, N''''))
        ) AS tv
        WHERE TRY_CONVERT(int, vag.from_time) IS NOT NULL
          AND (b.open_date IS NULL OR TRY_CONVERT(int, vag.from_time) >= b.open_date)
          AND (b.close_date IS NULL OR TRY_CONVERT(int, vag.from_time) <= b.close_date)
          AND (
                 tv.to_val_txt COLLATE Latin1_General_CI_AI LIKE N''%'' + @FornecedorGrupoNome + N''%''
              OR UPPER(tv.to_val_txt) LIKE N''%'' + UPPER(@FornecedorGrupoHex) + N''%''
              OR UPPER(tv.to_val_txt) LIKE N''%'' + UPPER(@FornecedorGrupoHexSem0x) + N''%''
          );';

    EXEC sp_executesql
        @sqlViewAuditGroup,
        N'@FornecedorGrupoNome nvarchar(200), @FornecedorGrupoHex nvarchar(100), @FornecedorGrupoHexSem0x nvarchar(100)',
        @FornecedorGrupoNome = @FornecedorGrupoNome,
        @FornecedorGrupoHex = @FornecedorGrupoHex,
        @FornecedorGrupoHexSem0x = @FornecedorGrupoHexSem0x;
END;

--------------------------------------------------------------------------------
-- Fonte 2: audit_log direto
--------------------------------------------------------------------------------
IF OBJECT_ID(N'dbo.audit_log', N'U') IS NOT NULL
BEGIN
    DECLARE @sqlAuditLogGrupo nvarchar(max) = N'
        INSERT INTO #EntradaGrupoCand_DEC
            (id, entrada_grupo_epoch, prioridade_fonte, fonte_entrada, detalhe_entrada)
        SELECT
            b.id,
            TRY_CONVERT(int, au.change_date) AS entrada_grupo_epoch,
            CONVERT(tinyint, 20) AS prioridade_fonte,
            N''audit_log.group'' AS fonte_entrada,
            CONCAT(
                N''attr_name='', CONVERT(nvarchar(4000), au.attr_name),
                N''; before='', CONVERT(nvarchar(4000), au.attr_before_val),
                N''; after='', CONVERT(nvarchar(4000), au.attr_after_val)
            ) AS detalhe_entrada
        FROM #EscopoIds_DEC AS e
        JOIN #Base_DEC AS b
            ON b.id = e.id
        JOIN dbo.audit_log AS au
            ON (
                   CONVERT(nvarchar(100), au.audobj_uniqueid) = CONVERT(nvarchar(100), b.id)
                OR CONVERT(nvarchar(100), au.audobj_uniqueid) = CONVERT(nvarchar(100), b.persid)
                OR CONVERT(nvarchar(100), au.audobj_uniqueid) = CONVERT(nvarchar(100), b.ref_num)
                OR CONVERT(nvarchar(100), au.audobj_persid)   = CONVERT(nvarchar(100), b.persid)
                OR CONVERT(nvarchar(100), au.audobj_trkid)    = CONVERT(nvarchar(100), b.ref_num)
            )
        CROSS APPLY (
            SELECT
                attr_name_txt = CONVERT(nvarchar(4000), ISNULL(au.attr_name, N'''')),
                after_val_txt = CONVERT(nvarchar(4000), ISNULL(au.attr_after_val, N''''))
        ) AS av
        WHERE TRY_CONVERT(int, au.change_date) IS NOT NULL
          AND (b.open_date IS NULL OR TRY_CONVERT(int, au.change_date) >= b.open_date)
          AND (b.close_date IS NULL OR TRY_CONVERT(int, au.change_date) <= b.close_date)
          AND (
                 av.attr_name_txt COLLATE Latin1_General_CI_AI IN (N''group'', N''group_id'', N''Grupo'')
              OR av.attr_name_txt COLLATE Latin1_General_CI_AI LIKE N''%group%''
              OR av.attr_name_txt COLLATE Latin1_General_CI_AI LIKE N''%grupo%''
          )
          AND (
                 av.after_val_txt COLLATE Latin1_General_CI_AI LIKE N''%'' + @FornecedorGrupoNome + N''%''
              OR UPPER(av.after_val_txt) LIKE N''%'' + UPPER(@FornecedorGrupoHex) + N''%''
              OR UPPER(av.after_val_txt) LIKE N''%'' + UPPER(@FornecedorGrupoHexSem0x) + N''%''
          );';

    EXEC sp_executesql
        @sqlAuditLogGrupo,
        N'@FornecedorGrupoNome nvarchar(200), @FornecedorGrupoHex nvarchar(100), @FornecedorGrupoHexSem0x nvarchar(100)',
        @FornecedorGrupoNome = @FornecedorGrupoNome,
        @FornecedorGrupoHex = @FornecedorGrupoHex,
        @FornecedorGrupoHexSem0x = @FornecedorGrupoHexSem0x;
END;

--------------------------------------------------------------------------------
-- Fonte 3: act_log textual estrito (fallback preferencial na ordenacao)
--------------------------------------------------------------------------------
INSERT INTO #EntradaGrupoCand_DEC
    (id, entrada_grupo_epoch, prioridade_fonte, fonte_entrada, detalhe_entrada)
SELECT
    b.id,
    al.system_time AS entrada_grupo_epoch,
    CONVERT(tinyint, 5) AS prioridade_fonte,
    N'act_log.TR textual exato' AS fonte_entrada,
    LEFT(txt.texto_log, 4000) AS detalhe_entrada
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
CROSS APPLY (
    SELECT texto_log =
        CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
        CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
) AS txt
WHERE al.system_time IS NOT NULL
  AND (b.open_date IS NULL OR al.system_time >= b.open_date)
  AND (b.close_date IS NULL OR al.system_time <= b.close_date)
  AND al.type = 'TR'
  AND (
        txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Transferir%Grupo%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Transfer Group%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Grupo%Transferid%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Grupo%alterad%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Group%changed%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%group_id%'
  )
  AND (
        txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%' + @FornecedorGrupoNome + N'%'
     OR UPPER(CONVERT(nvarchar(max), txt.texto_log)) LIKE N'%' + UPPER(@FornecedorGrupoHex) + N'%'
     OR UPPER(CONVERT(nvarchar(max), txt.texto_log)) LIKE N'%' + UPPER(@FornecedorGrupoHexSem0x) + N'%'
  )
  AND (
        txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%para%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%to%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Novo valor%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%New Value%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%->%'
  );

CREATE INDEX IX_EntradaGrupoCand_DEC_id_epoch
    ON #EntradaGrupoCand_DEC(id, prioridade_fonte, entrada_grupo_epoch);

;WITH EscolhaEntrada AS (
    SELECT
        c.*,
        ROW_NUMBER() OVER (
            PARTITION BY c.id
            ORDER BY c.prioridade_fonte ASC, c.entrada_grupo_epoch DESC
        ) AS rn
    FROM #EntradaGrupoCand_DEC AS c
)
SELECT
    id,
    entrada_grupo_epoch,
    fonte_entrada,
    detalhe_entrada
INTO #EntradaGrupo_DEC
FROM EscolhaEntrada
WHERE rn = 1;

CREATE UNIQUE CLUSTERED INDEX IX_EntradaGrupo_DEC_id ON #EntradaGrupo_DEC(id);

IF OBJECT_ID('tempdb..#InicioContagemFARC_DEC') IS NOT NULL DROP TABLE #InicioContagemFARC_DEC;

CREATE TABLE #InicioContagemFARC_DEC (
    id int NOT NULL PRIMARY KEY,
    inicio_contagem_epoch int NULL,
    fonte_inicio_contagem nvarchar(200) NOT NULL,
    detalhe_inicio_contagem nvarchar(4000) COLLATE DATABASE_DEFAULT NULL
);

INSERT INTO #InicioContagemFARC_DEC (id, inicio_contagem_epoch, fonte_inicio_contagem, detalhe_inicio_contagem)
SELECT
    e.id,
    COALESCE(eg.entrada_grupo_epoch, b.open_date) AS inicio_contagem_epoch,
    CASE
        WHEN eg.entrada_grupo_epoch IS NOT NULL
            THEN CONCAT(N'Entrada no grupo fornecedor via ', eg.fonte_entrada)
        WHEN b.open_date IS NOT NULL
            THEN N'Fallback: chamado já no grupo ou sem histórico auditável de grupo'
        ELSE N'Sem início de contagem identificado'
    END AS fonte_inicio_contagem,
    CASE
        WHEN eg.entrada_grupo_epoch IS NOT NULL THEN eg.detalhe_entrada
        ELSE NULL
    END AS detalhe_inicio_contagem
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
LEFT JOIN #EntradaGrupo_DEC AS eg
    ON eg.id = b.id;

IF OBJECT_ID('tempdb..#CapturaStatusFARC_DEC') IS NOT NULL DROP TABLE #CapturaStatusFARC_DEC;

SELECT
    b.id,
    MIN(al.system_time) AS captura_status_epoch
INTO #CapturaStatusFARC_DEC
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN #InicioContagemFARC_DEC AS ic
    ON ic.id = b.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
CROSS APPLY (
    SELECT texto_log =
        CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
        CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
) AS txt
WHERE al.system_time IS NOT NULL
  AND ic.inicio_contagem_epoch IS NOT NULL
  AND al.system_time >= ic.inicio_contagem_epoch
  AND al.type = 'ST'
  -- Nao basta o texto conter "Em andamento": linhas como
  -- "Em andamento -> Agendado" tambem contem o termo e NAO sao captura.
  AND (
        txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Status alterado de%para ''Em andamento''%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Status changed from%to ''In Progress''%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%NOVO=''Em andamento''%'
     OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%New Value=''In Progress''%'
  )
GROUP BY b.id;

CREATE UNIQUE CLUSTERED INDEX IX_CapturaStatusFARC_DEC_id ON #CapturaStatusFARC_DEC(id);

-- Preservada exatamente como estava no FARC. Ver observacao na secao [0]:
-- e calculada e nao participa da escolha final de captura.
IF OBJECT_ID('tempdb..#CapturaAtivFornecFARC_DEC') IS NOT NULL DROP TABLE #CapturaAtivFornecFARC_DEC;

SELECT
    b.id,
    MIN(al.system_time) AS primeira_atividade_fornecedor_epoch
INTO #CapturaAtivFornecFARC_DEC
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN #InicioContagemFARC_DEC AS ic
    ON ic.id = b.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
WHERE al.system_time IS NOT NULL
  AND ic.inicio_contagem_epoch IS NOT NULL
  AND al.system_time >= ic.inicio_contagem_epoch
  AND EXISTS (
      SELECT 1
      FROM #FornecedorMembros_DEC fm
      WHERE fm.contact_uuid = al.analyst
  )
GROUP BY b.id;

CREATE UNIQUE CLUSTERED INDEX IX_CapturaAtivFornecFARC_DEC_id ON #CapturaAtivFornecFARC_DEC(id);

IF OBJECT_ID('tempdb..#CapturaFARC_DEC') IS NOT NULL DROP TABLE #CapturaFARC_DEC;

SELECT
    e.id,
    COALESCE(cs.captura_status_epoch, ic.inicio_contagem_epoch) AS captura_epoch,
    CASE
        WHEN cs.captura_status_epoch IS NOT NULL THEN N'ST com destino exato para Em andamento'
        WHEN ic.inicio_contagem_epoch IS NOT NULL THEN N'Fallback: Data Abertura FARC; não houve ST posterior para Em andamento'
        ELSE N'Sem captura identificada'
    END AS fonte_captura
INTO #CapturaFARC_DEC
FROM #EscopoIds_DEC AS e
LEFT JOIN #InicioContagemFARC_DEC AS ic
    ON ic.id = e.id
LEFT JOIN #CapturaStatusFARC_DEC AS cs
    ON cs.id = e.id;

CREATE UNIQUE CLUSTERED INDEX IX_CapturaFARC_DEC_id ON #CapturaFARC_DEC(id);

--------------------------------------------------------------------------------
-- [6] Reabertura - COMPARTILHADA
-- Regra identica nas duas consultas anteriores.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Reabertura_DEC') IS NOT NULL DROP TABLE #Reabertura_DEC;

SELECT DISTINCT
    b.id,
    CAST(1 AS bit) AS houve_reabertura
INTO #Reabertura_DEC
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
WHERE
    CONVERT(nvarchar(max), ISNULL(al.type, N'')) COLLATE Latin1_General_CI_AI LIKE N'%reab%'
    OR CONVERT(nvarchar(max), ISNULL(al.description, N'')) COLLATE Latin1_General_CI_AI LIKE N'%reabert%'
    OR CONVERT(nvarchar(max), ISNULL(al.action_desc, N'')) COLLATE Latin1_General_CI_AI LIKE N'%reabert%';

CREATE UNIQUE CLUSTERED INDEX IX_Reabertura_DEC_id ON #Reabertura_DEC(id);
--------------------------------------------------------------------------------
-- [7] FARC - Fechamento Decision / Terminal FARC  (motor proprio, preservado)
--
-- No relatorio do fornecedor a coluna "Data de Fechamento Decision" bate com o
-- evento de solucao (act_log.type = 'SOLN'), nao necessariamente com close_date.
-- Regra geral: primeiro SOLN valido. Sem SOLN, usa resolve_date consistente; em
-- ultimo caso, close_date.
--
-- Excecoes validadas em rotinas de Producao de relatorios com SOLN generico:
--   - captura ate 2 min apos o inicio => primeiro LOG de conclusao do usuario;
--   - demais casos                    => captura - 1 segundo.
--
-- ATENCAO: este terminal e do FARC e e DIFERENTE do marco de encerramento do
-- FAIA (ultima entrada valida em "Em homologacao", secao [8.2]). Os dois foram
-- mantidos separados de proposito.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TerminalFARC_DEC') IS NOT NULL DROP TABLE #TerminalFARC_DEC;

SELECT
    b.id,
    CASE
        -- CORRECAO 2026-07-30 (2a): removida a exigencia de captura imediata
        -- (c.captura_epoch - ic.inicio_contagem_epoch <= 120).
        --
        -- Quando a rotina de Producao de relatorios encerra com SOLN generico
        -- ('registrar texto da solucao'), o marco real de conclusao e o LOG de
        -- conclusao. Isso NAO depende de quao rapido o analista capturou o
        -- chamado: a janela de 120 s fazia o terminal variar por um motivo sem
        -- relacao com o fim do trabalho, e jogava os chamados de captura lenta
        -- num fallback artificial (captura - 1 s).
        --
        -- Comprovado pelos logs de quatro rotinas com o MESMO padrao (SOLN
        -- placeholder + LOG de conclusao terminado em 'Solicitação atendida? Sim'):
        --   1703341  captura 43:05 depois da abertura  LOG 16:57:25  ->  0:57:25
        --   1703343  captura 43:04 depois da abertura  LOG 17:01:47  ->  1:01:46
        --   1703344  captura 43:04 depois da abertura  LOG 16:59:40  ->  0:59:39
        --   1705170  captura    59 s depois            LOG 16:13:08  ->  0:13:07
        -- O relatorio BO traz 0:57:25 (1703341) e 1:01:46 (1703343), e o motor
        -- NMS do FAIA chega aos quatro valores de forma independente. Somente o
        -- 1705170 passava pela janela de 120 s; os outros tres caiam no fallback
        -- e produziam 0:43:04 / 0:43:03 / 0:43:03.
        --
        -- O fallback 'captura - 1 s' continua existindo para o caso em que nao
        -- ha LOG de conclusao identificavel.
        WHEN sol.soln_epoch IS NOT NULL
         AND c.captura_epoch IS NOT NULL
         AND terminal_especial.producao_relatorio_soln_generico = 1
         AND ic.inicio_contagem_epoch IS NOT NULL
         AND log_conclusao.log_conclusao_epoch IS NOT NULL
            THEN log_conclusao.log_conclusao_epoch
        WHEN sol.soln_epoch IS NOT NULL
         AND c.captura_epoch IS NOT NULL
         AND terminal_especial.producao_relatorio_soln_generico = 1
            THEN CASE
                    WHEN c.captura_epoch > ic.inicio_contagem_epoch
                        THEN c.captura_epoch - 1
                    ELSE c.captura_epoch
                 END
        WHEN sol.soln_epoch IS NOT NULL
            THEN sol.soln_epoch
        WHEN b.resolve_date IS NOT NULL
         AND ic.inicio_contagem_epoch IS NOT NULL
         AND b.resolve_date >= ic.inicio_contagem_epoch
         AND (b.close_date IS NULL OR b.resolve_date <= b.close_date)
            THEN b.resolve_date
        WHEN b.close_date IS NOT NULL
            THEN b.close_date
        ELSE b.resolve_date
    END AS terminal_epoch,
    CASE
        WHEN sol.soln_epoch IS NOT NULL
         AND c.captura_epoch IS NOT NULL
         AND terminal_especial.producao_relatorio_soln_generico = 1
         AND ic.inicio_contagem_epoch IS NOT NULL
         AND log_conclusao.log_conclusao_epoch IS NOT NULL
            THEN N'LOG de conclusão - Produção de relatórios com SOLN genérico'
        WHEN sol.soln_epoch IS NOT NULL
         AND c.captura_epoch IS NOT NULL
         AND terminal_especial.producao_relatorio_soln_generico = 1
            THEN N'Captura - Produção de relatórios com SOLN genérico'
        WHEN sol.soln_epoch IS NOT NULL
            THEN N'SOLN - Data de Fechamento Decision'
        WHEN b.resolve_date IS NOT NULL
         AND ic.inicio_contagem_epoch IS NOT NULL
         AND b.resolve_date >= ic.inicio_contagem_epoch
         AND (b.close_date IS NULL OR b.resolve_date <= b.close_date)
            THEN N'resolve_date'
        WHEN b.close_date IS NOT NULL
            THEN N'close_date'
        ELSE N'resolve_date_fallback'
    END AS fonte_terminal
INTO #TerminalFARC_DEC
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
JOIN #InicioContagemFARC_DEC AS ic
    ON ic.id = b.id
LEFT JOIN #CapturaFARC_DEC AS c
    ON c.id = b.id
OUTER APPLY (
    SELECT TOP (1)
        al.system_time AS soln_epoch,
        texto_soln = CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
                     CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
    FROM dbo.act_log AS al
    WHERE al.call_req_id = b.persid
      AND al.system_time IS NOT NULL
      AND al.type = 'SOLN'
      AND ic.inicio_contagem_epoch IS NOT NULL
      AND al.system_time >= ic.inicio_contagem_epoch
      AND (b.close_date IS NULL OR al.system_time <= b.close_date)
    ORDER BY al.system_time ASC
) AS sol
OUTER APPLY (
    SELECT TOP (1)
        al.system_time AS log_conclusao_epoch,
        texto_log_conclusao = CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
                              CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
    FROM dbo.act_log AS al
    CROSS APPLY (
        SELECT texto_log =
            CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
            CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
    ) AS txt
    WHERE al.call_req_id = b.persid
      AND al.system_time IS NOT NULL
      AND al.type = 'LOG'
      AND c.captura_epoch IS NOT NULL
      AND al.system_time >= c.captura_epoch
      AND (sol.soln_epoch IS NULL OR al.system_time <= sol.soln_epoch)
      AND (b.close_date IS NULL OR al.system_time <= b.close_date)
      AND (
            txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%registrar comentário do usuário%'
         OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%registrar comentario do usuario%'
         OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Solicitação atendida? Sim%'
         OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Solicitacao atendida? Sim%'
      )
      AND txt.texto_log COLLATE Latin1_General_CI_AI NOT LIKE N'%AHD05376%'
    ORDER BY al.system_time ASC
) AS log_conclusao
OUTER APPLY (
    SELECT producao_relatorio_soln_generico = CASE
        WHEN (
                b.categoria_sym COLLATE Latin1_General_CI_AI LIKE N'%Produção de relatórios%'
             OR b.summary_txt    COLLATE Latin1_General_CI_AI LIKE N'%Envio semanal de relatório%'
             )
         AND LTRIM(RTRIM(CONVERT(nvarchar(4000), ISNULL(sol.texto_soln, N'')))) COLLATE Latin1_General_CI_AI
                IN (N'registrar texto da solução registrar texto da solução',
                    N'registrar texto da solucao registrar texto da solucao')
            THEN 1 ELSE 0
    END
) AS terminal_especial;

CREATE UNIQUE CLUSTERED INDEX IX_TerminalFARC_DEC_id ON #TerminalFARC_DEC(id);

--------------------------------------------------------------------------------
-- [7.0.1] Terminal do ULTIMO ciclo  (orientacao do gerente, 2026-10-06)
--
-- Reabertura corrige um encerramento indevido: o Tempo de Atendimento acompanha
-- todos os ciclos e termina no encerramento do ultimo. Quando ha reabertura
-- (destino 'Reaberto') no instante do terminal acima ou depois dele, o terminal
-- passa a ser o primeiro encerramento depois da ULTIMA reabertura: um SOLN ou
-- uma entrada em 'Em homologacao'. Sem esse encerramento, vale resolve_date (se
-- posterior a reabertura); senao, close_date. Os eventos sao lidos a partir do
-- inicio da contagem (ultima entrada no grupo), ou seja, dentro da posse.
-- O intervalo SOLN -> reabertura nao conta: o SOLN pausa o motor [9.2].
--------------------------------------------------------------------------------
UPDATE t
SET terminal_epoch = COALESCE(
        fe.fechamento_epoch,
        CASE WHEN b.resolve_date >= rb.reabertura_epoch THEN b.resolve_date END,
        b.close_date),
    fonte_terminal = CASE
        WHEN fe.fechamento_epoch IS NOT NULL THEN N'Encerramento do último ciclo (após reabertura)'
        WHEN b.resolve_date >= rb.reabertura_epoch THEN N'resolve_date do último ciclo (após reabertura)'
        ELSE N'close_date - último ciclo sem encerramento (após reabertura)'
    END
FROM #TerminalFARC_DEC AS t
JOIN #Base_DEC AS b
    ON b.id = t.id
JOIN #InicioContagemFARC_DEC AS ic
    ON ic.id = t.id
CROSS APPLY (
    SELECT MAX(al.system_time) AS reabertura_epoch
    FROM dbo.act_log AS al
    CROSS APPLY (
        SELECT texto_log =
            CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
            CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
    ) AS txt
    WHERE al.call_req_id = b.persid
      AND al.system_time IS NOT NULL
      AND ic.inicio_contagem_epoch IS NOT NULL
      AND al.system_time >= ic.inicio_contagem_epoch
      AND (b.close_date IS NULL OR al.system_time <= b.close_date)
      AND (   txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%alterado de%para ''Reaberto''%'
           OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%changed from%to ''Reopened''%')
) AS rb
OUTER APPLY (
    SELECT MIN(al.system_time) AS fechamento_epoch
    FROM dbo.act_log AS al
    CROSS APPLY (
        SELECT texto_log =
            CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
            CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
    ) AS txt
    WHERE al.call_req_id = b.persid
      AND al.system_time IS NOT NULL
      AND al.system_time > rb.reabertura_epoch
      AND (b.close_date IS NULL OR al.system_time <= b.close_date)
      AND (   al.type = 'SOLN'
           OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%alterado de%para ''Em homologação''%')
) AS fe
WHERE rb.reabertura_epoch IS NOT NULL
  AND t.terminal_epoch IS NOT NULL
  AND rb.reabertura_epoch >= t.terminal_epoch;

--------------------------------------------------------------------------------
-- [7.1] Base final do FAIA, com datas em horario do Brasil
-- Contem SOMENTE os chamados do escopo FAIA, exatamente como antes.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#BaseEscopoFAIA_DEC') IS NOT NULL DROP TABLE #BaseEscopoFAIA_DEC;

SELECT
    b.*,
    e.FonteFornecedorFAIA AS FonteFornecedor,
    ic.inicio_contagem_epoch,
    ic.fonte_inicio_contagem,
    COALESCE(c.captura_epoch, ic.inicio_contagem_epoch) AS captura_epoch,
    -- Marco interno do FAIA/primeiro atendimento: pode ser posterior a abertura
    -- original quando o chamado nasceu em outro grupo.
    CASE WHEN ic.inicio_contagem_epoch IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, ic.inicio_contagem_epoch, @Epoch))
    END AS data_abertura_br,
    CASE WHEN COALESCE(c.captura_epoch, ic.inicio_contagem_epoch) IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, COALESCE(c.captura_epoch, ic.inicio_contagem_epoch), @Epoch))
    END AS data_captura_br,
    CASE WHEN b.close_date IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.close_date, @Epoch))
    END AS data_fechamento_br
INTO #BaseEscopoFAIA_DEC
FROM #EscopoFAIA_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
LEFT JOIN #InicioContagemFAIA_DEC AS ic
    ON ic.id = b.id
LEFT JOIN #CapturaFAIA_DEC AS c
    ON c.id = b.id;

CREATE UNIQUE CLUSTERED INDEX IX_BaseEscopoFAIA_DEC_id ON #BaseEscopoFAIA_DEC(id);
CREATE INDEX IX_BaseEscopoFAIA_DEC_persid ON #BaseEscopoFAIA_DEC(persid);

--------------------------------------------------------------------------------
-- [7.2] Base final do FARC, com datas em horario do Brasil
-- Contem TODOS os chamados do escopo unificado; e a base de linhas do resultado.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#BaseEscopoFARC_DEC') IS NOT NULL DROP TABLE #BaseEscopoFARC_DEC;

SELECT
    b.*,
    e.FonteFornecedor,
    ic.inicio_contagem_epoch,
    ic.fonte_inicio_contagem,
    ic.detalhe_inicio_contagem,
    COALESCE(c.captura_epoch, ic.inicio_contagem_epoch) AS captura_epoch,
    t.terminal_epoch AS fechamento_decision_epoch,
    t.fonte_terminal,
    CASE WHEN ic.inicio_contagem_epoch IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, ic.inicio_contagem_epoch, @Epoch))
    END AS data_abertura_br,
    CASE WHEN COALESCE(c.captura_epoch, ic.inicio_contagem_epoch) IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, COALESCE(c.captura_epoch, ic.inicio_contagem_epoch), @Epoch))
    END AS data_captura_br,
    CASE WHEN b.resolve_date IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.resolve_date, @Epoch))
    END AS data_resolucao_br,
    CASE WHEN t.terminal_epoch IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, t.terminal_epoch, @Epoch))
    END AS data_fechamento_decision_br,
    CASE WHEN b.close_date IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.close_date, @Epoch))
    END AS data_fechamento_cliente_br,
    -- Mantem o nome usado no motor do FARC, com o marco do relatorio:
    -- Data de Fechamento Decision.
    CASE WHEN t.terminal_epoch IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, t.terminal_epoch, @Epoch))
    END AS data_fechamento_br,
    CASE WHEN r.houve_reabertura = 1 THEN N'Sim' ELSE N'Não' END AS indicador_reabertura
INTO #BaseEscopoFARC_DEC
FROM #EscopoIds_DEC AS e
JOIN #Base_DEC AS b
    ON b.id = e.id
LEFT JOIN #InicioContagemFARC_DEC AS ic
    ON ic.id = b.id
LEFT JOIN #CapturaFARC_DEC AS c
    ON c.id = b.id
LEFT JOIN #TerminalFARC_DEC AS t
    ON t.id = b.id
LEFT JOIN #Reabertura_DEC AS r
    ON r.id = b.id;

CREATE UNIQUE CLUSTERED INDEX IX_BaseEscopoFARC_DEC_id ON #BaseEscopoFARC_DEC(id);
CREATE INDEX IX_BaseEscopoFARC_DEC_persid ON #BaseEscopoFARC_DEC(persid);

--------------------------------------------------------------------------------
-- [7.3] #Nums_DEC - COMPARTILHADA pelos dois motores
--
-- Dimensionada pelo MAIOR intervalo necessario entre os dois indicadores:
--   FAIA: open_date -> close_date (linha do tempo completa do chamado);
--   FARC: data_abertura_br -> data_fechamento_decision_br.
-- O primeiro cobre o segundo, mas o MAX explicito garante que nenhum dos dois
-- motores fique sem linhas se a base mudar.
--------------------------------------------------------------------------------
DECLARE @MaxDiasFAIA_DEC int =
(
    SELECT ISNULL(MAX(
        CASE
            WHEN b.open_date IS NOT NULL
             AND b.close_date IS NOT NULL
             AND b.close_date >= b.open_date
            THEN DATEDIFF(
                    DAY,
                    CAST(DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.open_date, @Epoch)) AS date),
                    CAST(DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.close_date, @Epoch)) AS date)
                 )
            ELSE 0
        END
    ), 0)
    FROM #BaseEscopoFARC_DEC AS b
);

DECLARE @MaxDiasFARC_DEC int =
(
    SELECT ISNULL(MAX(
        CASE
            WHEN data_abertura_br IS NOT NULL
             AND data_fechamento_decision_br IS NOT NULL
             AND data_fechamento_decision_br >= data_abertura_br
            THEN DATEDIFF(DAY, CAST(data_abertura_br AS date), CAST(data_fechamento_decision_br AS date))
            ELSE 0
        END
    ), 0)
    FROM #BaseEscopoFARC_DEC
);

DECLARE @MaxDias_DEC int =
    CASE WHEN @MaxDiasFAIA_DEC >= @MaxDiasFARC_DEC THEN @MaxDiasFAIA_DEC ELSE @MaxDiasFARC_DEC END;

IF OBJECT_ID('tempdb..#Nums_DEC') IS NOT NULL DROP TABLE #Nums_DEC;
CREATE TABLE #Nums_DEC (n int NOT NULL PRIMARY KEY);

INSERT INTO #Nums_DEC(n)
SELECT TOP (@MaxDias_DEC + 1)
       ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
FROM sys.all_objects a
CROSS JOIN sys.all_objects b;
--------------------------------------------------------------------------------
-- [7.4] #AtosDEC - act_log dos chamados do escopo, materializado UMA VEZ
--
-- MOTIVO (medicao real de 2026-08-20, 662 s no total):
--   [8.2] = 128.723 ms, [8.7] = 218.668 ms, [9.4] = 281.742 ms, ~95% do tempo.
--   Os tres liam dbo.act_log de novo a cada bloco e, nos APPLY correlacionados,
--   uma vez por LINHA. So [8.2] fazia cinco acessos, dois deles correlacionados
--   com LIKE sobre nvarchar(max). Alem disso, cada bloco reconstruia o mesmo
--   texto (description + action_desc) do zero.
--
-- Esta tabela le dbo.act_log UMA unica vez, ja com o texto concatenado, e passa
-- a ser a fonte dos blocos caros. NENHUMA REGRA MUDA: as colunas [type] e
-- system_time mantem os nomes originais de dbo.act_log, e texto_log e
-- exatamente a mesma expressao que cada bloco calculava.
--
-- Tipos: os unicos que a consulta consome depois deste ponto. 'TR' fica de fora
-- porque [3.1] roda antes de #BaseEscopoFARC_DEC existir e custa 5,5 s.
--
-- Escopo: #BaseEscopoFARC_DEC, que e o escopo UNIFICADO. O escopo do FAIA e
-- subconjunto estrito dele ([3.2] filtra #EscopoIds_DEC), entao esta tabela
-- cobre os dois motores.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#AtosDEC') IS NOT NULL DROP TABLE #AtosDEC;

SELECT
    b.id,
    b.persid,
    al.[type],
    al.system_time,
    CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
    CONVERT(nvarchar(max), ISNULL(al.action_desc,  N'')) AS texto_log
INTO #AtosDEC
FROM #BaseEscopoFARC_DEC AS b
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
WHERE al.system_time IS NOT NULL
  AND al.[type] IN ('ST', 'CL', 'SOLN', 'LOG', 'SRVY_SENT', 'RE', 'RO');

CREATE CLUSTERED INDEX IX_AtosDEC_id_tipo_epoch
    ON #AtosDEC(id, [type], system_time);

--------------------------------------------------------------------------------
-- [7.5] #ParesBaseSolnSrvy_DEC - pares SOLN -> SRVY_SENT calculados UMA VEZ
--
-- [8.7] (FAIA) e [9.4] (FARC) usavam pareamento IDENTICO - mesma ancora, mesmos
-- limites, mesmos predicados - diferindo apenas na base que os dirigia e no
-- formato de saida. Como #EscopoFAIA_DEC e subconjunto de #EscopoIds_DEC e as
-- duas bases herdam persid, open_date e close_date do mesmo #Base_DEC, calcular
-- sobre o escopo FARC e depois restringir ao escopo FAIA produz exatamente as
-- mesmas linhas que o calculo separado produzia.
--
-- A regra de pareamento e a de [8.7], reproduzida sem alteracao: para cada SOLN
-- dentro de open_date..close_date, o PRIMEIRO SRVY_SENT posterior a ele, anterior
-- ao PROXIMO SOLN e ainda dentro de close_date.
--
-- O 'proximo SOLN' sai de LEAD sobre os SOLN distintos, o que substitui a
-- subconsulta correlacionada que era executada uma vez por linha. LEAD sobre os
-- valores distintos ordenados devolve o mesmo que MIN(system_time) restrito a
-- system_time > soln_epoch: ambos sao o menor SOLN estritamente maior.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#SolnProx_DEC') IS NOT NULL DROP TABLE #SolnProx_DEC;

SELECT
    d.id,
    d.soln_epoch,
    LEAD(d.soln_epoch) OVER (PARTITION BY d.id ORDER BY d.soln_epoch) AS proximo_soln_epoch
INTO #SolnProx_DEC
FROM (
    SELECT DISTINCT a.id, a.system_time AS soln_epoch
    FROM #AtosDEC AS a
    WHERE a.[type] = 'SOLN'
) AS d;

CREATE UNIQUE CLUSTERED INDEX IX_SolnProx_DEC ON #SolnProx_DEC(id, soln_epoch);

IF OBJECT_ID('tempdb..#ParesBaseSolnSrvy_DEC') IS NOT NULL DROP TABLE #ParesBaseSolnSrvy_DEC;

-- MIN sobre os SRVY_SENT que satisfazem os tres predicados = o PRIMEIRO deles,
-- que e o que o OUTER APPLY original devolvia. O JOIN (e nao LEFT JOIN) descarta
-- o SOLN sem par, exatamente como fazia o WHERE srvy_epoch IS NOT NULL. E o
-- predicado sv.system_time > s.soln_epoch ja garante intervalo positivo.
SELECT
    b.id,
    b.persid,
    s.soln_epoch,
    MIN(sv.system_time) AS srvy_epoch
INTO #ParesBaseSolnSrvy_DEC
FROM #BaseEscopoFARC_DEC AS b
JOIN #SolnProx_DEC AS s
    ON s.id = b.id
JOIN #AtosDEC AS sv
    ON  sv.id = b.id
    AND sv.[type] = 'SRVY_SENT'
    AND sv.system_time > s.soln_epoch
    AND (s.proximo_soln_epoch IS NULL OR sv.system_time < s.proximo_soln_epoch)
    AND sv.system_time <= b.close_date
WHERE b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND s.soln_epoch >= b.open_date
  AND s.soln_epoch <= b.close_date
GROUP BY b.id, b.persid, s.soln_epoch;

CREATE UNIQUE CLUSTERED INDEX IX_ParesBaseSolnSrvy_DEC
    ON #ParesBaseSolnSrvy_DEC(id, soln_epoch);

--------------------------------------------------------------------------------
-- [8] MOTOR NMS DO FAIA - Tempo Total Decision, Tempo suspenso e datas
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- [8.0] Limites da linha do tempo oficial
--
-- As metricas percorrem todo o historico entre a abertura original e o
-- encerramento total do SDM. A intersecao posterior com as janelas de posse
-- elimina o tempo de outros grupos. SOLN/LOG/CL nao truncam fisicamente essa
-- janela: entram como mudancas semanticas de status.
--
-- IMPORTANTE (regra do ciclo): o limite superior e o close_date do chamado e o
-- inferior e o open_date. A janela @InicioBrasil/@FimBrasilExclusivo so seleciona quais
-- chamados entram; ele NAO corta a linha do tempo. Um chamado fechado dentro do
-- ciclo mas com suspensao iniciada antes dele conta a suspensao inteira.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Limites_DEC') IS NOT NULL DROP TABLE #Limites_DEC;

SELECT
    b.id,
    b.persid,
    b.open_date AS inicio_timeline_epoch,
    b.close_date AS fim_timeline_epoch
INTO #Limites_DEC
FROM #BaseEscopoFAIA_DEC AS b
WHERE b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND b.close_date >= b.open_date;

CREATE UNIQUE CLUSTERED INDEX IX_Limites_DEC_persid
    ON #Limites_DEC(persid);
CREATE INDEX IX_Limites_DEC_id ON #Limites_DEC(id);

--------------------------------------------------------------------------------
-- [8.1] Janelas completas de posse da Decision
--
-- O chamado pode entrar, sair e voltar para a Decision. Somar continuamente da
-- primeira entrada ate o fechamento incluiria, indevidamente, os periodos em
-- outros grupos.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#GrupoInicial_DEC') IS NOT NULL DROP TABLE #GrupoInicial_DEC;
IF OBJECT_ID('tempdb..#JanelasPosse_DEC') IS NOT NULL DROP TABLE #JanelasPosse_DEC;

SELECT
    b.id,
    b.persid,
    b.open_date AS evento_inicial_epoch,
    CONVERT(bit, CASE
        WHEN primeiro.origem_decision IS NOT NULL THEN primeiro.origem_decision
        -- Todos os chamados de #BaseEscopoFAIA_DEC encerram no grupo Decision.
        -- Sem qualquer transferencia registrada, nasceram e permaneceram no grupo.
        ELSE 1
    END) AS posse_inicial_decision
INTO #GrupoInicial_DEC
FROM #BaseEscopoFAIA_DEC AS b
OUTER APPLY (
    SELECT TOP (1)
        g.origem_decision
    FROM #GrupoEventos_DEC AS g
    WHERE g.id = b.id
    ORDER BY g.evento_epoch ASC, g.destino_decision DESC
) AS primeiro
WHERE b.open_date IS NOT NULL;

CREATE UNIQUE CLUSTERED INDEX IX_GrupoInicial_DEC_id
    ON #GrupoInicial_DEC(id);

;WITH TimelineGrupo AS (
    SELECT
        gi.id,
        gi.persid,
        gi.evento_inicial_epoch AS evento_epoch,
        gi.posse_inicial_decision AS em_posse,
        CONVERT(tinyint, 0) AS ordem_evento
    FROM #GrupoInicial_DEC AS gi

    UNION ALL

    SELECT
        b.id,
        b.persid,
        g.evento_epoch,
        g.destino_decision AS em_posse,
        CONVERT(tinyint, 1) AS ordem_evento
    FROM #BaseEscopoFAIA_DEC AS b
    JOIN #GrupoEventos_DEC AS g
        ON g.id = b.id
), OrdenadoGrupo AS (
    SELECT
        t.id,
        t.persid,
        t.evento_epoch,
        t.em_posse,
        LEAD(t.evento_epoch) OVER (
            PARTITION BY t.id
            ORDER BY t.evento_epoch ASC, t.ordem_evento ASC, t.em_posse ASC
        ) AS proximo_epoch
    FROM TimelineGrupo AS t
)
SELECT
    o.id,
    o.persid,
    o.evento_epoch AS inicio_posse_epoch,
    limite.fim_epoch AS fim_posse_epoch
INTO #JanelasPosse_DEC
FROM OrdenadoGrupo AS o
JOIN #Limites_DEC AS ld
    ON ld.persid = o.persid
CROSS APPLY (
    SELECT fim_epoch = CASE
        WHEN COALESCE(o.proximo_epoch, ld.fim_timeline_epoch) > ld.fim_timeline_epoch
            THEN ld.fim_timeline_epoch
        ELSE COALESCE(o.proximo_epoch, ld.fim_timeline_epoch)
    END
) AS limite
WHERE o.em_posse = 1
  AND o.evento_epoch < ld.fim_timeline_epoch
  AND limite.fim_epoch > o.evento_epoch;

CREATE INDEX IX_JanelasPosse_DEC_persid
    ON #JanelasPosse_DEC(persid, inicio_posse_epoch, fim_posse_epoch);
CREATE INDEX IX_JanelasPosse_DEC_id
    ON #JanelasPosse_DEC(id, inicio_posse_epoch, fim_posse_epoch);

IF OBJECT_ID('tempdb..#TotaisPosse_DEC') IS NOT NULL DROP TABLE #TotaisPosse_DEC;

SELECT
    j.persid,
    SUM(CONVERT(bigint, j.fim_posse_epoch) - CONVERT(bigint, j.inicio_posse_epoch)) AS segundos_total_janelas
INTO #TotaisPosse_DEC
FROM #JanelasPosse_DEC AS j
GROUP BY j.persid;

CREATE UNIQUE CLUSTERED INDEX IX_TotaisPosse_DEC_persid
    ON #TotaisPosse_DEC(persid);

--------------------------------------------------------------------------------
-- [8.2] Segmentos de status: o DESTINO do evento vale ate o proximo evento
--
-- ST continua sendo a fonte principal. CL tambem e lido quando sua descricao traz
-- uma transicao textual real; RO grava a reabertura ('X' -> 'Reaberto') e RE, a
-- ida para homologacao. Quando a homologacao nao vem como ST/RE, cada SOLN valido
-- produz um evento implicito com destino "Em homologacao". Na
-- excecao comprovada de Producao de relatorios, o LOG de conclusao real
-- substitui o SOLN generico posterior.
--
-- A allowlist de #RegrasStatus_DEC e positiva: somente os quatro estados oficiais
-- (e traducoes conhecidas) sao ATIVOS; todo o restante e SUSPENSO. Eventos no
-- mesmo segundo recebem prioridade deterministica por fonte.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#StatusRaw_DEC') IS NOT NULL DROP TABLE #StatusRaw_DEC;
IF OBJECT_ID('tempdb..#StatusEventos_DEC') IS NOT NULL DROP TABLE #StatusEventos_DEC;
IF OBJECT_ID('tempdb..#MarcosSolucao_DEC') IS NOT NULL DROP TABLE #MarcosSolucao_DEC;
IF OBJECT_ID('tempdb..#Encerramento_DEC') IS NOT NULL DROP TABLE #Encerramento_DEC;
IF OBJECT_ID('tempdb..#LogEstados_DEC') IS NOT NULL DROP TABLE #LogEstados_DEC;

SELECT
    b.id,
    b.persid,
    CONVERT(varchar(10), al.type) AS tipo_log,
    al.system_time AS evento_epoch,
    CONVERT(nvarchar(400), SUBSTRING(txt.texto_log, ancora.posicao, 400)) AS resto
INTO #StatusRaw_DEC
FROM #BaseEscopoFAIA_DEC AS b
JOIN #AtosDEC AS al
    ON al.id = b.id
CROSS APPLY (
    SELECT texto_log = al.texto_log
) AS txt
CROSS APPLY (
    SELECT posicao = CASE
        WHEN CHARINDEX(N'alterado de', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'alterado de', txt.texto_log COLLATE Latin1_General_CI_AI) + 11
        WHEN CHARINDEX(N'changed from', txt.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'changed from', txt.texto_log COLLATE Latin1_General_CI_AI) + 12
        ELSE 0
    END
) AS ancora
-- RE: sem ele, o status anterior a homologacao ('Em andamento', ativo) seguia
-- correndo ate o proximo ST/CL, em geral o encerramento do chamado.
WHERE al.type IN ('ST', 'CL', 'RO', 'RE')
  AND al.system_time IS NOT NULL
  AND ancora.posicao > 0
  AND b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND al.system_time >= b.open_date
  AND al.system_time <= b.close_date;

CREATE INDEX IX_StatusRaw_DEC_id_epoch
    ON #StatusRaw_DEC(id, evento_epoch);

SELECT
    s.id,
    s.persid,
    s.evento_epoch,
    CONVERT(nvarchar(200), LTRIM(RTRIM(origem.nome))) AS status_origem,
    CONVERT(nvarchar(200), LTRIM(RTRIM(destino.nome))) AS status_destino,
    CONVERT(varchar(10), COALESCE(regra_destino.tipo_status, 'SUSPENSO'))
        COLLATE SQL_Latin1_General_CP1_CI_AS AS tipo_status_destino,
    CONVERT(varchar(10), COALESCE(regra_origem.tipo_status, 'SUSPENSO'))
        COLLATE SQL_Latin1_General_CP1_CI_AS AS tipo_status_origem,
    CONVERT(bit, CASE WHEN regra_destino.status_nome IS NULL THEN 0 ELSE 1 END) AS status_destino_conhecido,
    CONVERT(bit, CASE WHEN regra_origem.status_nome  IS NULL THEN 0 ELSE 1 END) AS status_origem_conhecido,
    CONVERT(bit, ISNULL(regra_destino.eh_homologacao_decision, 0)) AS eh_homologacao_destino,
    CONVERT(varchar(10), s.tipo_log) AS fonte_evento
INTO #StatusEventos_DEC
FROM #StatusRaw_DEC AS s
CROSS APPLY (SELECT q1 = CHARINDEX(N'''', s.resto)) AS c1
CROSS APPLY (SELECT q2 = CASE WHEN c1.q1 > 0 THEN CHARINDEX(N'''', s.resto, c1.q1 + 1) ELSE 0 END) AS c2
CROSS APPLY (
    SELECT nome = CASE
        WHEN c2.q2 > c1.q1 THEN SUBSTRING(s.resto, c1.q1 + 1, c2.q2 - c1.q1 - 1)
        ELSE N''
    END
) AS origem
CROSS APPLY (
    SELECT posicao = CASE
        WHEN c2.q2 > 0 AND CHARINDEX(N' para ', s.resto COLLATE Latin1_General_CI_AI, c2.q2) > 0
            THEN CHARINDEX(N' para ', s.resto COLLATE Latin1_General_CI_AI, c2.q2)
        WHEN c2.q2 > 0
            THEN CHARINDEX(N' to ', s.resto COLLATE Latin1_General_CI_AI, c2.q2)
        ELSE 0
    END
) AS separador
CROSS APPLY (SELECT q3 = CASE WHEN separador.posicao > 0 THEN CHARINDEX(N'''', s.resto, separador.posicao) ELSE 0 END) AS c3
CROSS APPLY (SELECT q4 = CASE WHEN c3.q3 > 0 THEN CHARINDEX(N'''', s.resto, c3.q3 + 1) ELSE 0 END) AS c4
CROSS APPLY (
    SELECT nome = CASE
        WHEN c4.q4 > c3.q3 THEN SUBSTRING(s.resto, c3.q3 + 1, c4.q4 - c3.q3 - 1)
        ELSE N''
    END
) AS destino
OUTER APPLY (
    SELECT TOP (1)
        r.status_nome,
        r.tipo_status,
        r.eh_homologacao_decision
    FROM #RegrasStatus_DEC AS r
    WHERE r.status_nome = LTRIM(RTRIM(destino.nome)) COLLATE Latin1_General_CI_AI
) AS regra_destino
OUTER APPLY (
    SELECT TOP (1)
        r.status_nome,
        r.tipo_status
    FROM #RegrasStatus_DEC AS r
    WHERE r.status_nome = LTRIM(RTRIM(origem.nome)) COLLATE Latin1_General_CI_AI
) AS regra_origem
WHERE c1.q1 > 0
  AND c2.q2 > c1.q1
  AND separador.posicao > 0
  AND c3.q3 > 0
  AND c4.q4 > c3.q3
  AND NULLIF(LTRIM(RTRIM(origem.nome)), N'') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(destino.nome)), N'') IS NOT NULL;

-- Formato alternativo em que o log traz somente NOVO=/New Value=.
INSERT INTO #StatusEventos_DEC
    (id, persid, evento_epoch, status_origem, status_destino,
     tipo_status_destino, tipo_status_origem,
     status_destino_conhecido, status_origem_conhecido,
     eh_homologacao_destino, fonte_evento)
SELECT
    b.id,
    b.persid,
    al.system_time AS evento_epoch,
    CONVERT(nvarchar(200), N'') AS status_origem,
    CONVERT(nvarchar(200), LTRIM(RTRIM(destino_unico.nome))) AS status_destino,
    CONVERT(varchar(10), COALESCE(regra_destino.tipo_status, 'SUSPENSO'))
        COLLATE SQL_Latin1_General_CP1_CI_AS AS tipo_status_destino,
    CONVERT(varchar(10), 'ATIVO') COLLATE SQL_Latin1_General_CP1_CI_AS AS tipo_status_origem,
    CONVERT(bit, CASE WHEN regra_destino.status_nome IS NULL THEN 0 ELSE 1 END) AS status_destino_conhecido,
    CONVERT(bit, 0) AS status_origem_conhecido,
    CONVERT(bit, ISNULL(regra_destino.eh_homologacao_decision, 0)) AS eh_homologacao_destino,
    CONVERT(varchar(10), 'NOVO') AS fonte_evento
FROM #BaseEscopoFAIA_DEC AS b
JOIN #AtosDEC AS al
    ON al.id = b.id
CROSS APPLY (
    SELECT texto_log = al.texto_log
) AS txt_unico
CROSS APPLY (
    SELECT posicao = CASE
        WHEN CHARINDEX(N'NOVO=', txt_unico.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'NOVO=', txt_unico.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'NOVO=')
        WHEN CHARINDEX(N'New Value=', txt_unico.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'New Value=', txt_unico.texto_log COLLATE Latin1_General_CI_AI) + LEN(N'New Value=')
        ELSE 0
    END
) AS ancora_unica
CROSS APPLY (
    SELECT resto = CONVERT(nvarchar(400), SUBSTRING(txt_unico.texto_log, ancora_unica.posicao, 400))
) AS trecho_unico
CROSS APPLY (SELECT q1 = CHARINDEX(N'''', trecho_unico.resto)) AS u1
CROSS APPLY (SELECT q2 = CASE WHEN u1.q1 > 0 THEN CHARINDEX(N'''', trecho_unico.resto, u1.q1 + 1) ELSE 0 END) AS u2
CROSS APPLY (
    SELECT nome = CASE
        WHEN u2.q2 > u1.q1 THEN SUBSTRING(trecho_unico.resto, u1.q1 + 1, u2.q2 - u1.q1 - 1)
        ELSE N''
    END
) AS destino_unico
OUTER APPLY (
    SELECT TOP (1)
        r.status_nome,
        r.tipo_status,
        r.eh_homologacao_decision
    FROM #RegrasStatus_DEC AS r
    WHERE r.status_nome = LTRIM(RTRIM(destino_unico.nome)) COLLATE Latin1_General_CI_AI
) AS regra_destino
WHERE al.type IN ('ST', 'CL')
  AND al.system_time IS NOT NULL
  AND ancora_unica.posicao > 0
  AND b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND al.system_time >= b.open_date
  AND al.system_time <= b.close_date
  AND u1.q1 > 0
  AND u2.q2 > u1.q1
  AND NULLIF(LTRIM(RTRIM(destino_unico.nome)), N'') IS NOT NULL
  AND NOT EXISTS (
        SELECT 1
        FROM #StatusEventos_DEC AS s
        WHERE s.id = b.id
          AND s.evento_epoch = al.system_time
          AND LTRIM(RTRIM(s.status_destino)) COLLATE Latin1_General_CI_AI
                = LTRIM(RTRIM(destino_unico.nome)) COLLATE Latin1_General_CI_AI
  );
-- O relatorio usa o instante do SOLN como inicio implicito de "Em homologacao"
-- quando nao existe ST correspondente. O time_spent do SOLN NAO participa do
-- calculo. Para Producao de relatorios com SOLN estritamente generico, o ultimo
-- LOG de conclusao real e o marco de homologacao, INDEPENDENTEMENTE do tempo
-- entre a abertura e a captura (casos comprovados 1705166 e 1703341).
SELECT DISTINCT
    b.id,
    b.persid,
    CASE
        WHEN especial.usar_log_conclusao = 1
         AND log_conclusao.log_conclusao_epoch IS NOT NULL
            THEN log_conclusao.log_conclusao_epoch
        ELSE sol.system_time
    END AS evento_epoch,
    CONVERT(varchar(10), CASE
        WHEN especial.usar_log_conclusao = 1
         AND log_conclusao.log_conclusao_epoch IS NOT NULL
            THEN 'LOG'
        ELSE 'SOLN'
    END) AS fonte_evento
INTO #MarcosSolucao_DEC
FROM #BaseEscopoFAIA_DEC AS b
JOIN #AtosDEC AS sol
    ON sol.id = b.id
   AND sol.type = 'SOLN'
   AND sol.system_time IS NOT NULL
CROSS APPLY (
    SELECT texto_soln = sol.texto_log
) AS texto_soln
OUTER APPLY (
    SELECT MAX(anterior.system_time) AS soln_anterior_epoch
    FROM #AtosDEC AS anterior
    WHERE anterior.id = b.id
      AND anterior.type = 'SOLN'
      AND anterior.system_time IS NOT NULL
      AND anterior.system_time < sol.system_time
) AS soln_anterior
OUTER APPLY (
    SELECT TOP (1)
        al.system_time AS log_conclusao_epoch
    FROM #AtosDEC AS al
    CROSS APPLY (
        SELECT texto_log = al.texto_log
    ) AS txt
    WHERE al.id = b.id
      AND al.type = 'LOG'
      AND al.system_time IS NOT NULL
      AND al.system_time >= COALESCE(
            soln_anterior.soln_anterior_epoch,
            b.captura_epoch,
            b.inicio_contagem_epoch,
            b.open_date
          )
      AND al.system_time <= sol.system_time
      AND (
            txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%registrar comentário do usuário%'
         OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%registrar comentario do usuario%'
         OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Solicitação atendida? Sim%'
         OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%Solicitacao atendida? Sim%'
      )
      AND txt.texto_log COLLATE Latin1_General_CI_AI NOT LIKE N'%AHD05376%'
    ORDER BY al.system_time DESC
) AS log_conclusao
CROSS APPLY (
    -- Marco de conclusao das rotinas "Producao de relatorios" (envio semanal):
    -- o SOLN gravado nesses chamados e um placeholder generico; a conclusao real
    -- e o LOG de comentario do usuario que o precede. A escolha do LOG NAO depende
    -- de a captura ter sido imediata: no 1703341 a captura ocorreu ~43 min apos a
    -- abertura e o marco correto continua sendo o LOG. Por isso a antiga janela
    -- "captura - inicio BETWEEN 0 AND 120" foi removida.
    SELECT usar_log_conclusao = CASE
        WHEN (
                b.categoria_sym COLLATE Latin1_General_CI_AI LIKE N'%Produção de relatórios%'
             OR b.summary_txt    COLLATE Latin1_General_CI_AI LIKE N'%Envio semanal de relatório%'
             )
         AND LTRIM(RTRIM(CONVERT(nvarchar(4000), texto_soln.texto_soln))) COLLATE Latin1_General_CI_AI
                IN (N'registrar texto da solução registrar texto da solução',
                    N'registrar texto da solucao registrar texto da solucao')
            THEN 1 ELSE 0
    END
) AS especial
WHERE b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND sol.system_time >= b.open_date
  AND sol.system_time <= b.close_date;

CREATE INDEX IX_MarcosSolucao_DEC_id_epoch
    ON #MarcosSolucao_DEC(id, evento_epoch);

INSERT INTO #StatusEventos_DEC
    (id, persid, evento_epoch, status_origem, status_destino,
     tipo_status_destino, tipo_status_origem,
     status_destino_conhecido, status_origem_conhecido,
     eh_homologacao_destino, fonte_evento)
SELECT
    m.id,
    m.persid,
    m.evento_epoch,
    CONVERT(nvarchar(200), N'') AS status_origem,
    CONVERT(nvarchar(200), N'Em homologação') AS status_destino,
    CONVERT(varchar(10), 'SUSPENSO') COLLATE SQL_Latin1_General_CP1_CI_AS,
    CONVERT(varchar(10), 'ATIVO')    COLLATE SQL_Latin1_General_CP1_CI_AS,
    CONVERT(bit, 1),
    CONVERT(bit, 0),
    CONVERT(bit, 1),
    m.fonte_evento
FROM #MarcosSolucao_DEC AS m
WHERE NOT EXISTS (
    SELECT 1
    FROM #StatusEventos_DEC AS s
    WHERE s.id = m.id
      AND s.evento_epoch = m.evento_epoch
      AND s.eh_homologacao_destino = 1
);

CREATE INDEX IX_StatusEventos_DEC_id_epoch
    ON #StatusEventos_DEC(id, evento_epoch, status_destino);

--------------------------------------------------------------------------------
-- [8.3] Data de Encerramento Decision - uma linha por chamado
--
-- A homologacao precisa ocorrer durante uma janela de posse da Decision e
-- representar ENTRADA no estado, nao apenas novo registro quando o chamado ja
-- estava homologado. Isso mantem ciclos de reabertura:
-- homologacao -> Reaberto -> trabalho -> nova homologacao.
--------------------------------------------------------------------------------
;WITH EventosComOrdem AS (
    SELECT
        s.*,
        LAG(s.eh_homologacao_destino, 1, CONVERT(bit, 0)) OVER (
            PARTITION BY s.id
            ORDER BY
                s.evento_epoch,
                CASE s.fonte_evento
                    WHEN 'LOG'  THEN 1
                    WHEN 'SOLN' THEN 2
                    WHEN 'ST'   THEN 3
                    WHEN 'NOVO' THEN 4
                    WHEN 'CL'   THEN 5
                    ELSE 9
                END,
                s.status_destino
        ) AS evento_anterior_era_homologacao
    FROM #StatusEventos_DEC AS s
), HomologacoesValidas AS (
    SELECT
        s.id,
        s.persid,
        s.evento_epoch,
        s.fonte_evento
    FROM EventosComOrdem AS s
    WHERE s.eh_homologacao_destino = 1
      AND s.evento_anterior_era_homologacao = 0
      AND EXISTS (
            SELECT 1
            FROM #JanelasPosse_DEC AS j
            JOIN #Limites_DEC AS ld
                ON ld.id = j.id
            WHERE j.id = s.id
              AND s.evento_epoch >= j.inicio_posse_epoch
              AND (
                    s.evento_epoch < j.fim_posse_epoch
                 OR (
                        s.evento_epoch = j.fim_posse_epoch
                    AND j.fim_posse_epoch = ld.fim_timeline_epoch
                    )
              )
      )
), HomologacoesOrdenadas AS (
    SELECT
        h.*,
        COUNT(*) OVER (PARTITION BY h.id) AS qtd_homologacoes,
        ROW_NUMBER() OVER (
            PARTITION BY h.id
            ORDER BY h.evento_epoch DESC,
                     CASE h.fonte_evento
                         WHEN 'ST'   THEN 1
                         WHEN 'NOVO' THEN 2
                         WHEN 'LOG'  THEN 3
                         WHEN 'SOLN' THEN 4
                         ELSE 9
                     END
        ) AS rn_ultima
    FROM HomologacoesValidas AS h
)
SELECT
    b.id,
    b.persid,
    h.evento_epoch AS encerramento_decision_epoch,
    ISNULL(h.qtd_homologacoes, 0) AS qtd_homologacoes,
    h.fonte_evento AS fonte_encerramento_decision
INTO #Encerramento_DEC
FROM #BaseEscopoFAIA_DEC AS b
LEFT JOIN HomologacoesOrdenadas AS h
    ON h.id = b.id
   AND h.rn_ultima = 1;

CREATE UNIQUE CLUSTERED INDEX IX_Encerramento_DEC_persid
    ON #Encerramento_DEC(persid);
CREATE INDEX IX_Encerramento_DEC_id ON #Encerramento_DEC(id);
--------------------------------------------------------------------------------
-- [8.3.1] FALLBACK do encerramento: entrada em homologacao gravada como 'RE'
--
-- EVIDENCIA (enc-5, 32 chamados da janela de seis ciclos):
--   ENTRADA_homolog_por_ST_CL = 0   nos 32
--   ENTRADA_homolog_por_RE   >= 1   nos 32
--   QtdSOLN = 0 e QtdSRVY_SENT = 0  nos 32
--   Nesses chamados o SDM gravou a entrada em 'Em homologacao' como
--   act_log.type = 'RE'. Quando [8.2] lia apenas 'ST' e 'CL', nenhum marco
--   existia e [Data de Encerramento Decision] saia NULL.
--
-- E FALLBACK, NAO SUBSTITUTO:
--   so entram chamados cujo #Encerramento_DEC ficou NULL. Valor ja obtido
--   por ST/CL/SOLN/LOG/RE e PRESERVADO e nunca sobrescrito. E por isso que
--   chamados como o 1710057, que ja tem marco por SOLN, nao se movem.
--
-- Desde 2026-10-06 [8.2] le 'RE', e [8.3] ja encontra a entrada em
-- homologacao gravada como 'RE' (fonte_evento = 'RE'). Este bloco fica como
-- rede de seguranca e nao muda nenhum valor nas populacoes atuais.
--
-- MESMAS REGRAS, NADA INVENTADO:
--   mesmo parser de origem/destino de [8.2] (ancora 'alterado de' /
--   'changed from', destino no par de aspas apos ' para ' / ' to ');
--   mesmo catalogo #RegrasStatus_DEC, aceitando so eh_homologacao_decision = 1
--   ('Em homologacao' e o unico); mesma janela open_date..close_date; e a
--   mesma exigencia de posse da Decision usada por [8.3].
--   MAX(system_time) reproduz o 'ultimo marco valido' que [8.3] obtem com
--   ROW_NUMBER() ... ORDER BY evento_epoch DESC.
--   Nao se exige CL posterior: [8.3] tambem nao exige.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#EncerramentoRE_DEC') IS NOT NULL DROP TABLE #EncerramentoRE_DEC;

SELECT
    b.id,
    b.persid,
    MAX(al.system_time) AS encerramento_re_epoch
INTO #EncerramentoRE_DEC
FROM #BaseEscopoFAIA_DEC AS b
JOIN #Encerramento_DEC AS ed
    ON ed.id = b.id
   AND ed.encerramento_decision_epoch IS NULL
JOIN #AtosDEC AS al
    ON al.id = b.id
   AND al.type = 'RE'
   AND al.system_time IS NOT NULL
CROSS APPLY (
    -- #AtosDEC ja traz o texto concatenado; nao existem description nem
    -- action_desc no schema dessa temporaria.
    SELECT texto_log = al.texto_log
) AS txt_re
CROSS APPLY (
    SELECT posicao = CASE
        WHEN CHARINDEX(N'alterado de', txt_re.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'alterado de', txt_re.texto_log COLLATE Latin1_General_CI_AI) + 11
        WHEN CHARINDEX(N'changed from', txt_re.texto_log COLLATE Latin1_General_CI_AI) > 0
            THEN CHARINDEX(N'changed from', txt_re.texto_log COLLATE Latin1_General_CI_AI) + 12
        ELSE 0
    END
) AS anc_re
CROSS APPLY (
    SELECT resto = CONVERT(nvarchar(400), SUBSTRING(txt_re.texto_log, anc_re.posicao, 400))
) AS tr_re
CROSS APPLY (SELECT q1 = CHARINDEX(N'''', tr_re.resto)) AS e1
CROSS APPLY (SELECT q2 = CASE WHEN e1.q1 > 0 THEN CHARINDEX(N'''', tr_re.resto, e1.q1 + 1) ELSE 0 END) AS e2
CROSS APPLY (
    SELECT posicao = CASE
        WHEN e2.q2 > 0 AND CHARINDEX(N' para ', tr_re.resto COLLATE Latin1_General_CI_AI, e2.q2) > 0
            THEN CHARINDEX(N' para ', tr_re.resto COLLATE Latin1_General_CI_AI, e2.q2)
        WHEN e2.q2 > 0
            THEN CHARINDEX(N' to ', tr_re.resto COLLATE Latin1_General_CI_AI, e2.q2)
        ELSE 0
    END
) AS sep_re
CROSS APPLY (SELECT q3 = CASE WHEN sep_re.posicao > 0 THEN CHARINDEX(N'''', tr_re.resto, sep_re.posicao) ELSE 0 END) AS e3
CROSS APPLY (SELECT q4 = CASE WHEN e3.q3 > 0 THEN CHARINDEX(N'''', tr_re.resto, e3.q3 + 1) ELSE 0 END) AS e4
CROSS APPLY (
    SELECT nome = CASE
        WHEN e4.q4 > e3.q3 THEN SUBSTRING(tr_re.resto, e3.q3 + 1, e4.q4 - e3.q3 - 1)
        ELSE N''
    END
) AS destino_re
JOIN #RegrasStatus_DEC AS reg_re
    ON reg_re.status_nome = LTRIM(RTRIM(destino_re.nome)) COLLATE Latin1_General_CI_AI
   AND reg_re.eh_homologacao_decision = 1
WHERE b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND al.system_time >= b.open_date
  AND al.system_time <= b.close_date
  AND anc_re.posicao > 0
  AND e1.q1 > 0
  AND e2.q2 > e1.q1
  AND sep_re.posicao > 0
  AND e3.q3 > 0
  AND e4.q4 > e3.q3
  -- mesma exigencia de posse da Decision aplicada em [8.3]
  AND EXISTS (
        SELECT 1
        FROM #JanelasPosse_DEC AS j
        JOIN #Limites_DEC AS ld
            ON ld.id = j.id
        WHERE j.id = b.id
          AND al.system_time >= j.inicio_posse_epoch
          AND (
                al.system_time < j.fim_posse_epoch
             OR (
                    al.system_time = j.fim_posse_epoch
                AND j.fim_posse_epoch = ld.fim_timeline_epoch
                )
          )
  )
GROUP BY b.id, b.persid;

CREATE UNIQUE CLUSTERED INDEX IX_EncerramentoRE_DEC_persid
    ON #EncerramentoRE_DEC(persid);

--------------------------------------------------------------------------------
-- [8.4] Segmentos de status ao longo da linha do tempo
--------------------------------------------------------------------------------
;WITH EventosOrdenados AS (
    SELECT
        s.id,
        s.persid,
        s.evento_epoch,
        s.status_origem,
        s.status_destino,
        s.tipo_status_origem,
        s.tipo_status_destino,
        s.status_origem_conhecido,
        s.status_destino_conhecido,
        s.fonte_evento,
        LEAD(s.evento_epoch) OVER (
            PARTITION BY s.id
            ORDER BY s.evento_epoch ASC,
                     CASE s.fonte_evento
                         WHEN 'LOG'  THEN 1
                         WHEN 'SOLN' THEN 2
                         WHEN 'ST'   THEN 3
                         WHEN 'NOVO' THEN 4
                         WHEN 'CL'   THEN 5
                         ELSE 9
                     END,
                     s.status_destino ASC
        ) AS proximo_epoch,
        ROW_NUMBER() OVER (
            PARTITION BY s.id
            ORDER BY s.evento_epoch ASC,
                     CASE s.fonte_evento
                         WHEN 'LOG'  THEN 1
                         WHEN 'SOLN' THEN 2
                         WHEN 'ST'   THEN 3
                         WHEN 'NOVO' THEN 4
                         WHEN 'CL'   THEN 5
                         ELSE 9
                     END,
                     s.status_destino ASC
        ) AS rn_asc
    FROM #StatusEventos_DEC AS s
), Segmentos AS (
    -- Apos cada evento, o destino vigente vale ate o proximo evento ou close_date.
    SELECT
        e.id,
        e.persid,
        e.evento_epoch AS inicio_status_epoch,
        COALESCE(e.proximo_epoch, ld.fim_timeline_epoch) AS fim_status_epoch,
        e.status_destino AS status_vigente,
        e.tipo_status_destino AS tipo_status,
        e.status_destino_conhecido AS status_conhecido,
        CONVERT(nvarchar(80), CONCAT(N'DESTINO_', e.fonte_evento)) AS fonte_status
    FROM EventosOrdenados AS e
    JOIN #Limites_DEC AS ld
        ON ld.id = e.id

    UNION ALL

    -- Antes do primeiro evento, usa a origem real. Se o formato NOVO= nao trouxer
    -- origem, o fallback explicito e a fila inicial ativa.
    SELECT
        ld.id,
        ld.persid,
        ld.inicio_timeline_epoch AS inicio_status_epoch,
        e.evento_epoch AS fim_status_epoch,
        CONVERT(nvarchar(200), CASE
            WHEN NULLIF(LTRIM(RTRIM(e.status_origem)), N'') IS NULL
                THEN N'Aberto, aguarda atendimento'
            ELSE e.status_origem
        END) AS status_vigente,
        CONVERT(varchar(10), CASE
            WHEN NULLIF(LTRIM(RTRIM(e.status_origem)), N'') IS NULL
                THEN 'ATIVO'
            ELSE e.tipo_status_origem
        END) COLLATE SQL_Latin1_General_CP1_CI_AS AS tipo_status,
        CONVERT(bit, CASE
            WHEN NULLIF(LTRIM(RTRIM(e.status_origem)), N'') IS NULL
                THEN 1
            ELSE e.status_origem_conhecido
        END) AS status_conhecido,
        CONVERT(nvarchar(80), CASE
            WHEN NULLIF(LTRIM(RTRIM(e.status_origem)), N'') IS NULL
                THEN N'FALLBACK_FILA_INICIAL_SEM_ORIGEM'
            ELSE N'ORIGEM_PRIMEIRO_ST'
        END) AS fonte_status
    FROM #Limites_DEC AS ld
    JOIN EventosOrdenados AS e
        ON e.id = ld.id
       AND e.rn_asc = 1

    UNION ALL

    -- Sem evento algum, assume-se a fila inicial criada pelo SDM.
    SELECT
        ld.id,
        ld.persid,
        ld.inicio_timeline_epoch AS inicio_status_epoch,
        ld.fim_timeline_epoch AS fim_status_epoch,
        CONVERT(nvarchar(200), N'Aberto, aguarda atendimento') AS status_vigente,
        CONVERT(varchar(10), 'ATIVO') COLLATE SQL_Latin1_General_CP1_CI_AS AS tipo_status,
        CONVERT(bit, 1) AS status_conhecido,
        CONVERT(nvarchar(80), N'FALLBACK_FILA_INICIAL_SEM_ST') AS fonte_status
    FROM #Limites_DEC AS ld
    WHERE NOT EXISTS (
        SELECT 1
        FROM #StatusEventos_DEC AS s
        WHERE s.id = ld.id
    )
)
SELECT
    s.id,
    s.persid,
    s.inicio_status_epoch AS epoch_marca,
    limite.fim_epoch AS epoch_fim,
    s.status_vigente,
    s.tipo_status,
    s.status_conhecido,
    s.fonte_status
INTO #LogEstados_DEC
FROM Segmentos AS s
JOIN #Limites_DEC AS ld
    ON ld.id = s.id
CROSS APPLY (
    SELECT fim_epoch = CASE
        WHEN s.fim_status_epoch > ld.fim_timeline_epoch THEN ld.fim_timeline_epoch
        ELSE s.fim_status_epoch
    END
) AS limite
WHERE limite.fim_epoch > s.inicio_status_epoch
  AND s.inicio_status_epoch < ld.fim_timeline_epoch;

CREATE INDEX IX_LogEstados_DEC_persid_epoch
    ON #LogEstados_DEC(persid, epoch_marca, epoch_fim);
CREATE INDEX IX_LogEstados_DEC_id_epoch
    ON #LogEstados_DEC(id, epoch_marca, epoch_fim);

--------------------------------------------------------------------------------
-- [8.5] Intersecao: somente trechos em posse da Decision recebem o status
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#IntervalosNMS_DEC') IS NOT NULL DROP TABLE #IntervalosNMS_DEC;

SELECT
    s.id,
    s.persid,
    sobreposicao.inicio_epoch AS epoch_marca,
    sobreposicao.fim_epoch AS epoch_fim,
    s.status_vigente,
    s.tipo_status,
    s.status_conhecido,
    s.fonte_status
INTO #IntervalosNMS_DEC
FROM #LogEstados_DEC AS s
JOIN #JanelasPosse_DEC AS j
    ON j.id = s.id
   AND j.fim_posse_epoch > s.epoch_marca
   AND s.epoch_fim > j.inicio_posse_epoch
CROSS APPLY (
    SELECT
        inicio_epoch = CASE WHEN s.epoch_marca > j.inicio_posse_epoch THEN s.epoch_marca ELSE j.inicio_posse_epoch END,
        fim_epoch = CASE WHEN s.epoch_fim < j.fim_posse_epoch THEN s.epoch_fim ELSE j.fim_posse_epoch END
) AS sobreposicao
WHERE sobreposicao.fim_epoch > sobreposicao.inicio_epoch;

CREATE INDEX IX_IntervalosNMS_DEC_persid_epoch
    ON #IntervalosNMS_DEC(persid, epoch_marca, epoch_fim);
CREATE INDEX IX_IntervalosNMS_DEC_id_epoch
    ON #IntervalosNMS_DEC(id, epoch_marca, epoch_fim);
--------------------------------------------------------------------------------
-- [8.6] Classificacao das rotinas conforme a Memoria de Calculo
--
-- A planilha aplica uma regra hibrida, diferente do calendario comercial puro:
--   1) rotina aberta em dia nao util: ativo = suspenso = 0;
--   2) da abertura ao encerramento Decision somente em dias uteis: conta corrida,
--      inclusive noite e termino apos 20:00;
--   3) se o intervalo toca dia nao util: aplica recorte seg-sex 08:00-20:00;
--   4) o trecho ativo excluido pelo recorte e "fora da apuracao", nao U.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#RotinasEscopo_DEC') IS NOT NULL DROP TABLE #RotinasEscopo_DEC;
IF OBJECT_ID('tempdb..#RotinasDesconsideradas_DEC') IS NOT NULL DROP TABLE #RotinasDesconsideradas_DEC;
IF OBJECT_ID('tempdb..#RotinasRecorte_DEC') IS NOT NULL DROP TABLE #RotinasRecorte_DEC;

SELECT
    b.persid
INTO #RotinasEscopo_DEC
FROM #BaseEscopoFAIA_DEC AS b
WHERE CONVERT(varchar(20), b.contrato_sym) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Demais'
  AND EXISTS (
        SELECT 1
        FROM #RotinasFAIA_DEC AS ro
        WHERE (ro.categoria_like IS NULL OR b.categoria_sym COLLATE Latin1_General_CI_AI LIKE ro.categoria_like COLLATE Latin1_General_CI_AI)
          AND (ro.resumo_like    IS NULL OR b.summary_txt    COLLATE Latin1_General_CI_AI LIKE ro.resumo_like    COLLATE Latin1_General_CI_AI)
  );

CREATE UNIQUE CLUSTERED INDEX IX_RotinasEscopo_DEC_persid
    ON #RotinasEscopo_DEC(persid);

SELECT
    b.persid,
    CASE
        WHEN feriado.descricao IS NOT NULL THEN feriado.descricao
        ELSE N'Fim de semana'
    END AS motivo_desconsideracao
INTO #RotinasDesconsideradas_DEC
FROM #BaseEscopoFAIA_DEC AS b
JOIN #RotinasEscopo_DEC AS r
    ON r.persid = b.persid
CROSS APPLY (
    SELECT
        abertura_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.open_date, @Epoch))
) AS abertura_br
CROSS APPLY (
    SELECT
        data_abertura = CAST(abertura_br.abertura_br AS date),
        mes_dia = RIGHT(CONVERT(char(10), CAST(abertura_br.abertura_br AS date), 120), 5)
) AS abertura
OUTER APPLY (
    SELECT TOP (1)
        f.descricao
    FROM (
        SELECT fx.descricao
        FROM #FeriadosFixos_DEC AS fx
        WHERE fx.mes_dia = abertura.mes_dia

        UNION ALL

        SELECT fd.descricao
        FROM #FeriadosPorData_DEC AS fd
        WHERE fd.data = abertura.data_abertura
    ) AS f
) AS feriado
WHERE b.open_date IS NOT NULL
  AND (
        feriado.descricao IS NOT NULL
     OR DATEDIFF(DAY, '19000101', abertura.data_abertura) % 7 NOT BETWEEN 0 AND 4
  );

CREATE UNIQUE CLUSTERED INDEX IX_RotinasDesconsideradas_DEC_persid
    ON #RotinasDesconsideradas_DEC(persid);

SELECT
    b.persid
INTO #RotinasRecorte_DEC
FROM #BaseEscopoFAIA_DEC AS b
JOIN #RotinasEscopo_DEC AS r
    ON r.persid = b.persid
LEFT JOIN #RotinasDesconsideradas_DEC AS rd
    ON rd.persid = b.persid
LEFT JOIN #Encerramento_DEC AS ed
    ON ed.persid = b.persid
CROSS APPLY (
    SELECT
        abertura_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, b.open_date, @Epoch)),
        terminal_br = DATEADD(
            HOUR,
            -@HorasBrasilParaUTC,
            DATEADD(SECOND, COALESCE(ed.encerramento_decision_epoch, b.close_date), @Epoch)
        )
) AS limites
WHERE rd.persid IS NULL
  AND b.open_date IS NOT NULL
  AND b.close_date IS NOT NULL
  AND limites.terminal_br > limites.abertura_br
  AND EXISTS (
        SELECT 1
        FROM #Nums_DEC AS n
        CROSS APPLY (
            SELECT
                dt_date = CAST(DATEADD(DAY, n.n, CAST(limites.abertura_br AS date)) AS date),
                mes_dia = RIGHT(CONVERT(char(10), CAST(DATEADD(DAY, n.n, CAST(limites.abertura_br AS date)) AS date), 120), 5)
        ) AS d
        WHERE n.n <= DATEDIFF(
                DAY,
                CAST(limites.abertura_br AS date),
                CAST(DATEADD(SECOND, -1, limites.terminal_br) AS date)
              )
          AND (
                DATEDIFF(DAY, '19000101', d.dt_date) % 7 NOT BETWEEN 0 AND 4
             OR EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = d.mes_dia)
             OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = d.dt_date)
          )
  );

CREATE UNIQUE CLUSTERED INDEX IX_RotinasRecorte_DEC_persid
    ON #RotinasRecorte_DEC(persid);
--------------------------------------------------------------------------------
-- [8.7] TEMPO SUSPENSO - pareamento SOLN para SRVY_SENT
--
-- Regra informada pelo gestor: o componente nao e o TempoGastoSeg, e sim o
-- intervalo entre o registro da solucao (SOLN) e o envio da pesquisa de
-- satisfacao (SRVY_SENT), que representa o periodo de homologacao apos a solucao.
--
-- PAREAMENTO (nao e "o primeiro" nem "o ultimo" evento, e sim o par do ciclo):
--   Para cada SOLN, o SRVY_SENT pareado e o PRIMEIRO SRVY_SENT que ocorre
--   DEPOIS daquele SOLN e ANTES do proximo SOLN do mesmo chamado. Justificativa:
--     - com reabertura ou novo ciclo de resolucao existem varios SOLN; parear
--       cada SOLN com o SRVY_SENT do seu proprio ciclo mantem os ciclos separados
--       e impede que o intervalo de um ciclo invada o outro;
--     - com SRVY_SENT duplicado no mesmo ciclo, MIN escolhe o primeiro e a uniao
--       de [8.8] torna as repeticoes inofensivas;
--     - SRVY_SENT anterior ou igual ao SOLN e descartado pelo predicado
--       srvy_epoch maior que soln_epoch (intervalo invalido, fim antes do inicio);
--     - sem SRVY_SENT no ciclo NAO se inventa um fim: o par simplesmente nao
--       existe. O trecho pos-SOLN continua coberto pelo estado implicito
--       "Em homologacao" criado em [8.2], que vai do SOLN ate o proximo evento
--       ou ate o close_date.
--   O intervalo e ainda recortado por open_date e close_date e pela intersecao
--   com as janelas de posse da Decision, para nunca contar tempo de outro grupo
--   nem tempo fora da vida do chamado.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#ParesSolnSrvy_DEC') IS NOT NULL DROP TABLE #ParesSolnSrvy_DEC;

-- OTIMIZADO: o pareamento foi calculado em [7.5] sobre o escopo FARC, que e
-- superconjunto do escopo FAIA. Aqui so se restringe ao escopo FAIA. Colunas,
-- ordem, tipos e indices permanecem os mesmos que este bloco sempre produziu.
SELECT
    p.id,
    p.persid,
    p.soln_epoch,
    p.srvy_epoch
INTO #ParesSolnSrvy_DEC
FROM #ParesBaseSolnSrvy_DEC AS p
JOIN #EscopoFAIA_DEC AS f
    ON f.id = p.id;

CREATE INDEX IX_ParesSolnSrvy_DEC_id
    ON #ParesSolnSrvy_DEC(id, soln_epoch, srvy_epoch);
CREATE INDEX IX_ParesSolnSrvy_DEC_persid
    ON #ParesSolnSrvy_DEC(persid, soln_epoch, srvy_epoch);
--------------------------------------------------------------------------------
-- [8.8] TEMPO SUSPENSO - intervalos brutos e UNIAO temporal
--
-- Componentes reunidos:
--   (a) todo intervalo em status SUSPENSO dentro da posse da Decision. Isso
--       cobre Agendado, Aguardando fornecedor, Em homologacao, Aguardando
--       documentacao, Aguardando publicacao e qualquer outro status que nao
--       esteja na allowlist ATIVA de #RegrasStatus_DEC. Nenhum status foi
--       incluido sem evidencia: a classificacao vem da allowlist, e o que nao
--       esta nela aparece no diagnostico de status nao classificado.
--   (b) o intervalo SOLN para SRVY_SENT de [8.7], recortado pela posse.
--
-- Exclusoes preservadas do motor anterior:
--   - rotina aberta em dia nao util: tudo zerado;
--   - trecho DESTINO_LOG (Producao de relatorios com SOLN generico): o intervalo
--     entre o LOG real e o SOLN generico e processamento administrativo e fica
--     fora da apuracao, nao em U.
--
-- UNIAO (impede dupla contagem): algoritmo de ilhas. Os intervalos sao ordenados
-- por inicio; um novo intervalo abre uma ilha somente quando comeca DEPOIS do
-- maior fim ja visto. Intervalos que se tocam sao fundidos. Exemplo:
--     Agendado             10:00 ate 12:00
--     SOLN para SRVY_SENT  11:00 ate 13:00
--   uniao = 10:00 ate 13:00 = 3 horas, e nao 2 mais 2 = 4 horas.
--
-- Nenhum intervalo com fim menor ou igual ao inicio entra: todos os ramos filtram
-- fim maior que inicio. Nada antes da abertura nem depois do encerramento total
-- entra, porque a fonte ja esta recortada por #Limites_DEC e pelas janelas de
-- posse.
--
-- A hora nao comercial NAO entra aqui. Ver [8.9].
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#SuspBruto_DEC') IS NOT NULL DROP TABLE #SuspBruto_DEC;

SELECT
    x.persid,
    x.inicio_epoch,
    x.fim_epoch,
    x.origem_componente
INTO #SuspBruto_DEC
FROM (
    -- (a) intervalos em status suspenso, ja intersectados com a posse
    SELECT
        i.persid,
        CONVERT(bigint, i.epoch_marca) AS inicio_epoch,
        CONVERT(bigint, i.epoch_fim)   AS fim_epoch,
        CONVERT(nvarchar(40), N'STATUS_SUSPENSO') AS origem_componente
    FROM #IntervalosNMS_DEC AS i
    LEFT JOIN #RotinasDesconsideradas_DEC AS rd
        ON rd.persid = i.persid
    WHERE i.tipo_status <> 'ATIVO'
      AND i.fonte_status <> N'DESTINO_LOG'
      AND rd.persid IS NULL
      AND i.epoch_fim > i.epoch_marca

    UNION ALL

    -- (b) SOLN para SRVY_SENT, recortado pelas janelas de posse da Decision
    SELECT
        sp.persid,
        CONVERT(bigint, corte.inicio_epoch) AS inicio_epoch,
        CONVERT(bigint, corte.fim_epoch)    AS fim_epoch,
        CONVERT(nvarchar(40), N'SOLN_SRVY_SENT') AS origem_componente
    FROM #ParesSolnSrvy_DEC AS sp
    JOIN #JanelasPosse_DEC AS j
        ON j.id = sp.id
       AND j.fim_posse_epoch > sp.soln_epoch
       AND sp.srvy_epoch > j.inicio_posse_epoch
    LEFT JOIN #RotinasDesconsideradas_DEC AS rd
        ON rd.persid = sp.persid
    CROSS APPLY (
        SELECT
            inicio_epoch = CASE WHEN sp.soln_epoch > j.inicio_posse_epoch THEN sp.soln_epoch ELSE j.inicio_posse_epoch END,
            fim_epoch    = CASE WHEN sp.srvy_epoch < j.fim_posse_epoch    THEN sp.srvy_epoch ELSE j.fim_posse_epoch    END
    ) AS corte
    WHERE rd.persid IS NULL
      AND corte.fim_epoch > corte.inicio_epoch
) AS x;

CREATE INDEX IX_SuspBruto_DEC_persid
    ON #SuspBruto_DEC(persid, inicio_epoch, fim_epoch);

IF OBJECT_ID('tempdb..#SuspUniao_DEC') IS NOT NULL DROP TABLE #SuspUniao_DEC;

;WITH Ordenados AS (
    SELECT
        s.persid,
        s.inicio_epoch,
        s.fim_epoch,
        MAX(s.fim_epoch) OVER (
            PARTITION BY s.persid
            ORDER BY s.inicio_epoch, s.fim_epoch
            ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
        ) AS maior_fim_anterior
    FROM #SuspBruto_DEC AS s
), Marcados AS (
    SELECT
        o.persid,
        o.inicio_epoch,
        o.fim_epoch,
        CASE
            WHEN o.maior_fim_anterior IS NULL OR o.inicio_epoch > o.maior_fim_anterior
                THEN 1 ELSE 0
        END AS inicia_ilha
    FROM Ordenados AS o
), Ilhas AS (
    SELECT
        m.persid,
        m.inicio_epoch,
        m.fim_epoch,
        SUM(m.inicia_ilha) OVER (
            PARTITION BY m.persid
            ORDER BY m.inicio_epoch, m.fim_epoch
            ROWS UNBOUNDED PRECEDING
        ) AS ilha
    FROM Marcados AS m
)
SELECT
    i.persid,
    i.ilha,
    MIN(i.inicio_epoch) AS inicio_epoch,
    MAX(i.fim_epoch)    AS fim_epoch
INTO #SuspUniao_DEC
FROM Ilhas AS i
GROUP BY i.persid, i.ilha;

CREATE UNIQUE CLUSTERED INDEX IX_SuspUniao_DEC_persid_ilha
    ON #SuspUniao_DEC(persid, ilha);

IF OBJECT_ID('tempdb..#SuspTotal_DEC') IS NOT NULL DROP TABLE #SuspTotal_DEC;

SELECT
    u.persid,
    SUM(u.fim_epoch - u.inicio_epoch) AS segundos_suspenso_uniao,
    COUNT(*) AS qtd_intervalos_suspensos
INTO #SuspTotal_DEC
FROM #SuspUniao_DEC AS u
GROUP BY u.persid;

CREATE UNIQUE CLUSTERED INDEX IX_SuspTotal_DEC_persid
    ON #SuspTotal_DEC(persid);

--------------------------------------------------------------------------------
-- [8.9] Tempo ATIVO por calendario, e o terceiro componente
--
-- Cada intersecao posse x status e quebrada por dia em horario do Brasil:
--   CORRIDA    + status ATIVO: todo o trecho pertence ao Tempo Total Decision;
--   COMERCIAL  + status ATIVO: somente seg-sex 08:00-20:00, fora de feriado/PF;
--   rotina hibrida: ativo excluido pelo calendario fica fora da apuracao.
--
-- Quando nao ha linha compativel em #SLA_FAIA_DEC, nenhum calendario NMS foi
-- comprovado: o ativo fica 0 e sem_regra_calendario = 1 aparece no diagnostico.
-- Nao existe fallback silencioso para CORRIDA ou COMERCIAL.
--
-- MUDANCA COMPROVADA NESTA VERSAO - a "hora nao comercial" deixa de entrar no
-- Tempo suspenso:
--   O motor anterior somava, para chamado NAO rotina com SLA COMERCIAL,
--   (segundos_total - segundos_comerciais) ao Tempo suspenso. O relatorio
--   oficial NAO faz isso. Prova no chamado 1700873 (CT_SAN, ciclo
--   30-05-2026 a 29-06-2026), severidade 4, portanto SLA comercial, e que NAO e
--   rotina do cadastro FAIA:
--       W (horas decorridas totais)  = 430:44:45
--       X (Tempo Total Decision)     =  23:06:46  = ativo intersectado com 08-20
--       U (coluna do relatorio)      = 335:37:59  = Agendado 171:38:51
--                                                 + Aguardando documentacao 0:00:04
--                                                 + Aguardando Publicacao 163:59:04
--       W - X - U                    =  72:00:00  = exatamente a hora nao comercial
--   Ou seja, a hora nao comercial e o TERCEIRO componente (fora da apuracao) e
--   nao faz parte de U. Isso tambem e coerente com o 1702458 ja registrado no
--   arquivo mestre, que atravessa duas noites e mesmo assim tem U de segundos.
--   O nome da coluna do relatorio ("Hora nao comercial, Agendado e Em
--   Homologacao") e historico.
--
-- Por isso #Duracoes_DEC passa a produzir apenas o ATIVO e o total de posse; o
-- suspenso vem da uniao de [8.8] e o fora da apuracao e o resto.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#Duracoes_DEC') IS NOT NULL DROP TABLE #Duracoes_DEC;

SELECT
    i.persid,
    SUM(CONVERT(bigint, fatia.segundos_total)) AS segundos_total_posse,
    SUM(CONVERT(bigint, fatia.segundos_ativo)) AS segundos_ativo,
    MAX(CONVERT(tinyint, CASE
        WHEN r.persid IS NOT NULL OR sl.tipo_inicio IN ('CORRIDA', 'COMERCIAL') THEN 0
        ELSE 1
    END)) AS sem_regra_calendario
INTO #Duracoes_DEC
FROM #IntervalosNMS_DEC AS i
JOIN #BaseEscopoFAIA_DEC AS b
    ON b.id = i.id
LEFT JOIN #RotinasEscopo_DEC AS r
    ON r.persid = i.persid
LEFT JOIN #RotinasDesconsideradas_DEC AS rd
    ON rd.persid = i.persid
LEFT JOIN #RotinasRecorte_DEC AS rc
    ON rc.persid = i.persid
LEFT JOIN #SLA_FAIA_DEC AS sl
    ON  sl.contrato     = CONVERT(varchar(20), b.contrato_sym)      COLLATE SQL_Latin1_General_CP1_CI_AS
    AND sl.tipo_chamado = CONVERT(char(1),     b.tipo_chamado_faia) COLLATE SQL_Latin1_General_CP1_CI_AS
    AND sl.prioridade   = b.prioridade_nivel
CROSS APPLY (
    SELECT
        ini_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, i.epoch_marca, @Epoch)),
        fim_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, i.epoch_fim,   @Epoch))
) AS intervalo
JOIN #Nums_DEC AS n
    ON i.epoch_fim > i.epoch_marca
   AND n.n <= DATEDIFF(
        DAY,
        CAST(intervalo.ini_br AS date),
        CAST(DATEADD(SECOND, -1, intervalo.fim_br) AS date)
   )
CROSS APPLY (
    SELECT dt_date = CAST(DATEADD(DAY, n.n, CAST(intervalo.ini_br AS date)) AS date)
) AS data_segmento
CROSS APPLY (
    SELECT
        mes_dia = RIGHT(CONVERT(char(10), data_segmento.dt_date, 120), 5),
        inicio_dia = CAST(data_segmento.dt_date AS datetime2(0)),
        fim_dia = DATEADD(DAY, 1, CAST(data_segmento.dt_date AS datetime2(0))),
        inicio_comercial = DATEADD(HOUR, @HoraInicioComercial, CAST(data_segmento.dt_date AS datetime2(0))),
        fim_comercial = DATEADD(HOUR, @HoraFimComercial, CAST(data_segmento.dt_date AS datetime2(0))),
        eh_dia_util = CASE
            WHEN DATEDIFF(DAY, '19000101', data_segmento.dt_date) % 7 BETWEEN 0 AND 4
                THEN 1 ELSE 0
        END,
        eh_feriado_ou_facultativo = CASE
            WHEN EXISTS (
                    SELECT 1
                    FROM #FeriadosFixos_DEC AS fx
                    WHERE fx.mes_dia = RIGHT(CONVERT(char(10), data_segmento.dt_date, 120), 5)
                 )
              OR EXISTS (
                    SELECT 1
                    FROM #FeriadosPorData_DEC AS fd
                    WHERE fd.data = data_segmento.dt_date
                 )
                THEN 1 ELSE 0
        END
) AS calendario
CROSS APPLY (
    SELECT
        ini_total = CASE
            WHEN intervalo.ini_br > calendario.inicio_dia THEN intervalo.ini_br
            ELSE calendario.inicio_dia
        END,
        fim_total = CASE
            WHEN intervalo.fim_br < calendario.fim_dia THEN intervalo.fim_br
            ELSE calendario.fim_dia
        END,
        ini_comercial = CASE
            WHEN intervalo.ini_br > calendario.inicio_comercial THEN intervalo.ini_br
            ELSE calendario.inicio_comercial
        END,
        fim_comercial = CASE
            WHEN intervalo.fim_br < calendario.fim_comercial THEN intervalo.fim_br
            ELSE calendario.fim_comercial
        END
) AS janela
CROSS APPLY (
    SELECT
        segundos_total = CASE
            WHEN janela.fim_total > janela.ini_total
                THEN DATEDIFF(SECOND, janela.ini_total, janela.fim_total)
            ELSE 0
        END,
        segundos_comerciais = CASE
            WHEN calendario.eh_dia_util = 1
             AND calendario.eh_feriado_ou_facultativo = 0
             AND janela.fim_comercial > janela.ini_comercial
                THEN DATEDIFF(SECOND, janela.ini_comercial, janela.fim_comercial)
            ELSE 0
        END
) AS relogio
CROSS APPLY (
    SELECT
        segundos_ativo = CASE
            WHEN rd.persid IS NOT NULL THEN 0
            -- No caso comprovado de Producao de relatorios, o LOG e tambem o
            -- encerramento efetivo da memoria; o SOLN generico posterior e
            -- processamento administrativo fora da apuracao.
            WHEN i.fonte_status = N'DESTINO_LOG' THEN 0
            WHEN i.tipo_status <> 'ATIVO' THEN 0
            -- Rotina que nao tocou dia nao util: contagem corrida, mesmo que a
            -- prioridade seja comercial e o termino ocorra apos 20:00.
            WHEN r.persid IS NOT NULL AND rc.persid IS NULL
                THEN relogio.segundos_total
            -- Rotina que tocou dia nao util: somente a janela comercial conta.
            WHEN r.persid IS NOT NULL AND rc.persid IS NOT NULL
                THEN relogio.segundos_comerciais
            WHEN sl.tipo_inicio = 'CORRIDA' THEN relogio.segundos_total
            WHEN sl.tipo_inicio = 'COMERCIAL' THEN relogio.segundos_comerciais
            ELSE 0
        END
) AS classificacao
CROSS APPLY (
    SELECT
        segundos_total = relogio.segundos_total,
        classificacao.segundos_ativo
) AS fatia
WHERE fatia.segundos_total > 0
GROUP BY i.persid;

CREATE UNIQUE CLUSTERED INDEX IX_Duracoes_DEC_persid
    ON #Duracoes_DEC(persid);

--------------------------------------------------------------------------------
-- [8.10] Calculo FAIA por chamado (valores numericos; a formatacao fica no
--        SELECT consolidado de [10])
--
-- Uma linha por id. Todas as fontes deste bloco tem chave unica por chamado,
-- portanto nenhum JOIN multiplica linhas.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#CalcFAIA_DEC') IS NOT NULL DROP TABLE #CalcFAIA_DEC;

;WITH Calc AS (
    SELECT
        b.id,
        b.persid,
        b.data_abertura_br,
        b.data_captura_br,
        sl.meta_inicio_seg,
        sl.tipo_inicio,
        sl.fator_inicio,
        CASE
            WHEN b.data_abertura_br IS NULL OR b.data_captura_br IS NULL THEN NULL
            -- Sem linha de SLA para esta combinacao (ex.: P4/P5 Solicitacao LibQuantum)
            WHEN sl.meta_inicio_seg IS NULL THEN NULL
            -- Regra ja existente do primeiro atendimento: rotina aberta em
            -- feriado ou ponto facultativo fica zerada.
            WHEN rotina.eh_rotina_operacional_faia = 1
             AND cal_inicio.eh_abertura_feriado_ou_facultativo = 1
                THEN 0
            WHEN b.data_captura_br < b.data_abertura_br THEN 0
            WHEN sl.tipo_inicio = 'CORRIDA'
                THEN COALESCE(bh.segundos_corridos, 0)
            WHEN sl.tipo_inicio = 'COMERCIAL'
                THEN COALESCE(bh.segundos_comerciais, 0)
            ELSE NULL
        END AS tempo_primeiro_seg
    FROM #BaseEscopoFAIA_DEC AS b
    -- JOIN triplo: contrato + tipo_chamado + prioridade.
    LEFT JOIN #SLA_FAIA_DEC AS sl
        ON  sl.contrato     = CONVERT(varchar(20), b.contrato_sym)      COLLATE SQL_Latin1_General_CP1_CI_AS
        AND sl.tipo_chamado = CONVERT(char(1),     b.tipo_chamado_faia) COLLATE SQL_Latin1_General_CP1_CI_AS
        AND sl.prioridade   = b.prioridade_nivel
    OUTER APPLY (
        SELECT
            abertura_data = CAST(b.data_abertura_br AS date),
            abertura_mes_dia = RIGHT(CONVERT(char(10), CAST(b.data_abertura_br AS date), 120), 5)
    ) AS abertura
    OUTER APPLY (
        SELECT eh_abertura_feriado_ou_facultativo = CASE
            WHEN b.data_abertura_br IS NOT NULL
             AND (
                    EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = abertura.abertura_mes_dia)
                 OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = abertura.abertura_data)
                 )
            THEN 1 ELSE 0
        END
    ) AS cal_inicio
    OUTER APPLY (
        SELECT eh_rotina_operacional_faia = CASE
            WHEN CONVERT(varchar(20), b.contrato_sym) COLLATE SQL_Latin1_General_CP1_CI_AS = 'Demais'
             AND EXISTS (
                    SELECT 1
                    FROM #RotinasFAIA_DEC AS ro
                    WHERE (ro.categoria_like IS NULL OR b.categoria_sym COLLATE Latin1_General_CI_AI LIKE ro.categoria_like COLLATE Latin1_General_CI_AI)
                      AND (ro.resumo_like    IS NULL OR b.summary_txt    COLLATE Latin1_General_CI_AI LIKE ro.resumo_like    COLLATE Latin1_General_CI_AI)
                 )
            THEN 1 ELSE 0
        END
    ) AS rotina
    OUTER APPLY (
        SELECT
            segundos_corridos   = COALESCE(SUM(x.seg_corrido),   0),
            segundos_comerciais = COALESCE(SUM(x.seg_comercial), 0)
        FROM (
            SELECT
                -- CORRIDA: conta 24x7, sem desconto de feriados/facultativos
                seg_corrido = CASE
                    WHEN janela_c.fim_calc > janela_c.ini_calc
                        THEN DATEDIFF(SECOND, janela_c.ini_calc, janela_c.fim_calc)
                    ELSE 0
                END,
                -- COMERCIAL: 08:00-20:00 seg-sex, excluindo feriados/facultativos
                seg_comercial = CASE
                    WHEN cal.eh_feriado_ou_facultativo = 1 THEN 0
                    WHEN cal.eh_dia_util = 0              THEN 0
                    WHEN janela_h.fim_calc > janela_h.ini_calc
                        THEN DATEDIFF(SECOND, janela_h.ini_calc, janela_h.fim_calc)
                    ELSE 0
                END
            FROM (
                SELECT DATEADD(DAY, n.n, CAST(b.data_abertura_br AS date)) AS dt
                FROM #Nums_DEC AS n
                WHERE b.data_abertura_br IS NOT NULL
                  AND b.data_captura_br IS NOT NULL
                  AND b.data_captura_br >= b.data_abertura_br
                  AND n.n <= DATEDIFF(DAY, CAST(b.data_abertura_br AS date), CAST(b.data_captura_br AS date))
            ) AS dias
            CROSS APPLY (
                SELECT
                    dt_date = CAST(dias.dt AS date),
                    mes_dia = RIGHT(CONVERT(char(10), CAST(dias.dt AS date), 120), 5)
            ) AS d
            CROSS APPLY (
                SELECT
                    eh_feriado_ou_facultativo = CASE
                        WHEN EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = d.mes_dia)
                          OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = d.dt_date)
                        THEN 1 ELSE 0
                    END,
                    eh_dia_util = CASE
                        WHEN DATEDIFF(DAY, '19000101', d.dt_date) % 7 BETWEEN 0 AND 4
                        THEN 1 ELSE 0
                    END
            ) AS cal
            CROSS APPLY (
                SELECT
                    ini_calc = CASE WHEN b.data_abertura_br > CAST(d.dt_date AS datetime2(0))
                                    THEN b.data_abertura_br ELSE CAST(d.dt_date AS datetime2(0)) END,
                    fim_calc = CASE WHEN b.data_captura_br  < DATEADD(DAY, 1, CAST(d.dt_date AS datetime2(0)))
                                    THEN b.data_captura_br  ELSE DATEADD(DAY, 1, CAST(d.dt_date AS datetime2(0))) END
            ) AS janela_c
            CROSS APPLY (
                SELECT
                    ini_calc = CASE WHEN b.data_abertura_br > DATEADD(HOUR, @HoraInicioComercial, CAST(d.dt_date AS datetime2(0)))
                                    THEN b.data_abertura_br ELSE DATEADD(HOUR, @HoraInicioComercial, CAST(d.dt_date AS datetime2(0))) END,
                    fim_calc = CASE WHEN b.data_captura_br  < DATEADD(HOUR, @HoraFimComercial,    CAST(d.dt_date AS datetime2(0)))
                                    THEN b.data_captura_br  ELSE DATEADD(HOUR, @HoraFimComercial,  CAST(d.dt_date AS datetime2(0))) END
            ) AS janela_h
        ) AS x
    ) AS bh
)
SELECT
    c.id,
    c.persid,
    c.data_captura_br,
    c.meta_inicio_seg,
    c.tipo_inicio,
    c.fator_inicio,
    c.tempo_primeiro_seg,
    CASE
        WHEN c.tempo_primeiro_seg IS NULL OR c.meta_inicio_seg IS NULL THEN NULL
        WHEN c.tempo_primeiro_seg > c.meta_inicio_seg THEN c.tempo_primeiro_seg - c.meta_inicio_seg
        ELSE 0
    END AS primeiro_excedido_seg,
    -- FALLBACK de [8.3.1]: so preenche quando a regra atual deu NULL.
    -- Aplicado AQUI, no ponto em que a coluna e produzida, e nao dentro de
    -- #Encerramento_DEC, para que #RotinasRecorte_DEC continue enxergando
    -- exatamente o que enxergava antes. Assim nenhuma outra coluna pode se
    -- mover por causa desta correcao.
    COALESCE(ed.encerramento_decision_epoch, edre.encerramento_re_epoch)
        AS encerramento_decision_epoch,
    ed.qtd_homologacoes,
    ed.fonte_encerramento_decision,
    -- Tempo Total Decision: nunca negativo.
    CASE
        WHEN ISNULL(dd.segundos_ativo, 0) < 0 THEN CONVERT(bigint, 0)
        ELSE ISNULL(dd.segundos_ativo, CONVERT(bigint, 0))
    END AS ttd_seg,
    -- Tempo suspenso: uniao de [8.8], nunca negativo.
    CASE
        WHEN ISNULL(su.segundos_suspenso_uniao, 0) < 0 THEN CONVERT(bigint, 0)
        ELSE ISNULL(su.segundos_suspenso_uniao, CONVERT(bigint, 0))
    END AS susp_seg,
    ISNULL(dd.segundos_total_posse, CONVERT(bigint, 0)) AS segundos_total_posse,
    -- Terceiro componente: o que sobra da posse depois do ativo e do suspenso.
    -- Inclui a hora nao comercial e o trecho DESTINO_LOG. Piso em zero.
    CASE
        WHEN ISNULL(dd.segundos_total_posse, 0)
             - ISNULL(dd.segundos_ativo, 0)
             - ISNULL(su.segundos_suspenso_uniao, 0) < 0 THEN CONVERT(bigint, 0)
        ELSE ISNULL(dd.segundos_total_posse, 0)
             - ISNULL(dd.segundos_ativo, 0)
             - ISNULL(su.segundos_suspenso_uniao, 0)
    END AS segundos_fora_apuracao,
    ISNULL(dd.sem_regra_calendario, CONVERT(tinyint, 0)) AS sem_regra_calendario
INTO #CalcFAIA_DEC
FROM Calc AS c
LEFT JOIN #Duracoes_DEC AS dd
    ON dd.persid = c.persid
LEFT JOIN #SuspTotal_DEC AS su
    ON su.persid = c.persid
LEFT JOIN #Encerramento_DEC AS ed
    ON ed.persid = c.persid
LEFT JOIN #EncerramentoRE_DEC AS edre
    ON edre.persid = c.persid;

CREATE UNIQUE CLUSTERED INDEX IX_CalcFAIA_DEC_id ON #CalcFAIA_DEC(id);

--------------------------------------------------------------------------------
-- [9] MOTORES DO FARC - Tempo de Atendimento
--
-- Preservados integralmente da consulta FARC anterior. A unica mudanca funcional
-- autorizada nesta tarefa foi o padrao decimal de nHR_FARC e FARC, aplicada em
-- [10]. Escopo, entrada no grupo, captura, terminal, rotinas, calendario, SLA e
-- excedente continuam identicos.
--
-- NAO foram transportados para ca o #LogEstadosDecision e o #DuracoesDecision da
-- consulta FARC antiga. Eles alimentavam apenas as colunas [Tempo total decision]
-- e [Tempo suspenso] do FARC, que sao a MESMA informacao das colunas homonimas do
-- FAIA e, pela regra de deduplicacao de colunas, ficaram com a versao do FAIA
-- (motor NMS, provado contra a Memoria de Calculo). O Tempo de Atendimento, o
-- nHR_FARC e o FARC nao dependiam dessas duas estruturas e nao mudaram.
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- [9.1] Motor de rotina: Data Abertura/Inicio -> Fechamento Decision
--   - Rotina aberta em feriado/ponto facultativo: tempo = 0.
--   - Rotina em dias uteis continuos: conta tempo corrido do intervalo.
--   - Rotina que atravessa sabado/domingo/feriado/facultativo: usa recorte
--     comercial 08:00-20:00 apenas nos dias uteis validos.
--
-- Este bloco produz o tempo BRUTO, ainda sem o desconto de suspensao. O liquido
-- e montado em [9.2.2], depois que [9.2.1] calcula o tempo suspenso.
--
-- Por que uma tabela NOVA (#TempoAtendRotinaBruto_DEC) em vez de acrescentar a
-- coluna base_calendario na #TempoAtendRotina_DEC:
--   O script inteiro e um unico batch (sem GO). Se a sessao ja tiver rodado uma
--   versao anterior da consulta, a #TempoAtendRotina_DEC dessa execucao continua
--   existindo, e o compilador liga as referencias ao ESQUEMA ANTIGO - o
--   DROP TABLE so roda depois da compilacao. Qualquer coluna nova numa temporaria
--   que ja existia gera Msg 207 "Invalid column name".
--   Mantendo #TempoAtendRotina_DEC e #MotorBaseFARC_DEC com EXATAMENTE o mesmo
--   esquema de antes, e colocando todo o material novo em tabelas que nunca
--   existiram, a consulta compila em qualquer sessao, limpa ou nao.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TempoAtendRotinaBruto_DEC') IS NOT NULL DROP TABLE #TempoAtendRotinaBruto_DEC;

SELECT
    b.id,
    CASE
        WHEN b.data_abertura_br IS NULL
          OR b.data_fechamento_decision_br IS NULL
          OR sl.tipo_resolucao IS NULL
            THEN NULL
        WHEN b.data_fechamento_decision_br < b.data_abertura_br
            THEN 0

        -- Se a rotina abriu em feriado/ponto facultativo, fica zerada.
        WHEN cal_inicio.eh_abertura_feriado_ou_facultativo = 1
            THEN 0

        -- Para SLA corrido, mantem intervalo cheio.
        WHEN sl.tipo_resolucao = 'CORRIDA'
            THEN DATEDIFF(SECOND, b.data_abertura_br, b.data_fechamento_decision_br)

        -- Rotinas Decision em dias uteis continuos: o relatorio usa tempo
        -- corrido, mesmo passando de 20:00 ou cruzando a noite entre dias uteis.
        WHEN sl.tipo_resolucao = 'COMERCIAL'
         AND cal_intervalo.tem_dia_nao_util_no_intervalo = 0
            THEN DATEDIFF(SECOND, b.data_abertura_br, b.data_fechamento_decision_br)

        -- Se atravessar sabado/domingo/feriado/facultativo, recorta para
        -- seg-sex 08:00-20:00 e ignora os dias nao contados.
        WHEN sl.tipo_resolucao = 'COMERCIAL'
            THEN COALESCE(bh.segundos_comerciais, 0)

        ELSE DATEDIFF(SECOND, b.data_abertura_br, b.data_fechamento_decision_br)
    END AS tempo_atendimento_rotina_seg,

    -- Base de calendario que o CASE acima efetivamente usou. Exposta para que o
    -- desconto do tempo suspenso, em [9.2.1], seja feito na MESMA base - do
    -- contrario o desconto nao seria comparavel com o total.
    -- Nao altera nenhum valor ja calculado: e so a explicitacao do ramo escolhido.
    CONVERT(varchar(10), CASE
        WHEN b.data_abertura_br IS NULL
          OR b.data_fechamento_decision_br IS NULL
          OR sl.tipo_resolucao IS NULL                              THEN 'NENHUM'
        WHEN b.data_fechamento_decision_br < b.data_abertura_br     THEN 'NENHUM'
        WHEN cal_inicio.eh_abertura_feriado_ou_facultativo = 1      THEN 'NENHUM'
        WHEN sl.tipo_resolucao = 'CORRIDA'                          THEN 'CORRIDO'
        WHEN sl.tipo_resolucao = 'COMERCIAL'
         AND cal_intervalo.tem_dia_nao_util_no_intervalo = 0        THEN 'CORRIDO'
        WHEN sl.tipo_resolucao = 'COMERCIAL'                        THEN 'COMERCIAL'
        ELSE 'CORRIDO'
    END) AS base_calendario
INTO #TempoAtendRotinaBruto_DEC
FROM #BaseEscopoFARC_DEC AS b
LEFT JOIN @SLA_FARC AS sl
    ON sl.prioridade = b.prioridade_nivel
   AND sl.tipo_chamado = b.[type] COLLATE DATABASE_DEFAULT
OUTER APPLY (
    SELECT
        abertura_data = CAST(b.data_abertura_br AS date),
        abertura_mes_dia = RIGHT(CONVERT(char(10), CAST(b.data_abertura_br AS date), 120), 5)
) AS ab
OUTER APPLY (
    SELECT
        eh_abertura_feriado_ou_facultativo = CASE
            WHEN b.data_abertura_br IS NOT NULL
             AND (
                    EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = ab.abertura_mes_dia)
                 OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = ab.abertura_data)
                 )
            THEN 1 ELSE 0
        END
) AS cal_inicio
OUTER APPLY (
    SELECT
        tem_dia_nao_util_no_intervalo = CASE
            WHEN EXISTS (
                SELECT 1
                FROM #Nums_DEC AS n
                CROSS APPLY (
                    SELECT
                        dt_date = CAST(DATEADD(DAY, n.n, CAST(b.data_abertura_br AS date)) AS date),
                        mes_dia = RIGHT(CONVERT(char(10), CAST(DATEADD(DAY, n.n, CAST(b.data_abertura_br AS date)) AS date), 120), 5)
                ) AS d
                WHERE b.data_abertura_br IS NOT NULL
                  AND b.data_fechamento_decision_br IS NOT NULL
                  AND b.data_fechamento_decision_br >= b.data_abertura_br
                  AND n.n <= DATEDIFF(DAY, CAST(b.data_abertura_br AS date), CAST(b.data_fechamento_decision_br AS date))
                  AND (
                        DATEDIFF(DAY, '19000101', d.dt_date) % 7 NOT BETWEEN 0 AND 4
                     OR EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = d.mes_dia)
                     OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = d.dt_date)
                  )
            )
            THEN 1 ELSE 0
        END
) AS cal_intervalo
OUTER APPLY (
    SELECT segundos_comerciais = COALESCE(SUM(x.segundos_dia), 0)
    FROM (
        SELECT
            segundos_dia = CASE
                WHEN janela.fim_calc > janela.ini_calc
                    THEN DATEDIFF(SECOND, janela.ini_calc, janela.fim_calc)
                ELSE 0
            END
        FROM (
            SELECT DATEADD(DAY, n.n, CAST(b.data_abertura_br AS date)) AS dt
            FROM #Nums_DEC AS n
            WHERE b.data_abertura_br IS NOT NULL
              AND b.data_fechamento_decision_br IS NOT NULL
              AND b.data_fechamento_decision_br >= b.data_abertura_br
              AND n.n <= DATEDIFF(DAY, CAST(b.data_abertura_br AS date), CAST(b.data_fechamento_decision_br AS date))
        ) AS dias
        CROSS APPLY (
            SELECT
                dt_date = CAST(dias.dt AS date),
                mes_dia = RIGHT(CONVERT(char(10), CAST(dias.dt AS date), 120), 5)
        ) AS d
        CROSS APPLY (
            SELECT
                eh_feriado_ou_facultativo = CASE
                    WHEN EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = d.mes_dia)
                      OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = d.dt_date)
                    THEN 1 ELSE 0
                END,
                eh_dia_util = CASE
                    WHEN DATEDIFF(DAY, '19000101', d.dt_date) % 7 BETWEEN 0 AND 4
                    THEN 1 ELSE 0
                END
        ) AS cal
        CROSS APPLY (
            SELECT
                inicio_janela = DATEADD(HOUR, @HoraInicioComercial, CAST(d.dt_date AS datetime2(0))),
                fim_janela    = DATEADD(HOUR, @HoraFimComercial,    CAST(d.dt_date AS datetime2(0)))
        ) AS h
        CROSS APPLY (
            SELECT
                ini_calc = CASE WHEN b.data_abertura_br            > h.inicio_janela THEN b.data_abertura_br            ELSE h.inicio_janela END,
                fim_calc = CASE WHEN b.data_fechamento_decision_br < h.fim_janela    THEN b.data_fechamento_decision_br ELSE h.fim_janela    END
        ) AS janela
        WHERE cal.eh_feriado_ou_facultativo = 0
          AND cal.eh_dia_util = 1
    ) AS x
) AS bh;

CREATE UNIQUE CLUSTERED INDEX IX_TempoAtendRotinaBruto_DEC_id ON #TempoAtendRotinaBruto_DEC(id);

--------------------------------------------------------------------------------
-- [9.2] Motor normal do FARC: tempo ativo por status
--
-- Conta os status ativos: Aberto, aguarda atendimento, Em andamento e Reaberto.
-- Pausa status como Agendado, Aguarda atendimento, Em homologacao e Em teste na
-- TI. O intervalo e limitado ao Terminal/Fechamento Decision.
--
-- Eventos de status: ST, RO (reabertura) e RE. O SDM grava como RE a ida para
-- homologacao ('Em andamento' -> 'Em homologacao'); sem ele, o status ativo
-- anterior seguia correndo ate o terminal. So entra RE com transicao textual,
-- para que um RE sem status nao pare o relogio.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#StatusEventosFARC_DEC') IS NOT NULL DROP TABLE #StatusEventosFARC_DEC;

;WITH PrimeiroST AS (
    SELECT
        b.id,
        txt.texto_log,
        ROW_NUMBER() OVER (PARTITION BY b.id ORDER BY al.system_time ASC) AS rn
    FROM #BaseEscopoFARC_DEC AS b
    JOIN dbo.act_log AS al
        ON al.call_req_id = b.persid
    CROSS APPLY (
        SELECT texto_log =
            CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
            CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
    ) AS txt
    WHERE al.system_time IS NOT NULL
      AND al.type IN ('ST', 'RO') -- RO = reabertura ('X' -> 'Reaberto')
      AND b.inicio_contagem_epoch IS NOT NULL
      AND al.system_time >= b.inicio_contagem_epoch
      AND b.fechamento_decision_epoch IS NOT NULL
      AND al.system_time <= b.fechamento_decision_epoch
)
SELECT
    b.id,
    b.inicio_contagem_epoch AS evento_epoch,
    CAST(CASE
        WHEN fst.texto_log COLLATE Latin1_General_CI_AI LIKE N'%de ''Agendado''%'
          OR fst.texto_log COLLATE Latin1_General_CI_AI LIKE N'%from ''Scheduled''%'
          OR (fst.texto_log COLLATE Latin1_General_CI_AI LIKE N'%de ''Aguarda atendimento''%'
              AND fst.texto_log COLLATE Latin1_General_CI_AI NOT LIKE N'%de ''Aberto, aguarda atendimento''%')
          OR fst.texto_log COLLATE Latin1_General_CI_AI LIKE N'%de ''Em homologação''%'
          OR fst.texto_log COLLATE Latin1_General_CI_AI LIKE N'%de ''Em teste na TI''%'
            THEN 0
        ELSE 1
    END AS bit) AS ativo,
    CONVERT(tinyint, 0) AS ordem_evento
INTO #StatusEventosFARC_DEC
FROM #BaseEscopoFARC_DEC AS b
LEFT JOIN PrimeiroST AS fst
    ON fst.id = b.id
   AND fst.rn = 1
WHERE b.inicio_contagem_epoch IS NOT NULL
  AND b.fechamento_decision_epoch IS NOT NULL
  AND b.inicio_contagem_epoch < b.fechamento_decision_epoch

UNION ALL

SELECT
    b.id,
    al.system_time AS evento_epoch,
    CAST(CASE
        WHEN txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%para ''Em andamento''%'
          OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%to ''In Progress''%'
          OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%NOVO=''Em andamento''%'
          OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%New Value=''In Progress''%'
          OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%para ''Aberto, aguarda atendimento''%'
          -- Reaberto conta como atendimento (orientacao do gerente, 2026-10-06).
          OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%para ''Reaberto''%'
          OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%to ''Reopened''%'
            THEN 1
        ELSE 0
    END AS bit) AS ativo,
    CONVERT(tinyint, 2) AS ordem_evento
FROM #BaseEscopoFARC_DEC AS b
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
CROSS APPLY (
    SELECT texto_log =
        CONVERT(nvarchar(max), ISNULL(al.description, N'')) + N' ' +
        CONVERT(nvarchar(max), ISNULL(al.action_desc,  N''))
) AS txt
WHERE al.system_time IS NOT NULL
  AND (   al.type IN ('ST', 'RO')
       OR (al.type = 'RE'
           AND (   txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%alterado de ''%'' para ''%'
                OR txt.texto_log COLLATE Latin1_General_CI_AI LIKE N'%changed from ''%'' to ''%')))
  AND b.inicio_contagem_epoch IS NOT NULL
  AND al.system_time >= b.inicio_contagem_epoch
  AND b.fechamento_decision_epoch IS NOT NULL
  AND al.system_time <= b.fechamento_decision_epoch

UNION ALL

-- SOLN (2026-10-06): a solucao registrada encerra o trecho ativo; o chamado fica
-- parado ate o proximo evento de status (a reabertura volta a contar). No mesmo
-- segundo, o SOLN vem antes dos ST/RO (ordem_evento 1 x 2).
SELECT
    b.id,
    al.system_time AS evento_epoch,
    CAST(0 AS bit) AS ativo,
    CONVERT(tinyint, 1) AS ordem_evento
FROM #BaseEscopoFARC_DEC AS b
JOIN dbo.act_log AS al
    ON al.call_req_id = b.persid
WHERE al.system_time IS NOT NULL
  AND al.type = 'SOLN'
  AND b.inicio_contagem_epoch IS NOT NULL
  AND al.system_time >= b.inicio_contagem_epoch
  AND b.fechamento_decision_epoch IS NOT NULL
  AND al.system_time < b.fechamento_decision_epoch;

CREATE INDEX IX_StatusEventosFARC_DEC_id_time
    ON #StatusEventosFARC_DEC(id, evento_epoch, ordem_evento);

IF OBJECT_ID('tempdb..#IntervalosStatusFARC_DEC') IS NOT NULL DROP TABLE #IntervalosStatusFARC_DEC;

;WITH Ordenado AS (
    SELECT
        s.id,
        s.evento_epoch AS ini_epoch,
        LEAD(s.evento_epoch) OVER (
            PARTITION BY s.id
            ORDER BY s.evento_epoch, s.ordem_evento
        ) AS prox_epoch,
        s.ativo
    FROM #StatusEventosFARC_DEC AS s
),
Cortado AS (
    SELECT
        o.id,
        o.ini_epoch,
        CASE
            WHEN COALESCE(o.prox_epoch, b.fechamento_decision_epoch) > b.fechamento_decision_epoch
                THEN b.fechamento_decision_epoch
            ELSE COALESCE(o.prox_epoch, b.fechamento_decision_epoch)
        END AS fim_epoch,
        o.ativo
    FROM Ordenado AS o
    JOIN #BaseEscopoFARC_DEC AS b
        ON b.id = o.id
)
SELECT
    id,
    ini_epoch,
    fim_epoch
INTO #IntervalosStatusFARC_DEC
FROM Cortado
WHERE ativo = 1
  AND fim_epoch > ini_epoch;

CREATE INDEX IX_IntervalosStatusFARC_DEC_id
    ON #IntervalosStatusFARC_DEC(id, ini_epoch, fim_epoch);

--------------------------------------------------------------------------------
-- [9.2.1] Tempo SUSPENSO do FARC, por chamado  (CORRECAO 2026-07-30)
--
-- PROBLEMA CORRIGIDO
--   O motor de rotina [9.1] mede o intervalo Data Abertura FARC -> Fechamento
--   Decision e aplica o calendario, mas NAO desconta os periodos em que o
--   relogio esteve parado. Para a rotina tipica isso e inofensivo, porque ela
--   nao tem suspensao: abre, trabalha e fecha. Quando a rotina de fato passa por
--   status suspenso, porem, o motor conta a suspensao como se fosse trabalho.
--
--   Prova (chamado 1700873, SwitchSAN, ciclo 30/05-29/06, severidade 4):
--     intervalo abertura -> terminal, em horas comerciais .... 142:44:45
--     Agendado          18/05 10:36:20 -> 25/05 14:15:11 ......  63:38:51
--     Aguard. doc/publ. 25/05 14:16:22 -> 01/06 10:15:30 ......  55:59:08
--     142:44:45 - 119:37:59 = 23:06:46
--   O relatorio oficial (CT_SAN, coluna X) traz exatamente 23:06:46, e os logs
--   trazem os proprios eventos SLADELAY / SLARESUME do SDM marcando o inicio e o
--   fim de cada suspensao. Mesmo padrao confirmado em 1700884 (22:52:43, bate) e
--   1700889 (22:45:28; o relatorio traz 22:46:49, e o motor NMS do FAIA chega
--   independentemente ao mesmo 22:45:28 a partir dos mesmos logs).
--
--   Sem o desconto, esses tres chamados produziam FARC 16,55 / 16,51 / 16,48
--   onde o valor correto e ZERO. Eram os UNICOS tres chamados com FARC diferente
--   de zero no periodo 30/04 a 29/06/2026.
--
-- O QUE ESTE BLOCO FAZ
--   Materializa os intervalos INATIVOS do FARC - exatamente o complemento dos
--   intervalos que [9.2] ja usa como ativos, vindos do mesmo #StatusEventosFARC_DEC
--   e ja cortados no mesmo terminal. Nao ha regra de status nova: a classificacao
--   ativo/inativo continua sendo a do proprio FARC.
--
--   O total e calculado nas DUAS bases de calendario, porque o motor de rotina
--   escolhe entre elas por chamado (coluna base_calendario de [9.1]):
--     segundos_suspensos_corridos    - relogio 24x7
--     segundos_suspensos_comerciais  - seg-sex 08:00-20:00, sem feriado/facultativo
--
--   Suspensao posterior ao terminal do FARC nao entra: os intervalos ja nascem
--   cortados em fechamento_decision_epoch.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#IntervalosInativosFARC_DEC') IS NOT NULL DROP TABLE #IntervalosInativosFARC_DEC;

;WITH Ordenado AS (
    SELECT
        s.id,
        s.evento_epoch AS ini_epoch,
        LEAD(s.evento_epoch) OVER (
            PARTITION BY s.id
            ORDER BY s.evento_epoch, s.ordem_evento
        ) AS prox_epoch,
        s.ativo
    FROM #StatusEventosFARC_DEC AS s
),
Cortado AS (
    SELECT
        o.id,
        o.ini_epoch,
        CASE
            WHEN COALESCE(o.prox_epoch, b.fechamento_decision_epoch) > b.fechamento_decision_epoch
                THEN b.fechamento_decision_epoch
            ELSE COALESCE(o.prox_epoch, b.fechamento_decision_epoch)
        END AS fim_epoch,
        o.ativo
    FROM Ordenado AS o
    JOIN #BaseEscopoFARC_DEC AS b
        ON b.id = o.id
)
SELECT
    id,
    ini_epoch,
    fim_epoch
INTO #IntervalosInativosFARC_DEC
FROM Cortado
WHERE ativo = 0
  AND fim_epoch > ini_epoch;

CREATE INDEX IX_IntervalosInativosFARC_DEC_id
    ON #IntervalosInativosFARC_DEC(id, ini_epoch, fim_epoch);

IF OBJECT_ID('tempdb..#SuspRotinaFARC_DEC') IS NOT NULL DROP TABLE #SuspRotinaFARC_DEC;

-- Os eventos de status sao sequenciais e nao se sobrepoem (cada intervalo vai de
-- um evento ate o proximo), portanto a soma direta nao conta o mesmo segundo
-- duas vezes. O corte no terminal e comum a todos.
SELECT
    p.id,
    SUM(CONVERT(bigint, corrido.seg)) AS segundos_suspensos_corridos,
    SUM(CONVERT(bigint, ISNULL(comercial.seg, 0))) AS segundos_suspensos_comerciais
INTO #SuspRotinaFARC_DEC
FROM #IntervalosInativosFARC_DEC AS p
CROSS APPLY (
    SELECT
        ini_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.ini_epoch, @Epoch)),
        fim_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.fim_epoch, @Epoch))
) AS br
CROSS APPLY (
    SELECT seg = CASE WHEN p.fim_epoch > p.ini_epoch
                      THEN CONVERT(bigint, p.fim_epoch) - CONVERT(bigint, p.ini_epoch)
                      ELSE CONVERT(bigint, 0) END
) AS corrido
OUTER APPLY (
    SELECT seg = COALESCE(SUM(x.segundos_dia), 0)
    FROM (
        SELECT
            segundos_dia = CASE
                WHEN janela.fim_calc > janela.ini_calc
                    THEN DATEDIFF(SECOND, janela.ini_calc, janela.fim_calc)
                ELSE 0
            END
        FROM #Nums_DEC AS n
        CROSS APPLY (
            SELECT
                dt_date = CAST(DATEADD(DAY, n.n, CAST(br.ini_br AS date)) AS date),
                mes_dia = RIGHT(CONVERT(char(10), CAST(DATEADD(DAY, n.n, CAST(br.ini_br AS date)) AS date), 120), 5)
        ) AS d
        CROSS APPLY (
            SELECT
                eh_feriado_ou_facultativo = CASE
                    WHEN EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = d.mes_dia)
                      OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = d.dt_date)
                    THEN 1 ELSE 0
                END,
                eh_dia_util = CASE
                    WHEN DATEDIFF(DAY, '19000101', d.dt_date) % 7 BETWEEN 0 AND 4
                    THEN 1 ELSE 0
                END
        ) AS cal
        CROSS APPLY (
            SELECT
                ini_calc = CASE WHEN br.ini_br > DATEADD(HOUR, @HoraInicioComercial, CAST(d.dt_date AS datetime2(0)))
                                THEN br.ini_br ELSE DATEADD(HOUR, @HoraInicioComercial, CAST(d.dt_date AS datetime2(0))) END,
                fim_calc = CASE WHEN br.fim_br < DATEADD(HOUR, @HoraFimComercial, CAST(d.dt_date AS datetime2(0)))
                                THEN br.fim_br ELSE DATEADD(HOUR, @HoraFimComercial, CAST(d.dt_date AS datetime2(0))) END
        ) AS janela
        WHERE n.n <= DATEDIFF(DAY, CAST(br.ini_br AS date), CAST(br.fim_br AS date))
          AND cal.eh_feriado_ou_facultativo = 0
          AND cal.eh_dia_util = 1
    ) AS x
) AS comercial
GROUP BY p.id;

CREATE UNIQUE CLUSTERED INDEX IX_SuspRotinaFARC_DEC_id ON #SuspRotinaFARC_DEC(id);

--------------------------------------------------------------------------------
-- [9.2.2] Tempo de rotina LIQUIDO = bruto [9.1] - suspenso [9.2.1]
--
-- O desconto e feito na MESMA base de calendario que [9.1] usou, informada pela
-- coluna base_calendario. Piso em zero.
--
-- #TempoAtendRotina_DEC e recriada aqui com EXATAMENTE as duas colunas que ela
-- sempre teve (id, tempo_atendimento_rotina_seg), agora ja liquidas. Assim
-- [9.3] permanece identico ao que era e nenhuma temporaria preexistente muda de
-- esquema - ver a nota em [9.1] sobre Msg 207.
--
-- Rotina sem suspensao desconta zero: o valor passa intacto. Foi o caso de 237
-- dos 245 chamados do periodo 30/04 a 29/06/2026.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#TempoAtendRotina_DEC') IS NOT NULL DROP TABLE #TempoAtendRotina_DEC;

SELECT
    br.id,
    CASE
        WHEN br.tempo_atendimento_rotina_seg IS NULL THEN NULL
        WHEN br.tempo_atendimento_rotina_seg - d.segundos_descontados < 0
            THEN CONVERT(bigint, 0)
        ELSE CONVERT(bigint, br.tempo_atendimento_rotina_seg) - d.segundos_descontados
    END AS tempo_atendimento_rotina_seg
INTO #TempoAtendRotina_DEC
FROM #TempoAtendRotinaBruto_DEC AS br
LEFT JOIN #SuspRotinaFARC_DEC AS sp
    ON sp.id = br.id
CROSS APPLY (
    SELECT segundos_descontados =
        CASE br.base_calendario
            WHEN 'CORRIDO'   THEN ISNULL(sp.segundos_suspensos_corridos, 0)
            WHEN 'COMERCIAL' THEN ISNULL(sp.segundos_suspensos_comerciais, 0)
            ELSE CONVERT(bigint, 0)
        END
) AS d;

CREATE UNIQUE CLUSTERED INDEX IX_TempoAtendRotina_DEC_id ON #TempoAtendRotina_DEC(id);

IF OBJECT_ID('tempdb..#TempoAtendStatusLead_DEC') IS NOT NULL DROP TABLE #TempoAtendStatusLead_DEC;

SELECT
    b.id,
    SUM(CASE
        WHEN sl.tipo_resolucao = 'CORRIDA'
            THEN COALESCE(tempo.segundos_calculados, 0)
        WHEN sl.tipo_resolucao = 'COMERCIAL'
            THEN COALESCE(tempo.segundos_calculados, 0)
        ELSE 0
    END) AS tempo_atendimento_status_lead_seg
INTO #TempoAtendStatusLead_DEC
FROM #BaseEscopoFARC_DEC AS b
LEFT JOIN @SLA_FARC AS sl
    ON sl.prioridade = b.prioridade_nivel
   AND sl.tipo_chamado = b.[type] COLLATE DATABASE_DEFAULT
LEFT JOIN #IntervalosStatusFARC_DEC AS p
    ON p.id = b.id
OUTER APPLY (
    SELECT segundos_calculados = COALESCE(SUM(x.segundos_dia), 0)
    FROM (
        SELECT
            segundos_dia = CASE
                WHEN janela.fim_calc > janela.ini_calc
                    THEN DATEDIFF(SECOND, janela.ini_calc, janela.fim_calc)
                ELSE 0
            END
        FROM (
            SELECT DATEADD(DAY, n.n, CAST(DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.ini_epoch, @Epoch)) AS date)) AS dt
            FROM #Nums_DEC AS n
            WHERE p.ini_epoch IS NOT NULL
              AND p.fim_epoch IS NOT NULL
              AND p.fim_epoch >= p.ini_epoch
              AND n.n <= DATEDIFF(
                    DAY,
                    CAST(DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.ini_epoch, @Epoch)) AS date),
                    CAST(DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.fim_epoch, @Epoch)) AS date)
                  )
        ) AS dias
        CROSS APPLY (
            SELECT
                ini_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.ini_epoch, @Epoch)),
                fim_br = DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, p.fim_epoch, @Epoch)),
                dt_date = CAST(dias.dt AS date),
                mes_dia = RIGHT(CONVERT(char(10), CAST(dias.dt AS date), 120), 5)
        ) AS d
        CROSS APPLY (
            SELECT
                eh_feriado_ou_facultativo = CASE
                    WHEN EXISTS (SELECT 1 FROM #FeriadosFixos_DEC fx WHERE fx.mes_dia = d.mes_dia)
                      OR EXISTS (SELECT 1 FROM #FeriadosPorData_DEC fd WHERE fd.data = d.dt_date)
                    THEN 1 ELSE 0
                END,
                eh_dia_util = CASE
                    WHEN DATEDIFF(DAY, '19000101', d.dt_date) % 7 BETWEEN 0 AND 4
                    THEN 1 ELSE 0
                END
        ) AS cal
        CROSS APPLY (
            SELECT
                inicio_janela = CASE
                    WHEN sl.tipo_resolucao = 'COMERCIAL'
                        THEN DATEADD(HOUR, @HoraInicioComercial, CAST(d.dt_date AS datetime2(0)))
                    ELSE CAST(d.dt_date AS datetime2(0))
                END,
                fim_janela = CASE
                    WHEN sl.tipo_resolucao = 'COMERCIAL'
                        THEN DATEADD(HOUR, @HoraFimComercial, CAST(d.dt_date AS datetime2(0)))
                    ELSE DATEADD(DAY, 1, CAST(d.dt_date AS datetime2(0)))
                END
        ) AS h
        CROSS APPLY (
            SELECT
                ini_calc = CASE WHEN d.ini_br > h.inicio_janela THEN d.ini_br ELSE h.inicio_janela END,
                fim_calc = CASE WHEN d.fim_br < h.fim_janela    THEN d.fim_br ELSE h.fim_janela    END
        ) AS janela
        WHERE cal.eh_feriado_ou_facultativo = 0
          AND (
                sl.tipo_resolucao = 'CORRIDA'
             OR (sl.tipo_resolucao = 'COMERCIAL' AND cal.eh_dia_util = 1)
          )
    ) AS x
) AS tempo
GROUP BY b.id;

CREATE UNIQUE CLUSTERED INDEX IX_TempoAtendStatusLead_DEC_id
    ON #TempoAtendStatusLead_DEC(id);

--------------------------------------------------------------------------------
-- [9.3] Escolha do motor base do FARC
--
-- Bloco IDENTICO ao original: escolhe entre o motor de rotina e o de status e
-- nada mais. O desconto do tempo suspenso ja veio pronto de [9.2.2], dentro de
-- #TempoAtendRotina_DEC, na mesma base de calendario que [9.1] usou.
--
-- O motor de status ([9.2]) NAO recebe desconto: ele ja soma apenas os
-- intervalos ativos, ou seja, ja nasce liquido.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#MotorBaseFARC_DEC') IS NOT NULL DROP TABLE #MotorBaseFARC_DEC;

SELECT
    b.id,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM #RotinasFARC_DEC AS ro
            WHERE (ro.categoria_like IS NOT NULL AND b.categoria_sym COLLATE Latin1_General_CI_AI LIKE ro.categoria_like COLLATE Latin1_General_CI_AI)
               OR (ro.resumo_like    IS NOT NULL AND b.summary_txt    COLLATE Latin1_General_CI_AI LIKE ro.resumo_like COLLATE Latin1_General_CI_AI)
        )
            THEN tr.tempo_atendimento_rotina_seg
        ELSE tsl.tempo_atendimento_status_lead_seg
    END AS tempo_base_seg,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM #RotinasFARC_DEC AS ro
            WHERE (ro.categoria_like IS NOT NULL AND b.categoria_sym COLLATE Latin1_General_CI_AI LIKE ro.categoria_like COLLATE Latin1_General_CI_AI)
               OR (ro.resumo_like    IS NOT NULL AND b.summary_txt    COLLATE Latin1_General_CI_AI LIKE ro.resumo_like COLLATE Latin1_General_CI_AI)
        )
            THEN N'ROTINA_INTERVALO_ABERTURA_FECHAMENTO_DECISION'
        ELSE N'STATUS_ATIVO_ABERTO_FILA_E_EM_ANDAMENTO'
    END AS regra_base
INTO #MotorBaseFARC_DEC
FROM #BaseEscopoFARC_DEC AS b
LEFT JOIN #TempoAtendRotina_DEC AS tr
    ON tr.id = b.id
LEFT JOIN #TempoAtendStatusLead_DEC AS tsl
    ON tsl.id = b.id;

CREATE UNIQUE CLUSTERED INDEX IX_MotorBaseFARC_DEC_id ON #MotorBaseFARC_DEC(id);

--------------------------------------------------------------------------------
-- [9.4] Intervalo SOLN -> SRVY_SENT por chamado, para o Tempo de Atendimento
--
-- POR QUE ESTE BLOCO EXISTE
--   O terminal do FARC e o proprio SOLN. O envio da pesquisa (SRVY_SENT) vem
--   alguns segundos depois e, por isso, cai FORA da janela medida pelos motores
--   de rotina e de status. O [Tempo Suspenso] ja contabiliza esse par; o
--   [Tempo de Atendimento] nao contabilizava. Este bloco fornece o intervalo para
--   que a coluna passe a soma-lo.
--
-- REGRA DE PAREAMENTO
--   Identica a de #ParesSolnSrvy_DEC (que alimenta o Tempo Suspenso do FAIA):
--   para cada SOLN dentro de open_date..close_date, o PRIMEIRO SRVY_SENT
--   posterior a ele, anterior ao PROXIMO SOLN e ainda dentro de close_date.
--
--   Uma tabela propria e necessaria porque #ParesSolnSrvy_DEC e construida sobre
--   #BaseEscopoFAIA_DEC, e o escopo do FAIA e um SUBCONJUNTO do escopo do FARC
--   (#EscopoFAIA_DEC filtra #EscopoIds_DEC). Reaproveitar a tabela do FAIA
--   deixaria sem intervalo justamente os chamados que existem so no FARC. As
--   regras sao as mesmas; o que muda e a base de chamados. O FAIA nao e tocado.
--
-- POR QUE NAO HA DUPLA CONTAGEM
--   - DISTINCT no SOLN: um mesmo SOLN nao gera duas linhas.
--   - Cada SRVY_SENT e limitado pelo SOLN seguinte, entao dois pares nunca se
--     sobrepoem no tempo.
--   - So entram pares com srvy_epoch > soln_epoch, o que elimina intervalo
--     negativo ou SRVY_SENT anterior ao SOLN.
--   - A agregacao e por chamado (GROUP BY), com indice unico por id: nao
--     multiplica linhas no resultado final.
--   - Sem par valido, o chamado nem aparece aqui e o ISNULL soma ZERO.
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#ParSolnSrvyFARC_DEC') IS NOT NULL DROP TABLE #ParSolnSrvyFARC_DEC;

-- OTIMIZADO: mesmo calculo compartilhado de [7.5], agora apenas agregado por
-- chamado. A base ja esta restrita ao escopo FARC, que e o escopo deste bloco.
SELECT
    p.id,
    SUM(CONVERT(bigint, p.srvy_epoch) - CONVERT(bigint, p.soln_epoch)) AS par_soln_srvy_seg
INTO #ParSolnSrvyFARC_DEC
FROM #ParesBaseSolnSrvy_DEC AS p
GROUP BY p.id;

CREATE UNIQUE CLUSTERED INDEX IX_ParSolnSrvyFARC_DEC_id ON #ParSolnSrvyFARC_DEC(id);

--------------------------------------------------------------------------------
-- [10] RESULTADO CONSOLIDADO - uma linha por chamado
--
-- Linhas: dirigidas por #BaseEscopoFARC_DEC, que e o escopo unificado. Todo
-- chamado do escopo aparece exatamente uma vez. As colunas de FAIA vem de
-- #CalcFAIA_DEC por LEFT JOIN; quando o chamado nao satisfaz a exigencia de
-- encerrar no grupo Decision, elas saem NULL em vez de a linha desaparecer.
--
-- Cardinalidade: #CalcFAIA_DEC e #MotorBaseFARC_DEC tem indice UNICO por id, e
-- @SLA_FARC tem PK por (tipo_chamado, prioridade). Nenhum JOIN multiplica SDM.
--
-- ORDEM DAS COLUNAS
--   1 a 23  colunas do SELECT final do FAIA, na ordem original.
--   24 a 29 colunas EXCLUSIVAS do FARC, na ordem relativa original.
--   Nao existe segundo bloco de colunas compartilhadas no fim do resultado.
--
-- COLUNAS DEDUPLICADAS (mesma informacao nos dois lados; ficou a do FAIA):
--   SDM, Tipo Chamado, Severidade, Status, Categoria, Responsavel Abertura,
--   Responsavel Atendimento, Resumo, Indicador Reabertura, Acordo Prazo,
--   Acordo Qualidade, Justificativa, Tempo Total Decision, Tempo suspenso.
--
-- DEDUPLICACAO DAS DATAS (revisao 2026-07-29)
--   A versao anterior preservava tres colunas de data do lado FARC com nome
--   distinto, por terem ORIGEM diferente. A revisao mudou o criterio: o que
--   decide e a FUNCAO da coluna no relatorio, nao a origem tecnica. As tres
--   respondiam a mesma pergunta que uma coluna do FAIA ja respondia, entao
--   foram REMOVIDAS do resultado e o conceito ficou com a versao do FAIA:
--
--     removida [Data Abertura FARC]               -> [Data de Abertura]
--     removida [Data Captura FARC]                -> [Data Captura]
--     removida [Data de Fechamento Decision FARC] -> [Data de Encerramento Decision]
--
--   O fato de os valores divergirem NAO justificava manter as duas: a
--   divergencia e o sintoma de duas implementacoes do mesmo conceito. Para
--   conceitos compartilhados, a versao corrigida do FAIA e a fonte de verdade.
--
--   Os marcos internos correspondentes continuam existindo e alimentando os
--   motores do FARC; apenas deixaram de ser expostos como coluna.
--
-- COLUNA DO FARC QUE NAO E DUPLICADA E PERMANECE:
--   [Data Resolução] = call_req.resolve_date. E um marco proprio do SDM, que nao
--   coincide com a abertura, nem com o close_date de [Data de Encerramento Total
--   do Chamado], nem com a ida a homologacao de [Data de Encerramento Decision].
--------------------------------------------------------------------------------
IF OBJECT_ID('tempdb..#ResultadoFAIAFARC_DEC') IS NOT NULL DROP TABLE #ResultadoFAIAFARC_DEC;

;WITH FinalFARC AS (
    SELECT
        b.id,
        b.persid,
        b.ref_num,
        b.[type],
        b.prioridade_nivel,
        b.status_sym,
        b.categoria_sym,
        b.responsavel_abertura,
        b.responsavel_atendimento,
        b.summary_txt,
        b.open_date,
        b.close_date,
        b.data_abertura_br,
        b.data_captura_br,
        b.data_resolucao_br,
        b.data_fechamento_decision_br,
        b.data_fechamento_cliente_br,
        b.indicador_reabertura,
        sl.meta_resolucao_seg,
        sl.tipo_resolucao,
        sl.fator_resolucao,
        rb.tempo_base_seg AS tempo_atendimento_seg,
        rb.regra_base AS regra_tempo_farc,
        -- Valor EXIBIDO em [Tempo de Atendimento]: o tempo medido pelos motores
        -- MAIS o intervalo SOLN -> SRVY_SENT ([9.4]). Sem par valido soma zero.
        --
        -- ISOLAMENTO DELIBERADO: este valor alimenta SOMENTE a coluna
        -- [Tempo de Atendimento]. O excedente abaixo continua sendo calculado a
        -- partir de rb.tempo_base_seg puro, para que [Tempo Atendimento
        -- Excedido], [Meta Atendimento], [nHR_FARC] e [FARC] NAO se movam.
        CASE
            WHEN rb.tempo_base_seg IS NULL THEN NULL
            ELSE CONVERT(bigint, rb.tempo_base_seg) + ISNULL(psv.par_soln_srvy_seg, 0)
        END AS tempo_atendimento_exibicao_seg,
        CASE
            WHEN rb.tempo_base_seg IS NULL OR sl.meta_resolucao_seg IS NULL THEN NULL
            WHEN rb.tempo_base_seg > sl.meta_resolucao_seg THEN rb.tempo_base_seg - sl.meta_resolucao_seg
            ELSE 0
        END AS atendimento_excedido_seg
    FROM #BaseEscopoFARC_DEC AS b
    LEFT JOIN @SLA_FARC AS sl
        ON sl.prioridade = b.prioridade_nivel
       AND sl.tipo_chamado = b.[type] COLLATE DATABASE_DEFAULT
    LEFT JOIN #MotorBaseFARC_DEC AS rb
        ON rb.id = b.id
    LEFT JOIN #ParSolnSrvyFARC_DEC AS psv
        ON psv.id = b.id
)
SELECT
    -- ============================ COLUNAS DO FAIA ============================
    f.ref_num AS [SDM],
    CASE f.[type]
        WHEN 'I' THEN N'Incidente'
        WHEN 'R' THEN N'Solicitação'
        WHEN 'P' THEN N'Problema'
        WHEN 'C' THEN N'Mudança'
        ELSE CONCAT(N'Outro/Não mapeado: ', ISNULL(CONVERT(nvarchar(10), f.[type]), N'NULO'))
    END AS [Tipo Chamado],
    CASE f.prioridade_nivel
        WHEN 1 THEN N'1 - Máxima'
        WHEN 2 THEN N'2 - Alta'
        WHEN 3 THEN N'3 - Média'
        WHEN 4 THEN N'4 - Baixa'
        WHEN 5 THEN N'5 - Mínima'
        ELSE N'NãoInformada'
    END AS [Severidade],
    ISNULL(f.status_sym, N'N/A') AS [Status],
    ISNULL(f.categoria_sym, N'N/A') AS [Categoria],
    f.responsavel_abertura AS [Responsável Abertura],
    f.responsavel_atendimento AS [Responsável Atendimento],
    LTRIM(RTRIM(f.summary_txt)) AS [Resumo],
    -- Item de configuracao do chamado, o campo 'Item de configuracao' da tela
    -- do SDM: call_req.affected_rc -> ca_owned_resource. Sem IC, NULL.
    own_ic.resource_name AS [Item de Configuração],

    -- Datas: abertura original, close_date total e ultimo marco comprovado de
    -- entrada em homologacao (ST/NOVO, SOLN implicito ou LOG especial).
    CASE WHEN f.open_date IS NULL THEN NULL
         ELSE DATEADD(HOUR, -@HorasBrasilParaUTC, DATEADD(SECOND, f.open_date, @Epoch))
    END AS [Data de Abertura],

    -- Entrada no grupo Fornecedores - Decision: PRIMEIRA vez que o chamado caiu
    -- no grupo. Nao substitui [Data Captura], que marca a primeira ida para
    -- 'Em andamento' e, por definicao, vem depois.
    CASE WHEN egd.entrada_grupo_decision_epoch IS NULL THEN NULL
         ELSE DATEADD(
                HOUR,
                -@HorasBrasilParaUTC,
                DATEADD(SECOND, egd.entrada_grupo_decision_epoch, @Epoch)
              )
    END AS [Data Entrada Grupo Decision],
    f.data_fechamento_cliente_br AS [Data de Encerramento Total do Chamado],
    CASE WHEN cf.encerramento_decision_epoch IS NULL THEN NULL
         ELSE DATEADD(
                HOUR,
                -@HorasBrasilParaUTC,
                DATEADD(SECOND, cf.encerramento_decision_epoch, @Epoch)
              )
    END AS [Data de Encerramento Decision],

    -- SOLN/CL/SRVY_SENT participam como MARCOS, nunca como soma/subtracao de
    -- time_spent. O terceiro componente (fora da apuracao) fica no diagnostico.
    CASE WHEN cf.ttd_seg IS NULL THEN NULL ELSE CONCAT(
        CONVERT(varchar(30), cf.ttd_seg / 3600), N':',
        RIGHT(N'00' + CONVERT(varchar(2), (cf.ttd_seg % 3600) / 60), 2), N':',
        RIGHT(N'00' + CONVERT(varchar(2), cf.ttd_seg % 60), 2)
    ) END AS [Tempo Total Decision],

    CASE WHEN cf.susp_seg IS NULL THEN NULL ELSE CONCAT(
        CONVERT(varchar(30), cf.susp_seg / 3600), N':',
        RIGHT(N'00' + CONVERT(varchar(2), (cf.susp_seg % 3600) / 60), 2), N':',
        RIGHT(N'00' + CONVERT(varchar(2), cf.susp_seg % 60), 2)
    ) END AS [Tempo suspenso],

    cf.data_captura_br AS [Data Captura],

    CASE WHEN cf.tempo_primeiro_seg IS NULL THEN NULL ELSE CONCAT(
        CONVERT(varchar(20), cf.tempo_primeiro_seg / 3600), N':',
        RIGHT(N'00' + CONVERT(varchar(2), (cf.tempo_primeiro_seg % 3600) / 60), 2), N':',
        RIGHT(N'00' + CONVERT(varchar(2), cf.tempo_primeiro_seg % 60), 2)
    ) END AS [Tempo Primeiro Atendimento],

    CASE WHEN cf.primeiro_excedido_seg IS NULL THEN NULL ELSE CONCAT(
        CONVERT(varchar(20), cf.primeiro_excedido_seg / 3600), N':',
        RIGHT(N'00' + CONVERT(varchar(2), (cf.primeiro_excedido_seg % 3600) / 60), 2), N':',
        RIGHT(N'00' + CONVERT(varchar(2), cf.primeiro_excedido_seg % 60), 2)
    ) END AS [Primeiro Atendimento Excedido],

    CASE
        WHEN cf.primeiro_excedido_seg IS NULL THEN N'N/A'
        WHEN cf.primeiro_excedido_seg > 0 THEN N'Não Atende'
        ELSE N'Atende'
    END AS [Meta Primeiro Atendimento],
    f.indicador_reabertura AS [Indicador Reabertura],
    N'-' AS [Acordo Prazo],
    N'-' AS [Acordo Qualidade],
    N'-' AS [Justificativa],

    -- nHR_FAIA PROPORCIONAL: fracao de hora NAO vira hora inteira.
    -- 5400 s / 3600 = 1.50 (nunca 2).
    CASE WHEN cf.primeiro_excedido_seg IS NULL THEN NULL ELSE
        CONVERT(decimal(18, 2), cf.primeiro_excedido_seg / 3600.0)
    END AS [nHR_FAIA],

    -- FAIA calculado a partir do quociente cheio, nao de um nHR ja arredondado.
    -- Fator do FAIA: 0,40 LibQuantum / 0,10 Demais.
    CASE WHEN cf.primeiro_excedido_seg IS NULL THEN NULL ELSE
        CONVERT(decimal(18, 2), (cf.primeiro_excedido_seg / 3600.0) * ISNULL(cf.fator_inicio, 0.1))
    END AS [FAIA],

    -- ===================== COLUNAS EXCLUSIVAS DO FARC ========================
    --
    -- DEDUPLICACAO (revisao 2026-07-29): tres colunas de data que o bloco FARC
    -- trazia foram REMOVIDAS do resultado por representarem o MESMO CONCEITO de
    -- colunas que o bloco FAIA ja entrega. Para conceitos compartilhados, a
    -- versao do FAIA e a fonte de verdade, ainda que os valores divirjam - a
    -- divergencia e justamente o sintoma de duas implementacoes do mesmo conceito:
    --
    --   [Data Abertura FARC]              -> coberta por [Data de Abertura]
    --   [Data Captura FARC]               -> coberta por [Data Captura]
    --   [Data de Fechamento Decision FARC]-> coberta por [Data de Encerramento Decision]
    --
    -- As estruturas internas que produzem esses marcos NAO foram removidas:
    -- data_abertura_br, data_captura_br e fechamento_decision_epoch continuam
    -- alimentando #TerminalFARC_DEC, #TempoAtendRotina_DEC,
    -- #StatusEventosFARC_DEC e #TempoAtendStatusLead_DEC, ou seja, o Tempo de
    -- Atendimento, o excedente, o nHR_FARC e o FARC seguem intactos.
    --
    -- [Data Resolução] PERMANECE: e o call_req.resolve_date, um marco proprio do
    -- SDM que nao coincide com nenhuma coluna do FAIA. Nao e a abertura, nao e o
    -- close_date de [Data de Encerramento Total do Chamado] e nao e a ida a
    -- homologacao de [Data de Encerramento Decision].
    f.data_resolucao_br AS [Data Resolução],

    CASE WHEN f.tempo_atendimento_exibicao_seg IS NULL THEN NULL ELSE CONCAT(
        CONVERT(varchar(20), f.tempo_atendimento_exibicao_seg / 3600), N':',
        RIGHT(N'00' + CONVERT(varchar(2), (f.tempo_atendimento_exibicao_seg % 3600) / 60), 2), N':',
        RIGHT(N'00' + CONVERT(varchar(2), f.tempo_atendimento_exibicao_seg % 60), 2)
    ) END AS [Tempo de Atendimento],

    CASE WHEN f.atendimento_excedido_seg IS NULL THEN NULL ELSE CONCAT(
        CONVERT(varchar(20), f.atendimento_excedido_seg / 3600), N':',
        RIGHT(N'00' + CONVERT(varchar(2), (f.atendimento_excedido_seg % 3600) / 60), 2), N':',
        RIGHT(N'00' + CONVERT(varchar(2), f.atendimento_excedido_seg % 60), 2)
    ) END AS [Tempo Atendimento Excedido],

    CASE
        WHEN f.atendimento_excedido_seg IS NULL THEN N'N/A'
        WHEN f.atendimento_excedido_seg > 0 THEN N'Não Atende'
        ELSE N'Atende'
    END AS [Meta Atendimento],

    -- nHR_FARC PROPORCIONAL: mesmo padrao decimal(18,2) do nHR_FAIA.
    -- Antes: CEILING(CONVERT(decimal(18,6), excedido) / 3600.0), que transformava
    -- 5400 s em 2. Agora 5400 / 3600 = 1.50.
    CASE WHEN f.atendimento_excedido_seg IS NULL THEN NULL ELSE
        CONVERT(decimal(18, 2), f.atendimento_excedido_seg / 3600.0)
    END AS [nHR_FARC],

    -- FARC calculado a partir do quociente cheio, nao de um nHR arredondado.
    -- Fator do FARC preservado: 0,40 / 0,20 / 0,30 conforme @SLA_FARC.
    CASE WHEN f.atendimento_excedido_seg IS NULL THEN NULL ELSE
        CONVERT(decimal(18, 2), (f.atendimento_excedido_seg / 3600.0) * ISNULL(f.fator_resolucao, 0.30))
    END AS [FARC]
INTO #ResultadoFAIAFARC_DEC
FROM FinalFARC AS f
LEFT JOIN #CalcFAIA_DEC AS cf
    ON cf.id = f.id
LEFT JOIN #EntradaGrupoDecision_DEC AS egd
    ON egd.id = f.id
-- Item de configuracao. As duas juncoes usam a chave primaria do lado direito
-- (call_req.id e ca_owned_resource.own_resource_uuid): no maximo um IC por
-- chamado, sem multiplicar linha.
LEFT JOIN dbo.call_req AS cr_ic
    ON cr_ic.id = f.id
LEFT JOIN dbo.ca_owned_resource AS own_ic
    ON own_ic.own_resource_uuid = cr_ic.affected_rc
OPTION (RECOMPILE);

CREATE INDEX IX_ResultadoFAIAFARC_DEC_ordem
    ON #ResultadoFAIAFARC_DEC([Data de Encerramento Total do Chamado], [SDM]);

--------------------------------------------------------------------------------
-- [11] RESULT SET UNICO (Power BI)
--
-- A consulta manual expoe varias janelas opcionais (@QtdTotalChamados,
-- @ResultadoTudo, @G1, @G2, @SAN, @Servidores, @LibQuantum) e um bloco de
-- diagnostico [12]. Nenhum deles existe aqui: o conector do Power BI consome
-- apenas o PRIMEIRO result set e descartaria os demais em silencio.
--
-- Sai o conjunto COMPLETO, sem filtro de categoria. Equivale ao
-- @ResultadoTudo = 1 da consulta manual com @MostrarDiagnostico = 0.
-- O recorte por G1, G2, SAN, Servidores ou LibQuantum passa a ser feito no
-- proprio Power BI, pela coluna [Categoria], que ja vem no resultado.
--
-- Mesmas colunas, mesma ordem e mesmos aliases da consulta consolidada.
-- Uma linha por chamado (SDM).
--------------------------------------------------------------------------------
SELECT *
FROM #ResultadoFAIAFARC_DEC
ORDER BY [Data de Encerramento Total do Chamado] ASC, [SDM] ASC;
