# AgroGestor 2.1.1 — abastecimento na operação do dia

O operador pode registrar abastecimento junto com a operação real, inclusive ao concluir uma tarefa. Na janela **Registrar operação**, use **Adicionar abastecimento** antes de salvar.

Informe máquina, origem do combustível, litros, horímetro e local/posto, se conhecido. A data é a mesma da operação; a conta autenticada registra automaticamente o responsável. O abastecimento é opcional: nos dias em que não ocorreu, não adicione uma linha nem informe litros zero.

## Duas formas

- **Estoque da propriedade:** selecione diesel, gasolina ou etanol cadastrado em litros. O PC verifica saldo e reservas, baixa o estoque e calcula o custo médio. Não repita estes litros no campo de insumos consumidos. O custo já aparece nos insumos da operação e não é somado novamente.
- **Compra em posto:** informe o combustível e, se souber, o preço por litro. Valor = litros × preço por litro, arredondado para centavos. A compra não baixa o estoque da propriedade. Se o preço não foi informado, o valor fica ausente e o relatório indica informação incompleta.

Litros abastecidos não são uma medição dos litros queimados pela máquina durante o trabalho. O valor do abastecimento fica associado à operação como custo registrado, sem afirmar consumo real ou eficiência do motor. A tarifa de máquina continua excluindo combustível, mão de obra e manutenção.

Quando houver horas de máquina na operação, o horímetro do abastecimento precisa estar entre o inicial e o final. Sem apontamento de horas, usa-se o horímetro confirmado da máquina; abastecer sozinho não cria horas trabalhadas. O servidor valida propriedade, máquina, perfil, estoque e manutenção antes de confirmar.

## Histórico e relatório

Os abastecimentos aparecem no detalhamento da operação e da tarefa concluída. A aba **Abastecimentos**, dentro de **Operações**, reúne os registros confirmados da propriedade, com data, máquina, combustível, litros, horímetro, origem e responsável. No gestor, **Combustível** abre essa área; **Consultar registros anteriores** mantém acesso ao módulo antigo.

Os relatórios por safra/período e suas exportações PDF/Excel incluem litros abastecidos, valores e registros de origem. Custos de abastecimento do estoque são uma referência já incluída nos insumos; somente a compra em posto é adicionada à soma por fora. O gráfico separa máquinas, insumos incluindo combustível do estoque e compras em posto, sem repetir o mesmo valor.

Não há exclusão isolada que apague o histórico. O gestor pode estornar a operação pelas regras existentes: o estoque é recomposto, o abastecimento permanece identificado no registro estornado e deixa de entrar nos relatórios ativos.

## Persistência e atualização

Operação, abastecimentos, horas, baixa de estoque e conclusão da tarefa são confirmados numa única transação. Se houver erro, nenhuma dessas partes é confirmada sozinha. Reenvio do mesmo pedido não cria outro abastecimento nem outra baixa. O aparelho mantém a fila SQLite até receber a confirmação do PC; continuam valendo login anterior, autorização offline de até oito horas e licença válida.

A migração aditiva 7 cria somente a tabela de abastecimentos e seu índice. Não converte registros antigos de combustível em novos abastecimentos, não altera lançamentos anteriores e aceita os pedidos antigos que não possuem esse campo.

Validação: 59 testes do servidor e 87 testes móveis, incluindo o cliente com fila SQLite contra a API real. Cobertura de duas origens, preço ausente, saldo insuficiente, permissões, horímetros, duplicidade, rateio exato dos centavos entre máquinas, estorno e compatibilidade com pedidos antigos. Análise estática sem problemas. Backups anteriores à atualização mantidos fora do repositório.

Conferência no MuMu: operador concluiu uma tarefa de café com 2 ha, 2 kg de adubo e abastecimento de 10 L do estoque. O PC recebeu um único abastecimento de R$ 62 e baixou o diesel de 1.500 para 1.490 L. Um segundo exemplo de posto tem 5 L a R$ 6,25, total R$ 31,25, sem nova baixa do tanque. Todos são fictícios. Os 16 registros anteriores do emulador principal continuam iguais. [Exemplo com registros e relatório](exemplos/abastecimento-ficticio-2.1.1.json).

Ao salvar o realizado de uma tarefa, o aplicativo retorna à lista. Enquanto há um realizado na fila, a tarefa indica confirmação pendente e não oferece uma segunda conclusão. A fila impede atomicamente dois envios simultâneos da mesma tarefa.
