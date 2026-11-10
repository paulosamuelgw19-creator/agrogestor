# Produtos e insumos — 2.0.2+2005

14/10/2026. Versão de teste/homologação. IA e n8n continuam fora desta entrega.

## Comportamento

O menu Produtos e insumos identifica a versão do servidor. Com v2 atualizado e habilitado, abre o mesmo catálogo e estoque por propriedade utilizados nas operações. A aba de produtos das operações e o atalho em Cadastros apontam para essa mesma área. No servidor anterior ou na demonstração local, abre o cadastro existente com a nova classificação, preservando os registros.

Não se escolhe outro estoque por falha de conexão. A identificação já confirmada é armazenada por endereço de servidor, organização e conta. Sem identificação prévia e sem conexão, a área pede nova tentativa. Servidores v2 anteriores ao esquema 3 exigem atualização.

## Classificação

Categoria e tipo são selecionados no cadastro novo; tipos anteriores podem permanecer sem preenchimento. Categorias antigas livres continuam disponíveis ao editar. Alterar a categoria limpa o tipo anterior para evitar combinações incorretas.

1. Químicos e minerais: fertilizantes, corretivos, herbicidas, inseticidas, fungicidas, nematicidas, acaricidas, bactericidas e adjuvantes.
2. Biológicos e orgânicos: bioinsumos, inoculantes, biofertilizantes, compostos, controle biológico e bioestimulantes.
3. Sementes e material genético: sementes, mudas, sêmen e embriões.
4. Peças e materiais de máquinas e implementos: peças, filtros, pneus, correias, mangueiras, componentes de aplicação e materiais de manutenção.
5. Insumos pecuários: rações, sais, volumosos, suplementos e produtos veterinários. A categoria não implementa manejo ou acompanhamento de animais.
6. Tecnologia e irrigação: sensores, componentes, materiais de irrigação e água.
7. Combustíveis e lubrificantes: diesel, gasolina, etanol, óleos e graxas.
8. Outros materiais: equipamentos de proteção, embalagens e outros.

Máquinas e implementos completos permanecem nos cadastros de patrimônio/frota. Serviços e assinaturas de software não recebem baixa física como se fossem materiais. A classificação não produz recomendações agronômicas.

## Dados e permissões

- Modelo anterior recebe o campo opcional `productType`; IDs, lotes, unidade, saldos e históricos permanecem.
- Migração aditiva 3 do servidor v2 acrescenta `category` e `product_type` em `v2_inputs`, com texto vazio para registros ainda não classificados. As migrações 1 e 2 não foram alteradas.
- O administrador cadastra e edita produtos. A edição v2 registra autor, data e valores anteriores; alterações concorrentes recebem conflito. Unidade e movimentos não são alterados pela edição do cadastro.
- Quantidades e custos v2 vêm das entradas e consumos do estoque por propriedade. Funcionário não recebe valores financeiros; os filtros de propriedade continuam no servidor.
- Com v2 habilitado, novas escritas nos módulos antigos `products` e `productUsage` são recusadas, inclusive de aplicativos antigos, para impedir um estoque paralelo. Reenvios de eventos já confirmados continuam reconhecidos. A leitura do histórico anterior fica preservada conforme as permissões existentes.
- O formulário antigo de serviço não baixa produtos v2. O consumo deve ser registrado nas operações da propriedade. Não foi criada uma ligação automática entre históricos de serviços v1 e operações v2.

## Migração dos produtos anteriores

O plano de importação existente agora conserva também categoria e tipo, com mapeamento determinístico de IDs. O plano deve ser revisado pelo administrador antes de aplicar. Não copia quantidade antiga para uma propriedade presumida, não converte unidades e não inventa preços. Lotes e utilizações permanecem no histórico anterior; o controle de lotes no estoque v2 ainda é pendente.

Antes de ativar v2 em dados reais: fazer backup, conferir filas antigas, revisar o plano de cadastros, conciliar o inventário por propriedade e validar unidades/saldos. Esta entrega não altera a instalação do servidor anterior em execução nem habilita v2 automaticamente.

## Validação

- Servidor: 37 testes passaram. Incluem preservação de saldo e custo na migração, reenvios anteriores, classificação em consumo real, edição auditada, conflito, permissões, isolamento e bloqueio do estoque antigo paralelo.
- Flutter: 60 testes passaram; o teste integrado dependente de fixture foi omitido nessa execução geral. Os nove testes específicos de produtos/conexão passaram novamente após os últimos ajustes de formulário.
- Integração Dart → FastAPI com dados fictícios: um teste passou separadamente, incluindo classificação do produto, fila, consumo, saldo e relatório com valores conferidos.
- `flutter analyze`: sem problemas. APK debug de homologação compilado.

O piloto v2 ainda depende de configuração própria. Nenhum cadastro ou inventário real foi criado pelos testes.
