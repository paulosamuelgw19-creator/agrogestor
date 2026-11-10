# Servidor de ativação do AgroGestor Local - Windows

Este servidor é independente da central comercial da edição conectada. Não altera planos, clientes ou regras daquele servidor. Usa Python, FastAPI, SQLite e cryptography. O painel fica no próprio Windows; o app usa somente `/activation/v1/*`.

## Primeiro uso no Windows

Abra PowerShell nesta pasta e execute:

```powershell
.\Iniciar-servidor.ps1 -Preparar
```

O script prepara um ambiente Python separado caso ainda não exista. Python 3.12+ precisa estar instalado e disponível pelo comando `py`. Escolha o nome do administrador e crie uma senha com pelo menos 8 caracteres; são aceitas senhas de 8 dígitos. Não existe usuário ou senha padrão. A senha recebe hash Argon2id. A chave emissora já preparada nesta entrega é protegida pelo DPAPI do usuário deste Windows; somente sua chave pública entra no APK.

Para as próximas ativações:

```powershell
.\Iniciar-servidor.ps1
```

Abra **http://127.0.0.1:8790/** neste Windows e entre com a conta criada. Encerre o servidor com **Ctrl+C**, aguardando o término. O aplicativo que já foi ativado continua funcionando offline. A porta 8790 pertence exclusivamente a esta nova central; os serviços antigos não são necessários.

Se a política do PowerShell impedir o script, abra as propriedades do arquivo recebido, confira a origem e use o procedimento permitido na sua organização. Não é necessário desativar a segurança do Windows para instalar o aplicativo.

## Códigos e troca de aparelho

No painel, informe a identificação do destinatário e clique em Gerar código exclusivo. O código completo aparece apenas nessa resposta. Copie e envie somente ao destinatário; a central guarda seu hash SHA-256, com entropia de 160 bits. Se perder um código disponível, cancele-o e gere outro. A listagem mostra somente os últimos quatro caracteres, a situação, a data e a instalação vinculada.

Para troca, selecione Nova autorização em um código utilizado. A central preserva o vínculo anterior e emite outro código para uma instalação própria. A licença anterior é permanente e offline: **o celular antigo não é desativado automaticamente**. Combine a retirada de uso antes da transferência.

## Endereço do celular e HTTPS

O endereço do painel no Windows **não é o endereço de ativação do produtor**. `127.0.0.1`, `localhost` e `10.0.2.2` não dão acesso remoto ao Windows a partir do celular do produtor. O produtor não deve digitar IP nem configurar VPN.

O endereço externo HTTPS ainda não foi fornecido nem implantado. O APK de MuMu usa apenas um loopback de depuração com encaminhamento ADB e fica em `../testes/apks-mumu`; ele não é o APK para enviar ao produtor.

Caminho de implantação preparado: um domínio controlado pelo administrador, DNS para um IP público alcançável, portas 80/443 encaminhadas para o Windows e Caddy no Windows fazendo TLS com certificado válido e proxy somente de `/activation/v1/*` para `127.0.0.1:8790`. O modelo está em `Caddyfile.example`. Sob CGNAT ou sem controle do roteador será necessário escolher um túnel com endereço estável ou uma hospedagem de entrada. Nada foi publicado automaticamente e o proxy ainda não foi instalado/testado externamente.

Depois de configurar e verificar o HTTPS em um celular externo, defina AGRO_LOCAL_PUBLIC_ORIGIN com a origem real e siga o [guia de compilação](../../README.md#compilar-apk-de-teste). O endereço fica fixo na compilação.

## Banco, chave e backup

`dados-privados/` contém `licencas.sqlite3`, seu WAL quando aberto e `issuer-key.dpapi`. A chave privada é cifrada pelo Windows e vinculada ao usuário; sua cópia bruta não basta para trocar de Windows ou recuperar um perfil perdido. Preserve a chave pública associada ao APK. Não gere uma chave diferente para tentar recuperar licenças antigas.

Crie um backup portátil cifrado, em local privado, antes de autorizar o produtor:

```powershell
.\.venv\Scripts\python.exe -m fontes.manage backup --file dados-privados\central-2026-11-04.agrolicensebackup
```

Crie uma senha de pelo menos 12 caracteres. O backup usa Scrypt e AES-256-GCM e inclui um snapshot consistente do SQLite e a chave emissora. Guarde a senha separadamente. Sem senha e sem a chave original não é possível recuperar a capacidade de emitir licenças compatíveis.

Para restaurar, **pare o servidor** e execute:

```powershell
.\.venv\Scripts\python.exe -m fontes.manage restore --file CAMINHO-DO-BACKUP.agrolicensebackup
```

Digite RESTAURAR e a senha do backup. O conteúdo é validado antes da substituição; uma pasta anterior é preservada. O emissor é protegido novamente pelo DPAPI do Windows de destino. Sessões administrativas e desafios antigos são descartados. Use o backup mais recente: restaurar um banco anterior a uma ativação pode fazê-lo esquecer códigos já consumidos; isso não revoga licenças offline antigas. Não reutilize códigos de snapshots antigos.

Em caso de perda da senha administrativa, o proprietário da conta Windows com acesso à pasta pode executar `python -m fontes.manage reset-password`. Esse procedimento é local e interativo, não é uma rota remota.

## Limites e privacidade

Não são enviados dados agrícolas. A central guarda destinatário administrativo, hash do código, situação, chave pública/fingerprint, datas, licença e auditoria administrativa. Limites de tentativa usam identificadores hash temporários, removidos após a janela de segurança. Não há IMEI, telefone ou localização. A limitação por IP usa o endereço de transporte durante a requisição; não existe rastreamento do produtor.

Há autenticação administrativa, sessão com cookie HttpOnly/SameSite, CSRF, checagem de origem/host, limite de corpo e de tentativas. O painel só aceita conexões locais. Logs de acesso estão desativados no script para evitar retenção desnecessária. Corpo, código completo, senha e assinatura não são registrados pelos handlers.

Não se promete proteção absoluta contra APK modificado, acesso root ou comprometimento do aparelho/Windows. O APK de teste ainda usa assinatura de depuração compatível com a base 2.1.7; uma distribuição comercial requer planejamento de chave de assinatura própria e sua preservação.
