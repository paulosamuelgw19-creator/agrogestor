# AgroGestor 2.1.5 — gestão e relatórios

Implementação sobre Flutter/Dart, SQLite local, fila durável e API FastAPI/Python com SQLite do PC gestor. O aplicativo não foi recriado. IA e n8n permanecem fora desta entrega.

## Diagnóstico e alterações

O cadastro existente já mantinha propriedades, talhões, culturas e ciclos com identificadores permanentes, arquivamento e revisões. Entretanto, exigia um cliente no campo apresentado como responsável e cadastrava somente um talhão por vez. Agora o responsável é um funcionário opcional, separado do cliente/proprietário; uma fazenda e seus talhões são enviados em uma transação única. A fila local também confirma ou desfaz todo o conjunto. A soma de áreas usa precisão decimal e não altera a área total da fazenda. As edições preservam os identificadores e o histórico.

Oficina, Tarefas e Funcionários têm acessos separados. A oficina mantém ordens, andamento, peças e checklists. A visão geral mantém agenda, alertas, estoque mínimo e indicadores existentes; acrescenta o resumo integrado e acesso aos relatórios. Nenhuma tarefa ou funcionário foi apagado.

Os relatórios administrativos usam consultas do servidor, restritas ao perfil `admin`, inclusive para quem recebeu uma permissão de gerente em uma propriedade. Consultas diretas de operador e mecânico são recusadas. Há filtros combináveis por fazenda, talhão, ciclo, período, atividade, máquina, operador, mecânico e status, conforme os vínculos disponíveis em cada relatório. Filtros sem vínculo válido são recusados, em vez de ignorados. Exportações PDF e XLSX usam o mesmo retrato recebido, com filtros, geração e identificadores de origem.

Relatórios disponíveis: operações, histórico dos talhões, máquinas, oficina, estoque, acompanhamento da safra e custos. O histórico inclui o contexto registrado na operação, abastecimentos, insumos, horas, valores disponíveis, alterações e serviços da oficina. Períodos de parada são obtidos dos eventos de bloqueio/liberação registrados na auditoria. Os registros anteriores que ainda pertencem ao módulo legado continuam acessíveis pelo botão de relatórios anteriores; não são unidos por nomes ou aproximações.

## Área e acompanhamento da safra

Uma programação identifica safra, atividade e os ciclos/talhões participantes, com a área programada em cada um. Não se convertem operações antigas automaticamente em área única concluída.

Ao concluir uma operação, o usuário pode informar a programação e a **área única acumulada** já concluída naquele talhão. Uma repetição do trabalho mantém o mesmo acumulado. A versão do progresso impede que dois aparelhos sobrescrevam seus avanços silenciosamente. O servidor não permite programar o mesmo talhão duas vezes para a mesma atividade e safra, mesmo usando ciclos diferentes.

Progresso = área única acumulada / área programada × 100. Restante = programada − concluída. Cada atividade mantém seu próprio percentual. O número de talhões concluídos considera somente os programados. Valores novos começam em zero por decisão explícita de criar uma programação, não por ausência de medições históricas.

Previsão de término, quando existem avanços positivos em pelo menos dois dias distintos: média = avanços de área única / dias corridos entre o primeiro e o último avanço, inclusive. Prazo restante = teto(área restante / média). A data prevista parte do último avanço registrado, vem identificada como estimativa e depende da continuidade desse ritmo. Sem dados suficientes, fica indisponível.

Área de passadas mede esforço e pode incluir retrabalho; não é somada como cobertura única. A produtividade por máquina só atribui a área de uma operação quando há uma única máquina; operações com várias máquinas, sem rateio informado, ficam com área por máquina desconhecida. Horas são as diferenças de horímetro registradas. O responsável da tarefa prevalece como operador responsável quando o gestor registrou sua conclusão; o autor do lançamento continua identificado separadamente.

## Custos e combustível

O consolidado identifica cada origem e mantém as categorias Máquinas, Combustível, Insumos, Manutenção, Mão de obra e Outras despesas. Não cria despesas ausentes e não soma aquisição de máquina aos custos operacionais.

- Máquina: horas × tarifa registrada, em centavos. A tarifa continua sem combustível, manutenção e mão de obra.
- Insumos e combustível do estoque: valor da baixa real, calculado pelo estoque existente. Um abastecimento do estoque não é somado novamente.
- Combustível de posto: valor do abastecimento externo, uma única vez.
- Na consulta de uma máquina, o combustível do estoque usa o rateio já registrado nos abastecimentos, substituindo a baixa compartilhada nessa consulta.
- Oficina: peças pelos movimentos vinculados ao andamento, serviço e mão de obra informados. A mesma baixa de peças não entra novamente como outro consumo.
- Mão de obra agrícola: valor opcional informado pelo gestor. Horas sem preço deixam o custo incompleto.
- Manutenção sem vínculo com talhão permanece como despesa geral da fazenda; não há divisão automática pelos talhões.
- Custo por hectare: custo dos registros selecionados / área correspondente informada. Sem área ou preço suficiente, não é calculado; o subtotal conhecido continua visível.

