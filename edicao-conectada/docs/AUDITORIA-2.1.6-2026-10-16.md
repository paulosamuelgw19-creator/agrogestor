# Auditoria AgroGestor 2.1.6 — consolidação de testes em 21/10/2026

Base: commit 24ab30a. Este documento registra evidências; não constitui aprovação de produção.

## Inventário e diagnóstico inicial

Flutter/Dart no Android; Riverpod, navegação própria e go_router; SQLite/sqflite para cache e filas; SharedPreferences para coleções antigas. PC gestor: FastAPI/Python/SQLite, APIs v1 e v2. Central de licenças e contratos: outro FastAPI/SQLite. Não foi identificado servidor em nuvem configurado para este piloto.

| Área | Situação inicial observada | Componentes principais | Ação planejada |
|---|---|---|---|
| Acesso | Backend verifica organização, propriedade, autor e papel; há testes automatizados | auth, v2_api.py, work_api.py | Regressão e testes negativos das novas rotas |
| Fazendas/talhões | Cadastro local, múltiplos talhões, responsável opcional, arquivamento e revisões | properties_screen.dart, catalog_store.dart, v2_catalog.py | Preservar e agregar mapa independente da área cadastral |
| Mapas | Não implementados na base | Nenhuma dependência geográfica na versão inicial | Polígonos versionados, área geodésica, desenho offline, conflito explícito |
| Frota | Cadastro v2/horímetro/tarifa/vínculos; fotos no cadastro antigo, sem galeria v2 | operations_screen.dart, machines/, work_api.py | Reutilizar armazenamento de anexos para galeria e fila de envio |
| Implementos | Cadastro antigo sem fotos nem vínculo persistido na operação v2 | implements/ | Fotos e evidências por operação; preservar identificadores e catálogo |
| Operações | Operações, máquinas, insumos, combustível, horas, estorno e contexto histórico | v2_api.py, v2_models.py, operations_screen.dart | Registrar produção real na colheita, unidade e peso opcional |
| Insumos/estoque | Catálogo unificado, ledger, reserva, inventário, mínimos e alertas | work_api.py, management_api.py | Regressão de saldos, idempotência e custos |
| Combustível | Estoque e posto; abastecimento separado da medição de consumo | refueling.py | Manter distinção e conferir relatórios |
| Tarefas/oficina | Atribuições, privacidade, progresso, peças, encerramento e fotos | work_* | Regressão por papel; preservar manutenção e tarefas separadas |
| Safra | Programação e área única acumulada com versão | management_api.py, management_schema.py | Não somar passadas como área única; testar colheita integrada |
| Relatórios | Oito relatórios, filtros, PDF e XLSX; sem produção medida nem implementos | management_reports_screen.dart, v2_export.dart | Novos relatórios, traduções, gráfico de subtotais e filtros do resumo |
| Sincronização | Filas duráveis por servidor/organização/conta, conflitos e acesso offline limitado | sync_service.dart, *_store.dart | Incluir mapas/fotos sem apagar pendências ao falhar |
| Planos | Limites e módulos verificados no PC; central com revisões e auditoria | commercial.py, central_license/ | Regressão; mapas usam módulo de propriedades, fotos/implementos usam frota |

## Plano de execução e riscos

1. Validar base, inventariar serviços e guardar backup com ensaio de restauração.
2. Migração adicional 11: demarcações, produção colhida e uso de implementos. Não modificar migrações 1–10, não preencher históricos com valores presumidos.
3. Conectar telas existentes às novas rotas, manter permissões, preservar rascunhos e mostrar conflitos.
4. Testar cálculos/áreas/unidades, isolamento, permissões, repetição, migrações, exportações e dimensões; compilar apenas para teste após os testes.
5. Reiniciar somente o servidor piloto com backup e conferir preservação. Atualização dos emuladores por instalação sobreposta, sem desinstalar nem limpar dados.
6. Registrar evidências finais e pendências. Nenhuma publicação de produção automática.

Riscos: incompatibilidade com servidor antigo resulta em pendência/revisão, não perda; alterações concorrentes de polígonos exigem versão e revisão; hectares desenhados são estimativas e não substituem automaticamente a área cadastral. Produção antiga sem quantidade continua desconhecida. Sacas/caixas sem peso não são convertidas para kg. Rendimento registrado por hectare do ciclo não certifica encerramento de safra.

