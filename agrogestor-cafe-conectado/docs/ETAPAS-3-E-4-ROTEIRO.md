# Etapas 3 e 4 — Beneficiamento e vendas

## Roteiro de teste

1. No MuMu do piloto, use o PC gestor A na porta 8865. Entre com a conta de gestor fictícia.
2. Abra Colheita, escolha Fazenda Piloto Café A e Talhão Mundo Novo e toque em Beneficiamento.
3. Abra LOTE-PILOTO-01. Confira a origem no recebimento e compare o saldo em kg com o histórico de limpas e vendas.
4. Em uma nova venda de teste, informe o peso e o preço total. Após sincronizar, abra Registrar pagamento da venda e informe só a parcela recebida. Confira o saldo a receber.
5. Use Sincronizar agora e compare o lote nos dois aparelhos. A fila exibe gravações pendentes e eventuais conflitos.

## Verificações

Na API, 440 L foram divididos em 300 e 140 L, e a alocação extra foi recusada. A limpeza rendeu 70 kg, 40 kg foram vendidos e 30 kg ficaram disponíveis. Uma venda fictícia de R$ 1.000 recebeu R$ 350 e ficou com R$ 650 em aberto. A API bloqueou excesso, duplicação e acesso de perfis e organizações diferentes. A revisão também cobriu concorrência, edição desatualizada e a rejeição de pagamento acima do saldo.

No MuMu o APK final mostrou o lote de 300 L com 70 kg beneficiados, 40 kg vendidos, saldo de 30 kg, R$ 350 recebidos e R$ 650 a receber. Isolamento, concorrência e rejeição do excesso foram validados na API. Expiração de sessão, descarte de pagamento recusado pela interface e uso em Android físico com HTTPS continuam pendentes.
SHA-256 do APK: 3947AF03578A01FC7F33FD9123954C78718A31DB102A2DA5770B0732C380E2B0
