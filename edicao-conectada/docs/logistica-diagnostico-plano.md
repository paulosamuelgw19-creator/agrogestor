# AgroGestor — diagnóstico e plano de Logística

Data: 14/10/2026. Projeto analisado: piloto 2.1.1, cópia `09-AgroGestor-v2-piloto/projeto`.

Modalidades confirmadas pelo usuário: **próprio e terceirizado**. Caminhoneiros terão **conta própria**. GPS, IA e n8n ficam fora desta entrega.

## 1. Diagnóstico verificado

O aplicativo usa Flutter/Dart. O servidor do PC gestor usa Python/FastAPI. Há SQLite no servidor e no aplicativo, cache e fila de envio. A rede privada e o PC atual podem continuar; o módulo não exige outro servidor nem microserviços.

Existem duas gerações de registros. O banco antigo guarda coleções de registros; o piloto possui tabelas relacionais. Não podemos considerar que os cadastros antigos foram automaticamente importados para as tabelas novas.

| Área | O que existe | O que falta para Logística | Fonte principal |
|---|---|---|---|
| Frota anterior | Nome, marca, modelo, ano, placa, identificação, combustível, tanque, foto e horímetro | Quilômetros, capacidade com unidade, transportadora, vencimentos e estado ligado às viagens | `lib/features/machines/machine.dart` |
| Frota do piloto | Identidade, nome, horímetro, tarifa por hora e vínculo com propriedades | Perfil rodoviário e os demais campos de caminhão | `server/agrogestor_server/v2_schema.py`, `v2_models.py` |
| Funcionários | Cadastro de operador com nome, telefone, função e situação | CNH, vencimento, vínculo com transportadora e identidade de caminhoneiro | `lib/features/operators/operator.dart` |
| Contas | Gestor, operador e mecânico; convites, bloqueio de conta/aparelho | Conta restrita a viagens atribuídas | `server/agrogestor_server/app.py`, `lib/features/auth/user_model.dart` |
| Implementos | Cadastro com compatibilidade descrita em texto | Vínculo identificável de carreta ao caminhão | `lib/features/implements/farm_implement.dart` |
| Operações | Propriedade/talhão/safra, produtos, máquinas, horas e abastecimento; existe o tipo transporte | Origem, destino, motorista, frete, carga carregada/entregue e andamento da viagem | `v2_models.py`, `v2_api.py` |
| Combustível | Estoque da propriedade ou compra em posto, litros, custo e horímetro; ligado à operação | Abastecimento rodoviário com quilômetros e vínculo à viagem | `server/agrogestor_server/refueling.py` |
| Manutenção | Ordens, mecânico atribuído, diário, fotos, peças, custos e bloqueio/liberação da máquina | Ligação dos lançamentos de custo à viagem, sem recriá-los | `server/agrogestor_server/work_api.py` |
| Despesas | Custos de insumos, máquinas e abastecimento nas operações; custos da oficina separados | Pedágio, diária, alimentação, hospedagem, frete e rateio manual entre destinos | `v2_api.py`, `work_api.py` |
| Relatórios | Cálculos no servidor, tratamento de informações incompletas e exportação para PDF/Excel | Indicadores e filtros de transporte | `lib/features/operations_v2/v2_export.dart` |
| Offline | SQLite, cache por servidor/cliente/usuário, fila, identidade estável, conflitos preservados | Regras e projeções próprias de Logística, comprovantes e testes de reenvio | `v2_store.dart`, `lib/features/work/work_store.dart` |

**Não havia tabelas de viagens, caminhoneiros ou transportadoras no banco analisado.** O “Caminhão Apoio - FICTÍCIO” está registrado com 402 **horas**, não 402 quilômetros. A quilometragem inicial precisa ser informada, sem conversão presumida.

O limite atual de acesso offline é de até oito horas, também limitado pela validade da sessão e da licença. Será reutilizado; esta etapa não o amplia.

O banco do piloto antes desta etapa tinha esquema 7. A cópia antiga de produção contém 16 registros nas coleções anteriores; eles não foram alterados durante esta análise. Os dados dos emuladores antigos continuam separados e não serão importados sem identificar os vínculos.

## 2. Decisões e informações que ainda faltam

Já confirmados: transporte próprio e contratado; conta individual do caminhoneiro; rateio manual; manutenção separada da tarifa por hora atual; PC gestor e rede privada.

