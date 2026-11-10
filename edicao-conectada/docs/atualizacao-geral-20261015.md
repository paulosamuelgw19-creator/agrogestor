# Atualização geral — diagnóstico e execução

Base analisada em 15/10/2026: 2.1.3, esquema 8. Flutter/Dart, API FastAPI/Python no PC gestor e SQLite nos dois lados. Não substituir bancos nem misturar o piloto fictício com a organização anterior.

## Componentes e situação inicial

| Pedido | Existe | Lacuna verificada / componentes afetados |
|---|---|---|
| Perfis | Admin (gerente), operador e mecânico; conta, aparelho, organização e vínculos de propriedade | Filtro de operações baseado somente no vínculo employee; corrigir também para perfil operator em v2_api.py. Tarefas/ordens já verificam destinatário no work_api.py. |
| Tarefas | Responsável operador, safra/talhão, máquina, prazo, prioridade, previsto, descrição, histórico e conclusão atômica com operação | Não há notificações push. Fotos de ordem/checklist não equivalem a anexos de tarefa. Estado blocked não deve ser anunciado como conclusão parcial ou definitiva. |
| Operador | Operações, consumos, abastecimento junto da finalização, cache e fila | Interface mistura oficina; produtos independentes desnecessários; cadastros bloqueados para operador. |
| Propriedades | Cadastro local, edição/versionamento, arquivamento, talhões, área opcional, culturas/safras separadas | Criação pelo operador exige autorização no servidor e fila local. Não conceder a ele administração de acessos nem compartilhar automaticamente com colegas. Vários talhões no mesmo formulário ainda faltam. |
| Frota | Cadastro anterior rico e cadastro relacional básico (nome, horas, tarifa, propriedades) | Não são cadastros idênticos nem automaticamente importados. Perfil rodoviário existe apenas como fundação. Não converter horas para km. Fotos/metadados/implementos requerem integração explícita. |
| Combustível | Estoque por propriedade/insumo, entrada, ajuste, abastecimento de estoque ou posto, identidade e estorno | Não há tanques individuais nem abastecimento independente da operação. Litros abastecidos não provam consumo; não chamar custo de compra de consumo efetivo. |
| Serviços | Área antiga de serviços e WorkScreen separado | Lista de funcionários/atribuição deve usar contas reais autorizadas; disponibilidade manual e agenda são desenvolvimento novo. |
| Oficina | Ordens atribuídas, diário imutável, fotos, peças, custos separados, máquina bloqueada e revisão | Remover ação de reservar peças da tela do gerente sem apagar reservas históricas. |
| Safra | Ciclos, operações e área realizada | Não há programação identificável por atividade. Somar hectares de operações repetidas não calcula cobertura. |
| Relatórios | Cálculos no servidor, valores incompletos, estornos e exportação PDF/Excel | Consolidar manutenção/peças/mão de obra sem duplicar custos; consumo real de combustível depende de novos dados. |
| Sincronização | Fila por servidor/cliente/conta, ids estáveis, conflitos preservados; lease offline até 8h | Notificação com app fechado requer infraestrutura e configuração própria; sincronização periódica não é push. |

## Etapas de entrega

1. **Permissões e navegação**: isolar operações pelo autor; operador criar propriedade/talhão/máquina sem ganhar administração; retirar produtos e oficina do menu/painel do operador; retirar reserva de peças do gerente; indicadores separados. Testar endpoints diretos, outros funcionários/clientes, fila e interface.
2. **Tarefas e equipe**: organizar Serviços por funcionários, andamento/não conclusão justificada, resultado, anexos privados, implemento, disponibilidade e notificações individuais. Migração aditiva de eventos/destinatários e anexos; preservar estados antigos.
3. **Frota**: integrar metadados e fotos, implementos e perfil caminhão com odômetro independente. Migração aditiva, sem inferir km nem unir por nome.
4. **Combustível**: tanques, movimentos imutáveis, abertura/conferência/ajustes, abastecimento avulso com vínculo posterior e alertas. A mesma identidade de abastecimento só baixa o estoque uma vez. Migração: saldos antigos continuam no estoque sem tanque identificado até conferência; não inventar distribuição entre tanques.
5. **Operações e safra**: tempos, implemento, consumo efetivo separado do abastecimento, resultado parcial e programa de atividade por safra/talhão. Medir progresso sobre parcelas de programa identificadas; repetições só contam quando representam nova parcela. Não presumir cobertura única a partir de uma soma antiga de hectares.
6. **Relatórios e aparelhos reais**: consolidar categorias/origens, filtros e detalhamento, validação de cálculos, exportação e restauração; teste em celulares por Wi-Fi/dados móveis/Tailscale, offline e reenvio.

## Regras de preservação