Recuperação: backup independente em `../backups/antes-auditoria-mapas-producao-2026-10-16/`, com `before.sqlite3`, cópia restaurada e hashes de tabelas/colunas antigas. Para regressão estrutural, parar o piloto, preservar também o banco atualizado e anexos, restaurar banco e fontes anteriores em conjunto; nunca apontar código anterior a banco novo sem verificar compatibilidade. Dados de produção e emuladores originais não são alvo de descarte.

## A — Resultado por módulo

A tabela do inventário acima registra o diagnóstico anterior às alterações. Resultado desta etapa:

| Módulo | Alteração efetiva / estado final | Evidência e limite |
|---|---|---|
| Autenticação, permissões e planos | Reutilizados; novas rotas verificam organização, propriedade, perfil e módulo contratado | Regressões e testes negativos de mapas, anexos e relatórios; não equivale a auditoria externa de segurança |
| Fazendas e talhões | Cadastros existentes preservados, com acesso ao mapa nos detalhes | Gestor abriu lista e detalhes; cadastro múltiplo e responsável opcional já pertenciam à base |
| Mapas | Polígonos versionados, cores, nomes, vértices editáveis, área WGS84 estimada, exclusão lógica com motivo e revisão de conflito | Backend, filas offline e widgets testados; mapa de ruas abriu no MuMu. Satélite e busca de endereço dependem de chave/configuração externa |
| Máquinas e implementos | Galerias com anexos privados e fila durável; implementos vinculados à operação com identificação histórica | Upload/leitura binários e isolamento testados; câmera em celular físico não executada |
| Operações e colheita | Produção informada em kg, t, saca ou caixa; peso necessário para converter saca/caixa em kg | Integração real isolada: 25 sacas de 60 kg = 1.500 kg; ciclo de 10 ha = 150 kg/ha |
| Insumos, estoque e combustível | Regras existentes preservadas; combustível abastecido permanece distinto do consumo medido | Regressões de movimentação/idempotência/custos; não há conversão automática de abastecimento em consumo |
| Tarefas e oficina | Áreas e registros existentes preservados | Telas individuais do operador e mecânico carregaram; privacidade verificada por testes de backend |
| Safras | Programação existente preservada; produção medida agregada por ciclo/talhão | Denominador é a área registrada do ciclo. Passadas repetidas não viram hectares únicos; produção parcial não certifica rendimento final |
| Relatórios | Acrescentados produção e implementos; resumo com filtros e gráficos dos custos conhecidos; exportação legível de indicadores/moeda | Testes de filtros/cálculos/controle financeiro, PDF renderizado e XLSX aberto. Exportação detalhada é documental e ainda contém alguns identificadores/rótulos técnicos |
| Sincronização | Mapas e fotos entram em filas isoladas por servidor, organização e conta | Reabertura, expiração de acesso, repetição e conflito testados; pendências não são apagadas ao falhar |
| Infraestrutura | JDK 17 portátil configurado; APK de teste compilado e instalado por sobreposição em três MuMus | Bancos comparados antes/depois, sem desinstalar ou limpar dados; nenhuma publicação externa |

Não foram adicionados rastreamento de funcionários, coleta GPS ou IA/n8n. Não foi recriado o aplicativo.

## B — Interface e verificação visual

- Testes de widgets das novas áreas em 320×640, 360×800 e 900×600, com fonte ampliada, passaram. Isso não afirma cobertura manual de todas as telas antigas.
- Controles de desenho foram posicionados antes do mapa: arrastar o mapa não deve impedir alcançar os comandos na rolagem.
- Capturas manuais dos três perfis em retrato: gestor com 3 fazendas/8 talhões/14 operações concluídas; operador com suas tarefas; mecânico com suas ordens. Esses registros de demonstração já existiam e estão identificados como fictícios.
- Gestor: menu separa Tarefas, Oficina e Funcionários; lista de fazendas, detalhes e mapa de ruas abriram. Nenhuma demarcação artificial foi salva nas propriedades existentes durante essa conferência.
- Evidências locais: `../temporarios/auditoria-2026-10-20/emuladores/`, incluindo `gestor-conectado.png`, `operador-conectado.png`, `mecanico-conectado.png`, `fazenda-detalhes-final.png` e `mapa-final.png`.
- PDF revisado de 10 páginas: primeira, intermediária e última inspecionadas visualmente; todas as páginas verificadas quanto a texto fora dos limites. Planilha XLSX aberta com 255 linhas e 2 colunas. São exportações de fixture fictícia em banco temporário, sem completar relatórios reais com dados inventados.
- Refinamento editorial pendente: a exportação documental extensa preserva identificadores e alguns nomes técnicos de campos; alguns rótulos antigos de centavos aparecem ao lado de valores monetários já formatados. Os totais testados não dependem desses rótulos.