Os seguintes dados serão informados nos cadastros, sem bloquear a preparação da estrutura:

- Quais veículos existentes são caminhões, suas placas, capacidades e quilômetros atuais.
- Quem serão os caminhoneiros e quais contas deverão ser criadas para eles. O cadastro de funcionário não prova a identidade de uma conta.
- Transportadoras, prazos e unidades normalmente usados nas cargas.
- Componentes de eventual tarifa por quilômetro. Não presumir combustível ou manutenção incluídos.
- Fator de peso de uma saca/caixa, quando o produtor desejar conversão para toneladas.

Documentos e dados pessoais devem ficar disponíveis ao gestor e ao próprio caminhoneiro. Não solicitar senha nem divulgar documentos nos relatórios de produção.

## 3. Modelo proposto e preparado na migração 8

| Estrutura | Vínculo e função |
|---|---|
| Transportadora | Cliente/organização, contato, observações, arquivamento e versão |
| Perfil de caminhão | **Mesma identidade da frota existente**; placa única por organização, metadados, quilômetros independentes das horas, capacidade/unidade, próprio ou contratado e componentes da tarifa |
| Carreta | Identidade própria e vínculo com o caminhão; capacidade/unidade e arquivamento |
| Caminhoneiro | Cadastro pessoal, categoria/vencimento da CNH, vínculo profissional, transportadora e conta opcional |
| Restrição de conta | Marca persistente de caminhoneiro; desvincular/arquivar o cadastro não transforma essa conta em operador |
| Convite de caminhoneiro | Liga convite e cadastro; a aceitação futura será atômica, sem liberar propriedades automaticamente |
| Viagem | Caminhão, motorista, modalidade, propriedade principal, talhão/operação opcionais, origem/destino, datas, quilômetros, frete e versão |
| Carga | Produto/tipo/unidade, previsto, carregado e entregue; fator de conversão somente quando explicitamente informado |
| Andamento | Autor, situação, descrição, horário do acontecimento, horário do recebimento e valores anteriores/novos |
| Despesa | Valor em centavos ou não informado; categoria, origem e lançamento original; correção por cancelamento justificado, sem apagar |
| Rateio por destino | Parcelas manuais por propriedade/operação; soma exata do valor conhecido |
| Rateio por carga | Distribuição separada para calcular custo por produto em viagens com várias cargas; não é uma segunda despesa |
| Confirmação de estoque | Liga uma carga a uma única entrada de estoque e registra quem confirmou |
| Anexo privado | Documento, foto ou comprovante vinculado, tipo, tamanho, integridade e vencimento |
| Abastecimento rodoviário | Mesma frota e inventário, mas contador em km e ligação à viagem; não altera os abastecimentos antigos em horas |

Todos os vínculos relacionais usam também a identidade do cliente/organização. Os tipos decimais conservam precisão; dinheiro usa centavos inteiros. Valores desconhecidos permanecem nulos.

Não haverá preenchimento automático dos novos cadastros a partir de nomes parecidos. O gestor selecionará a identidade existente da frota. Caminhões terceirizados também terão identidade única nessa frota, com vínculo à transportadora.

## 4. Regras que os fluxos devem aplicar

- Disponibilidade do caminhão deriva do arquivamento, manutenção que o bloqueia e viagem ativa. Um simples botão não poderá liberá-lo durante uma manutenção.
- Caminhoneiro consulta e atualiza somente viagens atribuídas. Não recebe acesso geral às propriedades, operações de campo, outros motoristas ou finanças.
- Gestor administra cadastros, atribuições, custos e confirmação de entrega. Outros perfis não terão acesso novo automaticamente.
- Troca de atribuição ou edição concorrente exige versão esperada; conflito mantém o texto e exige conferência. Cada envio conserva o identificador para repetir sem duplicação.
- Recebimento de dados atrasados não substitui silenciosamente valores mais novos. Horário do acontecimento e do recebimento são separados.
- Uma despesa existente será referenciada pelo lançamento original. A origem não pode estar em duas despesas ativas de transporte.
- O relatório consolidado precisa reconhecer a origem já contabilizada nas operações. Somar o relatório atual ao de Logística diretamente ainda duplicaria valores; essa conciliação é trabalho da etapa 4.
- Componentes da tarifa por quilômetro serão registrados na viagem. Desembolso real e estimativa de uso serão mostrados separadamente; não se somam automaticamente componentes já incluídos na estimativa.
- Os dois rateios da mesma despesa são visões de distribuição, não valores adicionais. Quando o valor faltar, não será permitido rateá-lo como zero.
- Entrada de insumo exige entrega, quantidade/unidade compatível, produto e propriedade conferidos, inventário inicial já registrado e confirmação do gestor. Programar ou atualizar o andamento não movimenta estoque.
- Depois de uma entrada confirmada, corrigir quantidade exige procedimento explícito de ajuste de estoque e auditoria. Não gerar nova entrada para a mesma carga.
- Arquivamento mantém referências históricas. Viagens e movimentações confirmadas não têm exclusão silenciosa.

