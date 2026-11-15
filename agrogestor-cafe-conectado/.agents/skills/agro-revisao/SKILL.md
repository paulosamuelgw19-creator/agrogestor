---
name: agro-revisao
description: Use na revisão final de uma entrega integrada do AgroGestor Café, incluindo depuração e verificação dos critérios de aceite.
---

# Revisão final

- Revise o diff integrado contra os critérios de aceite e siga o fluxo desde a tela até os dados persistidos. Priorize perda de dados, alterações duplicadas e regressões de navegação.
- Reproduza cada falha relevante. Corrija ajustes pontuais e envie ao coordenador os passos de reprodução de problemas estruturais.
- Após os ajustes, rode `flutter analyze` e repita os testes afetados. Quando a entrega exigir validação no Android, inclua o resultado observado no MuMu ou no aparelho.
- Entregue **Pronto** quando todos os critérios estiverem verificados. Em **Pendente**, indique a falha ou verificação que falta e como reproduzir.
