# Etapa 5 — Ensaio de migração do Café Local

A ferramenta de inventário lê uma cópia do arquivo .agrobackup, verifica o SHA-256 do conteúdo e procura referências a anexos ausentes. Ela informa as quantidades por módulo, por tipo de cadastro e por tipo de anexo. Identificadores antigos de fazendas e talhões podem ser convertidos em UUIDs determinísticos para manter os vínculos.

## Ensaio executado

Usei a cópia do backup fictício TESTE-MuMu-nao-usar-como-dados-reais.agrobackup. O inventário identificou 1 fazenda, 3 talhões, 6 registros operacionais, 1 foto e 12 lançamentos de auditoria. Em um banco descartável, a API V2 aceitou a fazenda e os 3 talhões. Repeti a transferência e conferi os mesmos IDs e vínculos sem duplicação.

## Como repetir a leitura

No PowerShell, abra a pasta agrogestor-cafe-conectado e rode o comando com uma cópia privada do arquivo.

    .\.venv\Scripts\python.exe tool/migrar_cafe_local.py CAMINHO-DA-COPIA.agrobackup

## Pendências para migração real

O comando de inventário não grava no PC gestor. Falta validar a cópia do backup do produtor, mapear os seis módulos operacionais do exemplo e os módulos presentes no backup real, transferir fotos e PDFs, comparar saldos, históricos e anexos e testar em dois Android físicos. O ensaio de transferência foi limitado aos campos de fazenda e talhão suportados pela API V2. A edição local e o arquivo original foram preservados.

O ensaio final também sincronizou três registros operacionais (máquina com foto, serviço e abastecimento). Conferi os registros e a foto após a leitura pelo servidor. Repeti o envio sem duplicação. Os três itens restantes ficaram no inventário: implemento com foto, produto e consumo. O estoque V2 exige mapear saldos de abertura e baixas para evitar desconto duplicado. O serviço de teste descartável foi encerrado depois da conferência.
