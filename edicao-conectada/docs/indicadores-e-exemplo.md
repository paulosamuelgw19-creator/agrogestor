# Indicadores e exemplo — AgroGestor v2

Data de referência: 14/10/2026. Todo exemplo deste arquivo é **FICTÍCIO**, para validar apresentação e aritmética. Não foi obtido de uma propriedade real. O foco inicial é frota, insumos, consumo e operações; os indicadores econômicos da safra são uma expansão planejada.

## Catálogo de indicadores

As quantidades e valores precisam ter unidade, competência, origem e cobertura de informação. “Completo” significa completo entre os registros selecionados, não garantia de que o produtor informou todos os seus custos. Ausência de lançamento, valor desconhecido, zero confirmado e item não aplicável são estados diferentes.

| Indicador | Fórmula / unidade | Dados necessários | Dados incompletos / limites |
|---|---|---|---|
| Custo operacional registrado | Σ custos apropriados sem duplicação; R$ | Operações, consumo com custo histórico, usos de máquina, categorias e exclusões | Somar os conhecidos como subtotal. Uma linha sem custo impede chamar o resultado de total completo. No primeiro recorte cobre apenas máquina sem combustível/operador + insumos consumidos |
| Custo total de ciclo | Σ custos diretos + indiretos rateados + amortização definida; R$ | Base de apropriação, despesas, trabalho, máquina, insumos e regra de investimento | Não inferir custos não registrados, nem chamar subtotal de lucro. Escopo precisa declarar tributos, arrendamento, formação do cafezal e depreciação incluídos/excluídos |
| Custo por hectare cultivado | Custo do escopo / área cultivada única do ciclo; R$/ha | Valor completo do escopo, área histórica do ciclo | Área ausente/zero: não calculável. Área de passadas não substitui área cultivada. Em múltiplos ciclos, denominador é ha-ciclo e deve ser identificado |
| Custo por atividade/categoria | Σ custo apropriado por atividade/categoria; R$ e % do total equivalente | Tipo de operação, classificação e parcelas de rateio | “Não classificado” fica separado, sem distribuir por adivinhação. Não comparar porcentagem de subtotais com totais de escopos diferentes |
| Área trabalhada acumulada | Σ áreas das operações; ha de passadas | Área de cada passagem, operações e datas | Uma operação sem área torna o acumulado parcial. Aplicação e roçada no mesmo talhão contam duas passagens; isso não aumenta a área da propriedade |
| Horas de máquina | Σ(horímetro final − inicial); h | Máquina, operação, leituras, datas e validação de sequência | Final menor que inicial é inválido. Leitura ausente não vira zero. Intervalo não registrado é pendência, não trabalho presumido |
| Custo de máquina | Σ horas × taxa histórica + componentes externos não incluídos; R$ | Composição da taxa, combustível/manutenção/depreciação e alocação | No piloto a taxa informada é da máquina sem combustível e operador. Taxa desconhecida torna custo parcial. Combustível não pode entrar duas vezes |
| Rendimento operacional | Área trabalhada / horas; ha/h | Área e horas do mesmo conjunto de operações | Sem horas ou horas zero: não calculável. Comparar atividades e condições equivalentes; não inferir recomendação técnica |
| Consumo de insumo | Σ saídas por consumo − devoluções ligadas; kg/L/un | Insumo, unidade base, operação, quantidade, vínculo e estornos | Nunca somar L com kg ou unidades de produtos distintos. Conversão de produto/dose depende de dado explícito, sem recomendação agronômica automática |
| Consumo por hectare trabalhado | Quantidade de um insumo / área das operações correspondentes; unidade/ha de passagem | Consumos e áreas do mesmo escopo | Área faltante: parcial/não calculável. É descrição do registro, não dose indicada |
| Saldo físico | Inventário inicial confirmado + entradas + devoluções − consumos − saídas ± ajustes; unidade base | Movimentos completos do estoque por propriedade/local/insumo | Sem inventário inicial, saldo desconhecido; bloquear consumo até conferir o estoque. Não usar zero como saldo inicial presumido |
| Valor do estoque | Σ saldos valorizados por método escolhido; R$ | Custo histórico e custo médio móvel ou outro método definido | Recebimento sem custo permite saldo físico, mas valor e custo médio ficam pendentes; não excluir esse lote da média como se fosse gratuito |
| Produtividade | Produção líquida / área colhida correspondente; kg/ha ou t/ha | Produção bruta, perdas, forma/unidade e área colhida | Café cereja, em coco e beneficiado não são intercambiáveis. Sem forma/área/conversão: não calculável. Não usar área de operações repetidas |
| Perdas | Produção bruta − líquida; kg; ou perdas/bruta ×100; % | Mesma fase do produto, mensurações compatíveis | Ausência de perdas registradas não comprova perda zero. Umidade e beneficiamento podem exigir reconciliação específica |
| Custo por unidade produzida | Custo do ciclo / produção líquida da mesma fase; R$/kg ou R$/saca informada | Custo completo definido e produção líquida; peso de saca quando usado | Zero produzido não permite divisão. Sem custo/produção conhecidos, mostrar pendências. Não supor 60 kg/saca |
| Receita por competência | Σ valores de vendas reconhecidas no período − descontos/devoluções; R$ | Vendas, competência, produto/quantidade/preço, ajustes | Venda sem valor torna receita parcial. Não substituir receita por recebimento bancário |
| Resultado operacional registrado | Receita por competência − custos do mesmo escopo; R$ | Receita e custo comparáveis, qualidade e competência | Se qualquer componente estiver incompleto, resultado não calculável; mostrar subtotais conhecidos. Não chamar de lucro líquido |
| Lucro líquido | Receita − todos os custos, despesas e demais itens contábeis aplicáveis; R$ | Fechamento completo e política contábil, inclusive resultado financeiro/tributos | Exige escopo e fechamento que o piloto não oferece. Manter indisponível até implementação e validação apropriadas |
| Margem operacional | Resultado operacional / receita ×100; % | Mesma base do resultado e receita positiva | Receita zero/ausente ou resultado incompleto: não calculável. Não confundir com markup = resultado/custo |
| Fluxo de caixa líquido | Recebimentos − pagamentos nas datas de caixa; R$ | Pagamentos/recebimentos efetivos, financiamento e investimentos identificados | Diferente do resultado por competência. Lançamentos a receber/pagar não são movimentos efetuados |
| Planejado × realizado | Realizado − planejado; R$; variação/planejado ×100; % | Versão aprovada do plano e realizado de igual escopo | Plano zero: percentual indefinido, não infinito. Falta de orçamento não vira meta zero; real incompleto mantém comparação parcial |
| Comparação | Diferença absoluta e % entre períodos/ciclos equivalentes; unidade do indicador | Mesmas fórmulas, unidades, fase do café, área e cobertura | Base zero impede variação percentual. Agregar por soma e dividir pelos denominadores totais, não fazer média simples de taxas |
| Histórico e pendências | Lista cronológica, contagens por tipo/estado | Origem, responsável, versão, data, incompletudes, conflito e sincronização | Contagens de pendência não devem ocultar linhas sem valor; separar não enviado, rejeitado, conflito e informação faltante |