## C — Servidores, emuladores e configuração

- Sincronização piloto: `http://127.0.0.1:8766`, FastAPI/SQLite, migração 11. Central de contratos/licenças de teste: `http://127.0.0.1:8771`. Ambos com processo ativo em terminal visível na conferência final. Serviços de produção não foram redirecionados.
- MuMus de teste 0, 1 e 3 atualizados: gestor (16384), mecânico (16416) e operador (16480). MuMu 2 original preservado e desligado. APK instalado com `install -r`; autenticação, preferências, filas e dados não foram apagados.
- Foi encontrado desvio de quase cinco dias no relógio dos três Androids. Isso fazia o cache autenticado parecer vencido apesar de resposta válida do servidor. Horário dos emuladores corrigido para o PC; diferença final medida de 0 segundo em cada um. As regras de expiração de token/cache não foram enfraquecidas.
- Java antigo configurado havia sido removido. Instalado Microsoft OpenJDK 17.0.21 portátil, com ZIP de origem oficial e SHA-256 verificado, em uma pasta local de ferramentas. Flutter configurado para esse JDK; Gradle compilou normalmente.
- O acesso atual é local aos testes. Celulares reais exigem conferir rota privada/HTTPS, certificados, disponibilidade do PC e sincronização fora do emulador. Não se deve copiar `10.0.2.2` para um celular físico.
- Segredos continuam fora do pacote de fontes; não foram criadas chaves pagas nem alteradas credenciais do cliente.