- Novas permissões do operador não autorizam editar/arquivar cadastros existentes, alterar tarifas, conceder acesso ou administrar estoque. Gerente mantém essas ações. Seu novo cadastro de propriedade fica visível ao próprio autor e ao gerente; compartilhamento adicional cabe ao gerente.
- Função de gerente corresponde ao perfil admin já existente; não mudar o CHECK de usuários nem criar novo perfil sem migração coordenada.
- Esquemas anteriores mantêm checksum. Mudanças posteriores usam migrações novas, ensaio em cópia, integridade e foreign_key_check.
- Dados ausentes continuam nulos. Não calcular custo/ha sem área nem consumo real com litros abastecidos. Relatórios mostram escopo, origem e incompletude.
- Antes de atualizar os emuladores, salvar cópias privadas dos bancos e filas. Nenhum teste deve concluir tarefas, consumir estoque ou alterar custos do piloto em uso.

Este documento não declara os seis blocos concluídos. Os resultados de cada etapa devem ser registrados com testes e limitações.

## Entrega 2.1.4 — primeira etapa

Implementado e instalado nos emuladores gestor (16384), mecânico (16416) e operador (16480):

- Histórico e consulta direta de operações filtrados pelo autor para contas não administrativas, inclusive se seu vínculo de propriedade for mais amplo. Relatórios financeiros com autorização explícita de proprietário/gerente/consultor continuam preservados; essa autorização não abre o histórico operacional normal. O realizado de uma tarefa continua acessível ao destinatário da própria tarefa, inclusive quando confirmado pelo gerente.
- Operador pode criar cliente responsável, propriedade e talhão pela fila SQLite. A nova propriedade concede somente employee ao autor; o gerente a vê pela administração. Operador não compartilha com colegas, altera permissões, arquiva ou edita cadastros existentes. Clientes disponíveis são somente os vinculados a propriedades autorizadas ou criados pelo próprio operador.
- Operador pode criar máquina nas propriedades em que pode operar, **com conexão ao PC**. A tarifa fica a cargo do gerente. O formulário relacional continua sendo o cadastro básico de horas: não anuncia caminhão com quilômetros nem fotos como prontos.
- Navegação do operador: Tarefas, Operações, Máquinas e Propriedades. Produtos/insumos continuam selecionáveis na finalização; a área independente saiu do menu desse perfil. Painel de tarefas não mostra indicadores, aba ou ações da oficina.
- Serviços do gerente abre Funcionários, com Operadores e Mecânicos, trabalho em execução informado, quantidade de trabalhos abertos e atribuição direta ao funcionário selecionado. Ausência de andamento **não** é anunciada como disponibilidade confirmada. Ajuste manual de disponibilidade continua pendente.
- Indicadores do gerente distinguem tarefas agrícolas e manutenções atribuídas/abertas; preservam máquinas paradas, ordens em andamento e aguardando peças. A ação Reservar peças saiu da interface do gerente; reservas existentes, regras de estoque e diário não foram apagados.
- Corrigido atalho de Produtos e Insumos na área de cadastros que ainda tentava acessar uma antiga TabBar inexistente.

### Validação

- Análise estática sem apontamentos. Suíte geral do aplicativo: 106 testes aprovados e 1 integração inicialmente separada; a integração real foi executada depois e aprovada (107 testes distintos do aplicativo).
- Suíte geral do servidor: 77 testes aprovados; depois, 5 testes focados de perfis aprovados, incluindo um caso novo contra desvio pelos endpoints legados (78 casos distintos do servidor).
- Integração real: fila SQLite do operador → FastAPI temporária → propriedade/talhão com área ausente → máquina criada sem tarifa → leitura pelo gerente. As provas de operação, custo, estoque, oficina e reenvio já existentes também passaram. Nenhum desses testes usa o banco do piloto em uso.
- APK instalado sobre os três aplicativos, com a mesma assinatura. Bancos e todas as filas foram comparados imediatamente antes/depois da instalação e permaneceram idênticos; integridade SQLite e chaves estrangeiras válidas.
- Conferência visual em três perfis: nenhum erro de RenderFlex/RenderBox ou encerramento fatal nos processos conferidos. O formulário de propriedade do operador foi aberto e cancelado; não houve lançamento de consumo nem conclusão de tarefa.
- Banco do servidor comparado ao backup por conteúdo de todas as tabelas v2: nenhuma tabela de negócio alterada pela revisão. Não houve migração de esquema (permanece 8). Backup privado: `../backups/antes-perfis-2.1.4`; verificações `validacao-*.json` e `conferencia-final.json`.

### Pendências explícitas

Estados novos de tarefa/não conclusão e resultado parcial; anexos de tarefas; notificações locais/push; disponibilidade manual; vários talhões no mesmo formulário; metadados/fotos integrados de máquinas e implementos; uso rodoviário/odômetro; tanques e conferência por tanque; abastecimento independente e vinculação ao fechamento; consumo efetivo separado de volume abastecido; programação e cobertura única da safra; consolidação das novas categorias de custos e testes em celulares físicos. IA/n8n/GPS não integram esta atualização.

A próxima etapa funcional é Tarefas e equipe. Os emuladores foram devolvidos ao estado fechado; o servidor de teste pode executar o código atualizado na porta 8766. A versão 2.1.4 é uma entrega parcial da atualização geral, não uma declaração de prontidão comercial.
