# AgroGestor 2.1.0 — tarefas e oficina

Entrega do piloto no PC gestor e no aplicativo Android. Mantém Flutter/Dart, FastAPI/Python e SQLite. IA e n8n ficam para uma entrega separada.

## Uso

- Gestor: **Visão geral → Tarefas** para atribuir serviço a operador, propriedade, talhão/safra, máquina e prazo. Pode informar área, horas, orçamento e vários insumos previstos.
- Operador: **Tarefas → abrir tarefa → Informar andamento**. Para concluir, use **Registrar o realizado** e salve a operação com os consumos efetivos. Marcar andamento não movimenta estoque.
- Oficina: operador relata ocorrência; gestor define mecânico, prioridade e prazo. O mecânico vê somente ordens atribuídas a ele e pode acrescentar descrições ao diário.
- Diário: análise, execução, espera de peças, testes e conclusão. Cada anotação mantém autor, data/hora, descrição, fotos, peças consumidas e horas informadas. A conclusão exige indicar expressamente se a máquina foi liberada.
- Reservas: gestor separa peças por ordem. Reserva reduz o disponível, mas não o saldo físico. A baixa ocorre somente no lançamento efetivo do mecânico; ao encerrar, reservas restantes são liberadas.
- Checklists: conferência antes/depois, pendências, observações e fotos. Um checklist não libera sozinho uma máquina.
- Painel: tarefas vencidas, ordens vencidas, máquinas paradas, espera de peças e estoque abaixo do mínimo disponível. Próxima revisão pode ser por data ou horímetro.
- Máquinas, Clientes e Relatórios passam a abrir os cadastros por propriedade quando o servidor confirma suporte à versão 2. O botão **Consultar registros anteriores** preserva o acesso às telas anteriores.

## Registro confiável

As alterações são salvas em SQLite no aparelho e sincronizadas com o PC gestor. Cada pedido tem identificador estável; reenvio do mesmo pedido não repete consumo, custo ou anotação. Fotos selecionadas são copiadas para pasta persistente antes de entrar na fila.

O acesso offline depende de login anterior, autorização em cache de até oito horas, validade da sessão e licença. Na retomada, o servidor confere novamente perfil, propriedade e atribuição. Trocar conta não disponibiliza a fila ou cache de outra conta.

Edição concorrente interrompe o envio e preserva o texto para **Conferir**. Essa ação apresenta o conteúdo salvo, verifica se já foi confirmado e só então reapresenta o pedido sobre a versão atual. O pedido original é preservado no histórico local. Formulários que não puderam entrar na fila ficam como rascunhos, sujeitos à renovação de acesso e conferência. Não há liberação automática por relatório ou checklist.

## Custos e limites

O custo registrado da operação soma máquinas e insumos efetivamente lançados. A tarifa horária da máquina exclui combustível, mão de obra e manutenção. Informar horas de mão de obra em uma operação não calcula automaticamente seu valor monetário.

A manutenção tem soma própria de peças consumidas, mão de obra com preço informado e outros serviços. Não é adicionada novamente à tarifa da máquina. Valores não informados permanecem ausentes; totais incompletos apresentam subtotal conhecido e indicação de valores faltantes.

O piloto ainda não oferece um demonstrativo financeiro completo que consolide manutenção, folha, receitas e despesas gerais por talhão. Rateio manual de uma operação entre vários talhões, migração dos lançamentos históricos sem propriedade e conciliação dos outros emuladores continuam pendentes. Não considerar essas funcionalidades prontas apenas porque há campos ou gráficos.

## Dados fictícios ampliados

A organização de demonstração está separada na porta **8766**. Os dados anteriores continuam no servidor original da porta **8765**, sem importação automática. Credenciais, banco do piloto, backups e imagens privadas não integram o repositório ou pacote de fontes.

Há três propriedades de demonstração, oito talhões/safras, sete máquinas, quinze produtos/insumos, doze operações de café/milho/soja, dez tarefas, seis ordens de oficina, onze anotações de andamento, cinco checklists e uma imagem ilustrativa identificada como fictícia. O [exemplo completo em JSON](exemplos/piloto-ficticio-2.1.0.json) inclui estoque, registros e relatórios calculados pelo servidor, sem credenciais. Quantidades, custos e prazos são exemplos de teste, sem recomendação agronômica.

Para testar:

1. Entre como gestor e confira os totais do painel e as tarefas pendentes.
2. Abra **Propriedades e Talhões** e confira a propriedade e os talhões compartilhados.
3. Entre como operador e abra **Aplicação de café para próximo teste — FICTÍCIA** para registrar o realizado. Confira a confirmação no gestor e a baixa única no estoque.
4. Entre como mecânico e abra **Troca de filtro e verificação de vazamento — FICTÍCIA**. Acrescente uma descrição de andamento e confira sua autoria e horário no gestor.
5. Confira a ordem com orçamento pendente: custo ausente não deve virar zero. Confira também a ordem concluída com peças e mão de obra.
6. Em **Operações → Produtos e insumos**, compare saldo físico, reservado e disponível. Em **Relatórios**, selecione propriedade e safra antes de gerar/exportar.

As contas de teste estão no arquivo privado `ACESSOS-TESTE.txt` ao lado da pasta do projeto. Não compartilhar esse arquivo junto com o código.

## Migração e validação

Migração aditiva 6: tarefas, ordens, anotações imutáveis, reservas, peças consumidas, checklists, limites de estoque e metadados de anexos. As cinco migrações anteriores mantêm suas definições e verificações. Não elimina nem reclassifica registros antigos.

Validação automatizada: 53 testes do servidor; 82 testes móveis locais e um teste adicional do cliente contra API real. Cobrem isolamento entre organizações e perfis, atribuição ao mecânico, consumo único, reservas concorrentes, rollback, custos desconhecidos, migração repetível, anexos privados, fila offline, texto preservado e reconhecimento de confirmação perdida. Análise estática sem erros.

Antes da atualização foram copiados o banco do piloto e o armazenamento completo dos dois aplicativos de teste. Integridade SQLite e vínculos foram conferidos. Os emuladores antigos com dados ainda não conciliados permanecem sem atualização.

Conferência nos dois MuMu: tarefa concluída por operação de 2 ha/2 kg de adubo, baixa única para 6 kg/R$ 60; anotação do mecânico salva com o piloto indisponível e recebida uma única vez após reconexão; filtros físicos 5 un, reservados 2 un e disponíveis 3 un. Os 16 registros anteriores do emulador principal continuam iguais. A abertura de operação pela tarefa e a leitura do diário durante atualização automática foram conferidas no APK final.
