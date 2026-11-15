# Etapa 0 - Segurança e manutenção do Café Conectado

Use o APK 2.1.7-cafe-conectado.5 para repetir os testes. Esta etapa documenta a manutenção dos servidores e a restauração.

## Testar

1. Abra os servidores pelos atalhos do piloto. A Central usa 8870 e os PCs gestores A e B usam 8865 e 8866.
2. No MuMu, configure o encaminhamento ADB descrito no Guia do Piloto. Entre como gestor do cliente A em dois emuladores.
3. Abra Propriedades, selecione a fazenda de teste e abra o Caderno do talhão. Desconecte um emulador, salve uma nota de teste, reconecte e sincronize. No segundo, confira a nota. No cliente B, confira que a nota ficou fora do seu cadastro.
4. Para restaurar, use sempre uma pasta nova e mantenha a recuperação separada do servidor ativo. Antes de trocar um banco usado pelos aparelhos, planeje a conferência dos cursores e das filas pendentes.

## Backup e compactação

Abra o PowerShell na pasta agrogestor-cafe-conectado. Os comandos aceitam central, pc-a ou pc-b. Use destinos novos. Guarde os ZIPs junto da configuração privada correspondente, fora da pasta pública e do Git. Os ZIPs têm verificação de integridade por SHA-256 e contêm dados privados em formato sem criptografia.

```powershell
& .\.venv\Scripts\python.exe tool/manutencao_servidor.py backup pc-a .\piloto-local\pc-a-backup.zip
& .\.venv\Scripts\python.exe tool/manutencao_servidor.py restaurar pc-a .\piloto-local\pc-a-backup.zip .\piloto-local\pc-a-copia
```

Com o serviço correspondente parado, a compactação primeiro cria e verifica um ZIP e depois executa VACUUM no SQLite. O SQLite precisa de espaço temporário para reconstruir o arquivo.

```powershell
& .\.venv\Scripts\python.exe tool/manutencao_servidor.py compactar pc-a .\piloto-local\pc-a-pre-compactacao.zip
```

A queda de tamanho depende do volume de páginas livres e do conteúdo. Fotos já comprimidas costumam ocupar tamanho parecido no ZIP. A ferramenta preserva registros, histórico de sincronização e anexos referenciados.

## Antes de produção

Valide HTTPS em Android físico, restauração coordenada com filas e caches existentes e limites de armazenamento para anexos. O piloto exige chave por organização para licença; preserve a política estrita e as chaves próprias na configuração de produção. A etapa de Colheita Conectada permanece separada.