## 5. Relatórios e cálculos

Filtros: período, propriedade, caminhão, motorista e transportadora. Cada exportação informa data/hora de geração, filtros, identificação da propriedade e fontes dos totais.

| Indicador | Cálculo e unidade | Requisitos / informação incompleta |
|---|---|---|
| Quilômetros da viagem | final − inicial, em km | Dois contadores válidos e final ≥ inicial; ausência não é 0 km |
| Despesas registradas | Soma dos valores conhecidos das despesas ativas e únicas, em R$ | Se faltar valor, mostrar subtotal conhecido e situação incompleta |
| Custo por km | Despesas registradas ÷ km, em R$/km | Custos completos e distância positiva; estimativa de uso exibida separadamente |
| Estimativa de uso | km × tarifa por km, em R$ | Distância e tarifa explícitas; informar os componentes incluídos |
| Quantidade por produto | Soma de entregas do mesmo produto e unidade | Não juntar sacas, kg, toneladas e litros; ausências indicadas |
| Diferença de carga | carregado − entregue, na unidade original | Exige as duas quantidades. Diferença não prova perda: pode representar divergência ou entrega parcial |
| Custo por tonelada | Custo destinado à carga ÷ toneladas entregues, em R$/t | Custo completo e carga em t ou fator explícito; em carga mista, exigir rateio entre cargas |
| Custo por propriedade | Soma das parcelas manuais das despesas ativas | Não somar novamente o total integral de cada viagem |
| Atraso | chegada prevista vencida e viagem ainda não entregue/cancelada | Considerar fuso e data/hora de referência do relatório |

Esta análise de custos de transporte não calcula lucro, margem ou fluxo de caixa da produção. Frete contratado previsto não comprova pagamento; estimativa de utilização não é desembolso.

**Exemplo exclusivamente FICTÍCIO, ainda não cadastrado nos aparelhos:**

Uma viagem própria percorreu de 80.000 a 80.200 km: 200 km. Transportou 10 t de milho e entregou 9,9 t. Despesas confirmadas: combustível R$ 600, pedágio R$ 100 e alimentação R$ 50. Total R$ 750; custo R$ 3,75/km; diferença de quantidade 0,1 t; custo R$ 75,76/t entregue, arredondado somente na apresentação.

Rateio manual: Fazenda A R$ 450, Fazenda B R$ 300; soma R$ 750. Se a alimentação estiver sem valor, mostrar subtotal conhecido R$ 700 e **custo incompleto**, sem afirmar custo definitivo por km/tonelada.

Uma viagem terceirizada pode ter frete contratado R$ 1.200. Combustível da transportadora incluído no contrato não vira nova despesa da fazenda. Se houver R$ 80 de pedágio reembolsável, registrado separadamente, o custo registrado passa a R$ 1.280; pagamento continua exigindo informação própria.

## 6. Implementação e critérios de conclusão

