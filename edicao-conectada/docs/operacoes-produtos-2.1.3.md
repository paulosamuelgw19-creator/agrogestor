# AgroGestor 2.1.3 — Operações separadas de Produtos e Insumos

## Organização

- **Operações:** histórico do trabalho realizado e finalização de operações. As abas de produtos, frota, cadastros, relatórios e abastecimento foram retiradas dessa área.
- **Produtos e insumos:** cadastro único, categorias, consulta do estoque e entradas/correções autorizadas. Não possui formulário separado de consumo.
- Frota, cadastros, relatórios e abastecimentos continuam disponíveis pelas suas próprias entradas. Culturas e safras continuam acessíveis a partir da propriedade.
- O operador tem atalhos distintos para **Operações** e **Produtos** na navegação inferior.

## Finalização

1. O operador abre a tarefa e escolhe **Finalizar operação**, ou acessa a área Operações para finalizar um trabalho avulso.
2. Confere propriedade, talhão/safra, data e máquinas utilizadas.
3. Registra os horímetros reais. Quando a tarefa já tem uma máquina atribuída, ela aparece selecionada; o horímetro final permanece em branco para preenchimento.
4. Em **Insumos utilizados nesta operação**, adiciona cada produto e a quantidade realmente consumida, na unidade do cadastro. Pode informar vários insumos.
5. Informa o abastecimento do dia, se houver, nas opções de estoque da propriedade ou compra em posto já existentes.
6. Seleciona **Finalizar e salvar**. A finalização fica na fila local quando necessário; o PC gestor confirma a operação, os custos e a movimentação de estoque em uma transação.

As quantidades previstas na tarefa não são copiadas como consumo realizado. Quantidades/custos ausentes não são preenchidos artificialmente. O custo do insumo continua calculado pelo estoque; a interface não pede ao operador que invente preços.

Cancelar o formulário não cria operação nem consumo. A repetição do envio mantém o identificador e as proteções existentes contra duplicação. A tarefa apresenta a finalização pendente enquanto aguarda confirmação/conferência, evitando oferecer novamente a finalização como se nada tivesse sido salvo.

O cadastro anterior de produtos continua disponível em instalações antigas, com seu histórico preservado para consulta. O botão/formulário de utilização avulsa foi removido. Nenhum registro anterior de utilização foi apagado. Peças de manutenção continuam no fluxo próprio da oficina.

## Dados e validação

Não há mudança de esquema nem migração de dados nesta versão. Permanecem Flutter/Dart, FastAPI e SQLite. As regras de autorização, limites offline e cálculo de estoque continuam no servidor e nos repositórios existentes.

Foram acrescentados testes que verificam:

- Operações e Produtos como telas independentes, sem abas misturadas.
- Dois insumos com unidades diferentes, quantidades reais e vínculo à tarefa/máquina.
- Horímetro final não preenchido com horas previstas.
- Cancelamento sem criação de consumo nem modificação do catálogo.
- Histórico anterior sem botão de utilização avulsa.
- Finalização pendente visível na tarefa, sem alterar o retrato confirmado.

A validação inclui a suíte geral do aplicativo e integração com uma API FastAPI real usando banco temporário e dados fictícios. Os testes não lançam consumos nos dados do piloto em uso.

Backup anterior à atualização: pasta privada `backups/antes-separar-operacoes-2.1.3`, fora do Git. Instalação do APK sobre o aplicativo existente, sem desinstalação ou limpeza de dados. Os emuladores antigos não fazem parte da atualização.

Resultado: análise estática sem apontamentos; 102 testes da suíte geral aprovados e o teste de integração real, inicialmente separado da suíte, aprovado em seguida. Os três testes de formulários de propriedades também passaram na execução de integração. Conferência manual das telas de Operações, Produtos e Insumos e finalização nos dois emuladores de teste, sem erros de layout nos processos conferidos.

Após a instalação, os 16 registros anteriores do aparelho gestor permaneceram idênticos; o aparelho operador não tinha registros na coleção antiga. Também foram comparadas as tabelas de operações, estoque, abastecimentos, diário de manutenção, tarefas, ordens, propriedades, talhões, máquinas e insumos do piloto: nenhum lançamento foi alterado pelos testes manuais. O formulário aberto na conferência foi cancelado. O emulador de operador foi fechado novamente após a atualização, mantendo o estado anterior de uso.