## Relatório A: operação e consumo — FICTÍCIO

Gerado em: 14/10/2026, 10:00, America/Sao_Paulo. Identificador ilustrativo: DEMO-OPERACIONAL-001.

Filtros: cliente “Produtor Exemplo”; propriedade “Sítio Exemplo”; talhão “Café 01”; ciclo “Café 2026”; cultura café; período 01/10/2026 a 14/10/2026. Área cultivada confirmada do ciclo: **10 ha**. Fonte: lançamentos fictícios abaixo. Moeda: BRL. Taxa histórica da máquina: R$120/h, **sem combustível e sem operador**.

### Origens dos saldos e custos

| ID | Movimento | Quantidade | Valor |
|---|---|---:|---:|
| EST-001 | Inventário inicial de diesel | 100 L | R$600,00 |
| EST-002 | Entrada de diesel | 50 L | R$330,00 |
| EST-003 | Inventário inicial de insumo foliar fictício | 10 L | R$500,00 |

Custo médio do diesel antes dos consumos: (600 + 330)/(100 + 50) = **R$6,20/L**. O produto foliar fictício vale R$50/L. As quantidades são registros de demonstração, não recomendações de aplicação.

| Operação | Tipo | Área da passagem | Máquina/horas | Consumo | Custo registrado |
|---|---|---:|---|---|---:|
| OP-001 | Aplicação registrada | 10 ha | Trator Exemplo, 100 → 103 h: 3 h | Diesel 30 L = R$186; foliar 2 L = R$100 | Máquina R$360 + insumos R$286 = **R$646** |
| OP-002 | Manejo/roçada | 10 ha | Trator Exemplo, 103 → 107 h: 4 h | Diesel 40 L = R$248 | Máquina R$480 + insumos R$248 = **R$728** |

