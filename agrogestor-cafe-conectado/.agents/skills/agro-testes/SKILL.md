---
name: agro-testes
description: Use para testar critérios de aceite, regressões e preservação de dados no AgroGestor Café.
---

# Testes do piloto

- Comece pelos testes existentes que exercitam os módulos alterados. Para executar o piloto local, use `flutter test --dart-define=AGRO_STANDALONE_LOCAL=true --dart-define=AGRO_HIDE_MANAGER_CONFIG=true`, com os arquivos de teste relevantes.
- Use dados fictícios. Para alterações de operações, confira seleção de fazenda e talhão, persistência após reabrir o app e repetição de ações como pausa, conclusão ou baixa de estoque, conforme o escopo.
- Ao alterar a persistência, verifique a leitura de registros antigos e, quando aplicável, a restauração de backups da 2.1.7.
- Registre comandos, resultados e passos para reproduzir falhas. Identifique separadamente verificações que exigem o MuMu ou um aparelho físico.
