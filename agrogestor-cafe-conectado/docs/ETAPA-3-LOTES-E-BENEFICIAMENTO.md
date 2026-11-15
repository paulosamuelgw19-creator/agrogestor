# Etapa 3 — Lotes e Beneficiamento

O último APK validado é o 2.1.7-cafe-conectado.3, com Recebimento Físico testado em dois MuMu. A etapa de lotes começou pela análise dos componentes existentes.

## Ponto de retomada

O Café Local já tem formulário de lote, medições e limpeza. As entradas locais consultam litros da colheita e controlam o volume alocado. A edição conectada precisa usar recebimentos confirmados como origem e fazer a conferência da capacidade no servidor, dentro da transação, inclusive quando dois gestores alocarem o mesmo recebimento.

- Definir o contrato de lote conectado com entradas vinculadas pelo ID do recebimento, volume atribuído e vínculos de fazenda, talhão e safra preservados.
- Permitir dividir o volume de um recebimento entre lotes e combinar recebimentos da mesma fazenda e safra. Registrar cada origem para consulta futura.
- Gravar o beneficiamento com data e quantidade limpa em kg, ou em sacas com peso informado. Preservar origem e medições anteriores. O saldo para venda parte do peso líquido produzido.
- Testar reenvio, conflito de edição, lotes concorrentes que tentam exceder o mesmo volume, isolamento e preservação dos dados locais. Usar somente dados fictícios no piloto.

## Teste de aceite proposto

Do recebimento fictício de 440 L, atribua 300 L a um lote e 140 L a outro. Tente atribuir 1 L adicional em outro aparelho e confirme a recusa. Registre a limpeza com 1 saca de 60 kg e 10 kg avulsos, confirme 70 kg no histórico e confira a origem no segundo aparelho.

As etapas 4 e 5 permanecem na sequência. A primeira registra venda por lote e recebimento financeiro. A segunda importa uma cópia do backup e compara cadastros, anexos e totais antes de testar com dados reais.

## Contrato para implementação

Reaproveitar CoffeeLot e o módulo coffeeProcessingLots. Adicionar receiptId às entradas conectadas. O PC gestor confere cada origem e a soma alocada por recibo na mesma transação da gravação do lote. Usar código único por fazenda e safra, versionamento por registro e chave de reenvio. Preservar o histórico de medições e limpezas. Depois da primeira limpeza, congelar as origens e os volumes atribuídos. Até a etapa de vendas, o saldo em kg corresponde ao peso limpo registrado. A implementação e a compilação da etapa 3 ainda estão pendentes.