Mapas: Flutter Map 8.3.2; ruas OpenStreetMap online, atribuição e identificação do aplicativo. Não há download em lote nem garantia de imagens offline. Rascunho e geometria persistem localmente; fundo sem imagem disponível. Satélite e pesquisa textual têm integração MapTiler preparada, sem chave nesta compilação. Antes de habilitar comercialmente, confirmar plano, atribuição, custo e cotas do provedor. Referências consultadas: [política OSM](https://operations.osmfoundation.org/policies/tiles/), [Flutter Map](https://pub.dev/packages/flutter_map), [API MapTiler](https://docs.maptiler.com/cloud/api/tiles/), [preços MapTiler](https://www.maptiler.com/cloud/pricing/), [GeographicLib](https://geographiclib.sourceforge.io/html/python/), [Microsoft OpenJDK](https://learn.microsoft.com/en-us/java/openjdk/download).

## D — Banco, preservação e recuperação

- Mantidos Flutter/Dart, SQLite local e FastAPI/Python/SQLite no PC. Migrações 1–10 preservadas; migração adicional 11 cria demarcações, produção da colheita e uso de implementos.
- Identificadores estáveis e contexto histórico preservam vínculos após renomear cadastros. Geometria não altera automaticamente hectares cadastrais. Remoção de demarcação é lógica/auditada; conflito de versão exige revisão explícita.
- Valores ausentes continuam desconhecidos. Zero informado é zero. Saca/caixa sem peso não é convertida em kg. Produção/ha usa área do ciclo conhecido e escopo explícito. Implemento anexado não gera cobrança adicional, e custos consolidados reutilizam o ledger existente.
- Ensaios de backup/restauração e migração repetida: integridade SQLite OK, nenhuma chave estrangeira inválida e hashes/quantidades de colunas antigas preservados. Banco piloto inicializou na versão 11 com integridade OK.
- Backup mais recente: `../backups/antes-validacao-2026-10-20/`; contém banco anterior, cópia de restauração, anexos quando presentes e TARs privados dos três aplicativos. Cada `app-<porta>-preservation.json` registra igualdade das linhas antes/depois da instalação, integridade e referências válidas. Backups contêm dados sensíveis e não integram o pacote público de fontes.
- Recuperação: parar o piloto, preservar uma cópia do banco atualizado e anexos, restaurar banco e fontes anteriores em conjunto, validar integridade e testar antes de reabrir aos aparelhos. Não restaurar um backup antigo sobre lançamentos novos sem reconciliá-los.

## E — Testes e limitações

| Verificação | Resultado registrado |
|---|---|
| Base do servidor antes das mudanças | 100 testes passaram, 102,259 s |
| Bateria do servidor com novas funções | 107 passaram, 106,212 s |
| Repetição após últimos ajustes de autorização/precisão | 7 testes direcionados passaram, 14,561 s; a bateria completa não foi repetida após esses pequenos ajustes |
| Central de licenças/contratos | 17 passaram, 34,902 s; código da central não foi alterado |
| Bateria Flutter | 126 passaram; 1 teste de API real separado desta execução |
| Integração Dart → FastAPI → SQLite e exportação | Conjunto de 7 testes passou, incluindo produção, mapa, foto, PDF/XLSX |
| Última repetição de offline/widgets | 15 passaram, incluindo conflitos, escopo, validade de acesso e dimensões |
| Análise estática lib/test | Sem problemas na última execução registrada |
| Compilação APK | Sucesso, 250,2 s |
| Instalação e preservação | Sucesso nos três emuladores; comparação das bases antes/depois igual |
| Relógio/conexão | Horário corrigido nos três; telas carregaram dados por perfil |
| PDF/XLSX | 10 páginas, sem texto fora dos limites; 255 linhas/2 colunas; dados fictícios identificados |

Falhas encontradas e resolvidas: simulador de upload decodificava binário como UTF-8; callback de sincronização podia retornar a própria Future; controles abaixo do mapa dificultavam rolagem; primeira exportação expunha métricas internas; instalação Java ausente; relógios Android adiantados invalidavam acesso local. Uma resposta 404 para foto de máquina sem autorização é proteção intencional contra enumeração, não defeito.

Não executado: celulares físicos, iOS, câmera/permissões em hardware real, testes prolongados de campo/conexão remota, carga com clientes simultâneos, pentest independente, satélite/geocodificação com chave comercial. Nenhuma dessas etapas é apresentada como aprovada. Não houve inspeção manual exaustiva de todas as telas antigas nem validação humana de todos os cenários financeiros possíveis.

## F — Arquivos alterados nesta etapa

- `docs/AUDITORIA-2.1.6-2026-10-16.md`
- `lib/features/implements/implements_screen.dart`
- `lib/features/machines/catalog_photos.dart`
- `lib/features/operations_v2/management_reports_screen.dart`
- `lib/features/operations_v2/operations_screen.dart`
- `lib/features/operations_v2/v2_export.dart`
- `lib/features/properties/geography_screen.dart`
- `lib/features/properties/geography_store.dart`
- `lib/features/properties/properties_screen.dart`
- `lib/features/sync/sync_service.dart`
- `pubspec.lock`
- `pubspec.yaml`
- `server/agrogestor_server/geography.py`
- `server/agrogestor_server/harvest.py`
- `server/agrogestor_server/implement_usage.py`
- `server/agrogestor_server/management_api.py`
- `server/agrogestor_server/v2_api.py`
- `server/agrogestor_server/v2_models.py`
- `server/agrogestor_server/v2_schema.py`
- `server/agrogestor_server/work_api.py`
- `server/requirements.txt`
- `server/tests/test_geography_harvest.py`
- `server/tests/test_logistics_foundation.py`
- `server/tests/test_v2_pilot.py`
- `test/audit_ui_test.dart`
- `test/geography_offline_test.dart`
- `test/v2_real_api_test.dart`
- `tool/commercial_backup.py`

## G — Classificação e entrega

**Apto para testes controlados nos emuladores, com restrições. Não é aprovação de produção ou comercialização.** As funções implementadas têm validação automatizada e a instalação preservou os dados dos três aparelhos de teste; conectividade e navegação básica por perfil foram conferidas. As limitações da seção E e a configuração de mapas externos permanecem abertas.

APK candidato: `../APK/AgroGestor-2.1.6-auditoria-teste.apk`, versão 2.1.6, código 2015, assinatura de depuração compatível com os emuladores. SHA-256: `070bb11c1f3d92e210bf551cdc0bd69c5feaf836633708d1fd084731e978148b`.

Fontes desta etapa e manifesto de hashes ficam separados dos pacotes anteriores. Nenhum envio ao GitHub, lançamento em loja ou alteração automática de produção foi realizado. Próxima validação recomendada: aparelho Android físico com rede privada/HTTPS, câmera, trabalho offline e reconciliação entre gestor e operador.
