# Etapa 2 — Recebimento físico

## Entrega verificada

O APK 2.1.7-cafe-conectado.3 está testado nos MuMu 0 e 2. O histórico preservou os 460 L de campo, os 120 L detalhados por pessoa e um recebimento confirmado de 440 L, com diferença de 20 L a menos. Ambos os aparelhos exibiram o mesmo recebimento. Para consultar a origem pela primeira vez, conecte ao PC gestor. A gravação pode aguardar na fila se a conexão cair durante o envio.

## Como funciona

1. Em Colheita, abra uma data e toque em **Registrar recebimento**. Exiba fazenda, talhão, safra e total de campo. O gestor informa a data do recebimento, o volume real em litros e, se quiser, uma observação.
2. Exiba a diferença em litros e permita registrar o recebimento mesmo quando ela for diferente de zero. Use a convenção **recebido − colhido** e mostre o valor original consultado de campo.
3. O servidor deve validar o vínculo, a permissão de gestor e o volume confirmado. A confirmação aceita deve produzir uma única entrada, mesmo em reenvio ou quando dois aparelhos forem usados. Exiba um estado pendente enquanto o PC gestor ainda não confirmou o envio.
4. Registre a versão da origem e o volume de campo consultado na confirmação. Mudanças posteriores na colheita precisam ficar visíveis para conferência. O volume físico já confirmado permanece no histórico.
5. O saldo de café recebido vem dos recebimentos confirmados. Na etapa seguinte ele servirá de origem para os lotes. Os lançamentos por pessoa continuam disponíveis na colheita com as quantidades originais.

## Primeiro teste de aceite

Lance 600 L no campo e confirme 580 L recebidos. A tela deve mostrar 20 L a menos. Reenvie a confirmação e sincronize o segundo aparelho. Confira uma entrada de 580 L, o histórico de campo de 600 L e os lançamentos por pessoa preservados. Em duas confirmações concorrentes, mantenha a versão aceita e mostre o conflito no aparelho que enviou a outra.


## Validação

- Análise dos arquivos Dart alterados sem ocorrências.
- Três testes da API passaram após a revisão de segurança. Incluem 600 L em campo e 580 L no recebimento, reenvio, origem desatualizada, conflito, perfis, isolamento e restauração.
- No MuMu, abra Colheita, escolha Fazenda Piloto Café A e Talhão Mundo Novo. Consulte Recebimento físico abaixo dos detalhes de 13/11/2026. O registro fictício existente deve aparecer como Sincronizado.
- O reenvio após erro transitório e a resolução de conflito foram revisados no código e na API. Essas duas ações ainda precisam de teste visual no Android. O piloto usa a configuração de renderização do MuMu documentada na etapa 1.
SHA-256 do APK de teste: 7C7B238A7A0B571B917F7A1070496C011EFD85671059291B4A5E10F357A36D05
