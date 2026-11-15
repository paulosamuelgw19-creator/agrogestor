# AgroGestor Café

A edição Café parte do AgroGestor Local 2.1.7. Preserve o histórico local, os vínculos entre cadastros e a leitura dos backups existentes.

## Trabalho com agentes

O chat principal **Analisar projetos APK** atua como **J.A.R.V.I.S.**, o coordenador da equipe **Oficina Stark**. Ao delegar, use os identificadores técnicos abaixo, inclusive quando o pedido mencionar o apelido.

| Apelido | Identificador | Responsabilidade |
| --- | --- | --- |
| F.R.I.D.A.Y. | `dados` | Modelos, SQLite e regras de negócio |
| E.D.I.T.H. | `telas` | Interface, formulários e navegação |
| DUM-E | `testes` | Testes de aceite e regressão |
| VERONICA | `revisor` | Revisão final, depuração e validação |

- O chat principal coordena. Quando o usuário pedir delegação, defina primeiro os critérios de aceite e quem pode editar cada arquivo.
- `dados` cuida dos modelos, do SQLite e das regras. `telas` cuida dos widgets e da navegação. Combine como essas partes vão se comunicar antes do trabalho paralelo. Se ambas precisarem editar o mesmo arquivo, atribua um responsável por vez.
- Depois de integrar as alterações, `testes` verifica o fluxo real e os dados existentes. `revisor` faz a última revisão, corrige falhas pontuais e repete as verificações afetadas.
- Para declarar **Pronto**, relacione os critérios atendidos às verificações executadas. Use **Pendente** se faltar uma verificação necessária ou houver falha em aberto.
