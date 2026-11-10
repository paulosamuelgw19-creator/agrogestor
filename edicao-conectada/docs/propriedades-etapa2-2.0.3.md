# Propriedades e Talhões — etapa 2 — 2.0.3+2006

14/10/2026. Piloto de homologação. Esta etapa não migra dados reais nem substitui o servidor anterior em execução.

## Decisões confirmadas pelo responsável

- Operações em vários talhões terão distribuição de valores informada manualmente, com conferência da soma. Não haverá distribuição automática pela área.
- A tarifa horária de máquinas não inclui manutenção. Manutenção será registrada separadamente, com vínculo e origem próprios.
- Existem outros emuladores com dados. A conciliação deles é pré-condição para a migração real.

Essas decisões orientam a próxima etapa de operações e custos. O rateio em vários talhões e a despesa de manutenção ainda não foram implementados nesta etapa.

## Desenvolvido

- Entrada independente no menu: **Propriedades e Talhões**.
- Cadastro de propriedade com cliente responsável, nome, área opcional, localização e observações.
- Cadastro e edição de talhões com nome, área opcional, observações e vínculo permanente com a propriedade.
- Consulta das culturas por safra/ciclo de cada talhão; acesso ao cadastro existente de culturas/safras mantendo a propriedade selecionada. Não é criado um campo de cultura que sobrescreva as safras anteriores.
- Edição de propriedades e talhões com versão esperada; uma edição concorrente recebe conflito e exige atualização.
- Arquivar/reativar sem exclusão de registros. A propriedade arquivada impede novas operações, entradas de estoque, talhões e ciclos. Talhão arquivado impede novas operações e ciclos. Reenvios já confirmados continuam reconhecidos.
- Validação da soma de áreas conhecidas dos talhões ativos, inclusive na edição e reativação. Área ausente permanece nula; zero não substitui informação ausente.
- Somente administrador altera os cadastros nesta etapa. Demais contas consultam apenas propriedades autorizadas. O servidor valida organização, permissões e vínculos.
- Novas operações guardam um retrato dos cadastros de propriedade, talhão, cultura e ciclo no momento da gravação. Renomear ou editar o cadastro não altera esse retrato.
- Auditoria de alterações e revisões dos cadastros com autor, data, versão e valores anteriores.

## Banco e compatibilidade

Migração aditiva 4: localização, observações, arquivamento e versão em propriedades/talhões; tabelas `v2_catalog_revisions` e `v2_operation_context`. Migrações 1 a 3 permanecem intactas.

IDs, relações, movimentos de estoque e operações anteriores são conservados. Operações anteriores à atualização recebem `context_status=not_recorded_before_upgrade`; o sistema não inventa um retrato cadastral do passado. Revisões de cadastros anteriores são capturadas antes da primeira edição, com essa procedência explícita.

A edição cadastral não modifica a área já registrada na safra nem os custos das operações anteriores. Operações novas respeitam as áreas conhecidas do ciclo e do talhão atual. Revisões cadastrais não constituem um módulo de mapas, limites geográficos ou vigências agronômicas retroativas.

A importação planejada passa a conservar localização da propriedade e observações de propriedade/talhão. Áreas e culturas antigas continuam exigindo conferência. Nenhum plano de importação é aplicado automaticamente.

O app exige servidor com `propertyCatalog=true` (esquema 4) para esta área. O servidor antigo da porta 8765 não oferece essas rotas; o app apresenta a necessidade do piloto habilitado. Não é suficiente instalar o APK para ativar os cadastros v2 no servidor anterior.

## Validação

- 42 testes do servidor passaram. Novos casos cobrem edição com conflito, auditoria, preservação de retratos/custos, arquivamento sem perda de relatórios, bloqueio de novos lançamentos, área na reativação, acesso entre organizações e atualização repetida de um banco anterior.
- 64 testes Flutter passaram em uma execução com API real temporária, isolada e dados fictícios. Inclui formulários, preservação de área ausente, decimal com vírgula, cancelamento e criação/arquivamento pela API a partir do cliente Dart.
- `flutter analyze`: nenhum problema encontrado.
- APK debug de homologação compilado. A assinatura permanece a mesma da versão anterior.

## Pendente

- Rateio manual em vários talhões, com soma exata dos valores e consumo único de estoque.
- Custo de mão de obra, combustível conciliado, manutenção e despesas gerais.
- Histórico completo paginado por talhão, com filtros e todos os módulos.
- Relatórios financeiros consolidados por propriedade/talhão, incluindo as novas categorias de despesa.
- Conciliação dos emuladores anteriores, migração real e ativação do servidor piloto para o usuário.

A etapa 2 entrega o cadastro independente e suas regras no servidor; o módulo completo de custos e histórico continua em desenvolvimento nas etapas seguintes. IA e n8n continuam fora do escopo.
