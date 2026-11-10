# AgroGestor

Aplicativo Flutter para gestão agrícola, com duas edições e servidores separados.

| Edição | Aplicativo | Servidores |
| --- | --- | --- |
| Local 2.1.8 | [Android para uso offline](edicao-local/fonte-local/) | [Central de ativação única para Windows](edicao-local/licenciamento/servidor-licencas/) |
| Conectada 2.1.6 | [Piloto com sincronização](edicao-conectada/) | [PC gestor](edicao-conectada/server/) e [central de licenças e contratos](edicao-conectada/central_license/). [Firebase](edicao-conectada/functions/) é uma alternativa de licenciamento dessa edição. |

Veja como [compilar e testar a edição Local](edicao-local/README.md) e como [configurar a edição Conectada](edicao-conectada/README.md). Cada edição usa seu próprio fluxo de ativação.

O repositório contém código-fonte e exemplos de configuração. A ativação da edição Local em um celular externo ainda depende da configuração e da validação do HTTPS.