### Resumo verificável

| Indicador | Valor | Origem/cálculo |
|---|---:|---|
| Operações | 2 | OP-001 e OP-002 |
| Horas de máquina | 7 h | 3 + 4 |
| Área de passadas | 20 ha de passadas | 10 + 10; a propriedade continua com 10 ha nesse ciclo |
| Custo de máquina | R$840,00 | 3×120 + 4×120 |
| Custo de insumos consumidos | R$534,00 | 186 + 100 + 248 |
| Custo operacional registrado | **R$1.374,00** | 646 + 728 |
| Custo registrado/ha cultivado | **R$137,40/ha** | 1.374 / 10 |
| Diesel consumido | 70 L | 30 + 40 |
| Saldo de diesel | 80 L, R$496,00 | 150 − 70; 930 − 434 |
| Saldo do foliar fictício | 8 L, R$400,00 | 10 − 2; 500 − 100 |
| Produtividade/custo por kg | Não disponível neste recorte | Produção comercial e área colhida não foram informadas |
| Receita, resultado e margem | Não disponíveis neste recorte | Não há venda e custo completo de safra |

Escopo: apenas custos conhecidos de máquina e insumos. Mão de obra, investimento/formação, juros, arrendamento, tributos e outros custos não estão incluídos. O valor não representa custo total do café nem lucro.

Gráficos propostos: barras OP-001 R$646 e OP-002 R$728; barras de categorias máquina R$840 e insumos R$534; histórico de horímetro; tabela de saldos por insumo. Cada barra abre seus IDs de origem.

Teste de incompletude: se a taxa da máquina for desconhecida, o relatório mostrará subtotal conhecido de R$534 dos insumos, custo total operacional **não calculável**, e OP-001/OP-002 como pendências de custo. Não apresentará R$534 como total completo.

## Relatório B: expansão financeira — FICTÍCIO E INDEPENDENTE DO A

Este segundo exemplo demonstra o catálogo futuro. Não será somado ao relatório A e não é funcionalidade concluída do primeiro recorte.

Propriedade Exemplo; ciclo Café Beneficiado 2026; área colhida 10 ha; período de competência 01/01/2026–31/12/2026. Os lançamentos representam um cenário simulado, declarado completo apenas para esta demonstração.

| ID | Registro fictício | Valor/quantidade |
|---|---|---:|
| C-01 | Insumos apropriados | R$45.000 |
| C-02 | Mão de obra apropriada | R$18.000 |
| C-03 | Frota apropriada, composição sem duplicar C-01/C-02 | R$18.000 |
| C-04 | Outros custos do escopo | R$9.000 |
| V-01 | Venda reconhecida por competência | R$120.000 |
| P-01 | Produção líquida de café beneficiado | 6.000 kg |
| CX-01 | Recebimento efetivo | R$80.000 |
| CX-02 | Pagamentos efetivos | R$70.000 |
| ORC-01 | Custo previsto aprovado | R$80.000 |

Custos: R$90.000; custo/ha: R$9.000; produtividade: 600 kg beneficiados/ha; custo por kg: R$15; resultado operacional registrado: R$30.000; margem: 25%; fluxo líquido de caixa: R$10.000; desvio do custo planejado: R$10.000, ou 12,5%. Lucro líquido permanece sem apuração contábil completa. O recebimento de R$80.000 não altera a receita reconhecida de R$120.000.

Não informar sacas sem conhecer o peso convencionado. Sem C-02, por exemplo, o subtotal conhecido seria R$72.000, mas custo total, resultado e margem ficariam pendentes; não virarão automaticamente R$72.000, R$48.000 e 40%.