Consumo medido de combustível tem campo próprio, independente dos litros abastecidos. Horários de início e término são opcionais e armazenados com fuso. O aplicativo não apresenta litros abastecidos como consumo efetivamente medido.

O estoque mínimo gera alerta ao atingir **ou ficar abaixo** do limite. Diesel utiliza litros. O cadastro direto de produto/peça cria item, inventário inicial e limite em uma transação idempotente. O alerta identifica a fazenda e o produto; o painel apresenta saldo disponível e limite. Ajustes e estornos anteriores permanecem preservados.

Posição de estoque e progresso programado representam o estado atual. O período selecionado filtra os lançamentos do histórico; isso é informado na tela e na exportação.

## Migração e segurança da atualização

A migração 9 adiciona responsável opcional, observação do produto, medições de operações, programações e eventos de progresso. Não reescreve operações antigas nem preenche preços ou medições ausentes. As migrações 1 a 8 mantêm seus checksums.

Antes de atualizar: backup integral do aplicativo do gestor, backup consistente do SQLite do piloto e ensaio em uma cópia. A migração foi executada duas vezes na cópia e comparou todos os valores das colunas anteriores, integridade e chaves estrangeiras. A atualização Android usa instalação sobreposta, sem desinstalar ou limpar dados.

O erro `COMMIT: no current transaction` foi reproduzido em Android ao abrir a mesma conexão SQLite nativa por dois isolates. A recuperação de conexão do sqflite executava um ROLLBACK durante a transação de outro isolate. A correção usa uma conexão nativa por engine; a execução em segundo plano também deixa de iniciar temporizadores da sessão principal e fecha sua conexão ao terminar. O ensaio `tool/native_database_probe.dart` reproduziu a falha anterior e confirmou três gravações corretas com a alteração, usando somente bancos descartáveis.

## Validação e limites

Testes automatizados verificam cadastro composto e rollback, responsável opcional, edição/arquivamento, estoque, alertas no limite, permissões, isolamento, custos sem duplicação, cobertura acumulada, retrabalho, conflito entre aparelhos, estorno, safras separadas, estimativa, exportações e regressões dos módulos anteriores. Há também integração entre fila SQLite do cliente e API real usando uma base temporária. Os resultados finais da execução e as verificações no emulador ficam registrados junto à entrega.

Os relatórios mostram **custos registrados conhecidos**, não lucro, fluxo de caixa ou custo integral da cultura. Receitas, custos não lançados e valores desconhecidos não são inventados. A validação automatizada e no emulador não substitui a homologação do produtor em aparelhos reais e com seus procedimentos de trabalho.

Continuam fora deste escopo: IA/n8n, publicação iOS, implantação comercial de infraestrutura e importação automática de lançamentos legados sem vínculos confiáveis. A nova programação é criada com conexão ao PC gestor; a conclusão de operações continua utilizando a fila offline existente e pode gerar um conflito para conferência se outro aparelho avançar o mesmo talhão antes da sincronização.


## Resultado da execução de 15/10/2026

- Aplicativo: suíte completa com 110 testes aprovados; integração adicional da fila SQLite com uma API real temporária aprovada. Testes das áreas alteradas e de responsividade repetidos após os últimos ajustes.
- Servidor: suíte completa com 87 testes aprovados, seguida de dois casos adicionais aprovados (denominador da área filtrada e reservas de estoque). São 89 casos distintos; os 11 casos do módulo novo foram conferidos em conjunto.
- `flutter analyze --no-pub`: sem problemas.
- Android: falha de COMMIT reproduzida no cenário antigo e três transações corretas com a conexão independente.
- Migração: ensaio repetido e comparação da base atual confirmaram a preservação dos valores anteriores de 42 tabelas de negócio, com integridade e chaves estrangeiras válidas.
- Atualização sobreposta dos perfis gestor, operador e mecânico, com cópia antes de cada instalação e comparação dos bancos e filas antes/depois. O emulador antigo de índice 2 foi preservado.

Os arquivos de validação e backups ficam na entrega local, fora dos fontes públicos. Nenhuma senha, chave de API, base de dados de uso ou conta de teste autenticada é incluída no pacote de fontes.

A homologação em celulares reais permanece pendente. Operações antigas sem vínculo confiável continuam separadas; não se tenta relacioná-las automaticamente por nome. Cada lançamento agrícola atual referencia um ciclo/talhão; a programação de safra reúne vários talhões. Um lançamento único com rateio manual entre vários talhões ainda exige uma etapa específica.
