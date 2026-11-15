---
name: agro-dados
description: Use ao alterar modelos, regras de operação, persistência SQLite ou backup local no AgroGestor Café.
---

# Dados e regras

- Trace o caminho do formulário até o repositório e verifique como os registros da 2.1.7 são lidos e restaurados.
- Preserve os IDs que ligam fazenda, talhão e operação. Trate valores ausentes como desconhecidos e mantenha a leitura dos formatos antigos.
- Para operações em etapas, valide a transição de estado e grave as alterações relacionadas na mesma transação. Confira o comportamento ao repetir uma ação e ao reabrir o app.
- Documente para o agente de telas os campos aceitos, erros de validação e estados retornados.