1. **Base, migração e proteção de acesso.** Preparar modelo, backup/ensaio de restauração, restrição de caminhoneiro e testes de integridade. Não habilitar o módulo por ter tabelas prontas.
2. **Cadastros integrados.** Telas e gravação local de transportadora, caminhão/carreta e caminhoneiro; edição/arquivamento com versões; convite de conta restrita e documentos privados. Validar placa, identidade, privacidade e preservação de histórico.
3. **Viagens e diário.** Programar e atribuir; carga/datas/contadores; status e comprovantes; app do caminhoneiro com somente suas viagens. Validar permissões, manutenção, conflitos e reenvio.
4. **Custos e entregas.** Abastecimento em estoque ou posto, referência aos custos existentes, rateios manuais, confirmação idempotente do estoque e conciliação com relatórios de operações. Testar centavos, rollback e ausência de dupla contabilização.
5. **Relatórios e alertas.** Filtros, fontes, comparações, ausências, vencimentos e atrasos; exportação PDF/Excel. Testar unidades, cargas mistas e denominadores ausentes ou zero.
6. **Validação e instalação.** Exemplos claramente FICTÍCIOS no piloto; gestor e motorista em contas distintas; testes online/offline, conflitos, revogação e reenvio; APK nos dois emuladores de teste autorizados, preservando dados. Não atualizar os emuladores antigos nesta entrega.

## 7. Riscos e mitigação

- **Horas versus quilômetros:** colunas e telas separadas; sem conversão nem alteração do horímetro anterior.
- **Cadastro duplicado:** identidade compartilhada com a frota e placa normalizada única por cliente. Importações anteriores exigem mapeamento conferido.
- **Permissão excessiva:** não reutilizar o papel de operador como acesso efetivo do caminhoneiro. Uma marca própria permite restringir a conta sem reconstruir as tabelas antigas de usuários/convites e seus vínculos.
- **APK/servidor incompatíveis:** a capacidade de Logística ficará desabilitada até o fluxo estar pronto. O APK atual não conhece o novo perfil de caminhoneiro; não criar contas reais desse perfil antes da atualização coordenada.
- **Despesa/estoque duplicados:** unicidade de origem/entrega, transações e conciliação das fontes, que precisam ser testadas nos fluxos das etapas 3 e 4.
- **Offline e conflitos:** manter o prazo atual; confirmação de entrega/estoque aguarda servidor, com indicação clara no aparelho.
- **Documentos sensíveis:** armazenamento privado, validação de tamanho/formato e autorização a cada leitura. O envio de anexos novos ainda não está implementado.
- **Migração interrompida:** uma transação e checksums; backup antes da aplicação. Nenhuma migração pode apagar ou reescrever o histórico existente.

## 8. Estado desta entrega inicial

**Preparado no código:** migração aditiva 8, contratos de dados/validação e proteção do servidor para futuras contas de caminhoneiro. Contas de caminhoneiro não recebem compartilhamento automático de propriedades nem aparecem na seleção de operadores da oficina/tarefas.

**Ainda pendente:** endpoints de cadastros/viagens, criação/convites de contas de caminhoneiro, telas, fila/sincronização de Logística, anexos, transações de despesas/entregas, relatórios, exemplos cadastrados e atualização do APK. A integração do abastecimento rodoviário com os relatórios gerais também está pendente.

Os testes desta base não provam que os fluxos pendentes funcionam. Os bloqueios de unicidade no banco são uma camada de proteção; não substituem os testes de reenvio completo e de confirmação do estoque.

Backup e ensaio: pasta privada `backups/antes-logistica-20261014`, fora do repositório. Uma cópia do banco do piloto passou de 7 para 8 e foi migrada duas vezes; as 34 tabelas anteriores e seus 535 registros ficaram iguais. Os bancos copiados dos dois emuladores tiveram integridade e vínculos conferidos. Isso não é um ensaio de restauração de uma máquina virtual Android completa.

O servidor em uso e o APK dos emuladores continuam na versão anterior nesta entrega inicial. A migração 8 foi aplicada somente nas cópias de validação e nos bancos temporários dos testes. Nenhum dado real foi limpo ou substituído.

Validação executada: a suíte geral passou com 72 testes. Após o último ajuste de validação de despesas sem valor, os 14 testes específicos da base de Logística passaram novamente. Esses 14 incluem testes já presentes na execução geral; os números não representam 86 testes diferentes.

Foram verificados nesta etapa: migração repetida sem reescrever registros, conservação das migrações anteriores, quilômetros não preenchidos a partir de horas, vínculos entre clientes, restrições da conta de caminhoneiro, atribuição de viagem, arquivamento/bloqueio de acesso, compartilhamento de propriedades sem incluir caminhoneiros, unicidade de origem de despesa, vínculo único de entrega ao estoque, rateio exato de centavos, valores desconhecidos, unidades sem fator presumido e datas com fuso. O funcionamento completo no aplicativo, a fila de Logística e as confirmações transacionais continuam pendentes.
