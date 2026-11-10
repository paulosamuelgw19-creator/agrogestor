# Guia do administrador - AgroGestor Local 2.1.8

## Situação desta entrega

O servidor funciona no seu Windows. O painel local usa http://127.0.0.1:8790/. Nenhum domínio, acesso remoto HTTPS ou serviço público foi criado. O teste MuMu usa um encaminhamento ADB somente de depuração, não disponível no celular do produtor.

A edição 2.1.7 e seus fontes compactados foram preservados. A fonte local ativa agora é 2.1.8+2018. O pacote continua `com.campo.agrogestao.localpilot` e a assinatura de teste é compatível com a anterior. A edição conectada e a central de licenças comercial não foram alteradas.

## Preparar a conta e iniciar

Na pasta `servidor-licencas`, execute `Iniciar-servidor.ps1 -Preparar`. Escolha usuário e senha; não existe credencial padrão. Em uma instalação nova, a configuração cria a chave emissora e a protege com DPAPI. Para atualizar uma central existente, preserve o mesmo emissor. Nas próximas vezes, basta `Iniciar-servidor.ps1`. Mantenha a janela aberta enquanto combina uma ativação.

Entre no painel com a conta criada. As rotas administrativas aceitam somente acesso local; a configuração de HTTPS proposta publica apenas a ativação. Não abra a porta 8790 no roteador.

## Gerar e entregar um código

1. Informe uma identificação administrativa do destinatário. Evite dados pessoais desnecessários.
2. Clique em Gerar código exclusivo.
3. Copie o código no momento da geração. O valor completo não será recuperável depois: a central guarda somente o hash e os últimos quatro caracteres.
4. Quando o APK externo estiver pronto, envie ao produtor somente esse APK, seu código e o guia. Não envie a pasta do servidor, os testes ou o banco.
5. Combine um horário e deixe o servidor e o HTTPS ligados durante a ativação.

Um código disponível pode ser cancelado. Código utilizado não pode ser transferido para outra chave. Se a resposta se perder depois de emitida, a mesma instalação pode repetir a ativação e recuperar a licença original, sem consumir outro código.

## O que acontece no Android

Sem licença válida, a sessão antiga não libera os módulos: aparece Ativar AgroGestor Local. O produtor cola o código e toca em Ativar neste aparelho. O app gera sua chave no Android Keystore, assina um desafio temporário e recebe uma licença assinada pelo emissor. A licença é gravada atomicamente e verificada antes de liberar a sessão local.

Depois disso não há renovação, consulta periódica, vencimento ou dependência do PC gestor. A validação da assinatura e da chave acontece no próprio aparelho. A central não recebe o banco, as operações, o estoque ou as fotos. O app não solicita IMEI, telefone ou localização.

## Quando desligar

Depois que o produtor confirmar a ativação e conseguir abrir o aplicativo sem conexão, encerre o servidor com Ctrl+C. Se houver proxy HTTPS, ele também pode ser parado depois da janela de ativação. Isso não desativa instalações autorizadas.

## Atualizar sem perder autorização

Faça backup dos cadastros. Instale por cima um APK do mesmo pacote e com assinatura compatível, mantendo o mesmo emissor de confiança. Não desinstale nem limpe os dados. Atualização compatível preserva dados, fotos, licença e a chave da instalação.

A licença não depende do número da versão comercial: o formato assinado é validado por `schemaVersion=1` e pelo pacote, emissor e chave de instalação. Incrementar a versão do APK não cria uma nova instalação quando a atualização é compatível.

## Trocar de celular

1. No antigo, salve e confira o backup comercial `.agrobackup`.
2. No painel, use Nova autorização e registre a troca de aparelho.
3. No novo, instale o APK preparado e ative com o novo código.
4. Restaure o backup comercial. A licença e a chave do novo celular são mantidas.
5. Combine a retirada de uso do antigo. **Emitir outra licença não desativa a anterior offline.**

O backup comercial não contém a autorização nem a chave privada e não ativa outro aparelho. Se perder a chave da instalação ou reinstalar após apagar os dados, pode ser necessária uma nova autorização. Nenhum dado agrícola é apagado por falha de licença.

## Recuperar a central

Use `python -m fontes.manage backup --file CAMINHO.agrolicensebackup`, com o Python da `.venv`. Crie uma senha longa e guarde-a separadamente. O backup portátil é cifrado e contém banco e emissor, necessários para recuperar a capacidade de emitir licenças que o APK aceita.

Para restaurar, pare o servidor e use `python -m fontes.manage restore --file CAMINHO.agrolicensebackup`. O comando pede confirmação e senha, valida o arquivo e preserva a pasta anterior. Reprotege o emissor pelo DPAPI do Windows atual e elimina sessões e desafios do snapshot.

Use sempre a cópia mais recente e confira a lista de utilizados antes de retomar. Uma restauração antiga pode fazer a central esquecer ativações posteriores, permitindo reutilização indevida de códigos esquecidos pelo snapshot. Isso não revoga as licenças permanentes já emitidas. Não reutilize códigos antigos por causa de uma restauração.

Não copie somente o SQLite e não gere outro emissor para recuperar um APK existente. A chave privada não pode entrar no Git público, no APK ou no pacote do produtor. As pastas privadas estão excluídas do Git e com ACL restrita no Windows.

São três chaves diferentes: a emissora da licença, protegida no servidor; a chave de instalação, que permanece no Android Keystore e não é exportada pelo backup comercial; e a chave que assina o instalador APK. A assinatura de teste atual usa o keystore de desenvolvimento do proprietário em `%USERPROFILE%\.android\debug.keystore`. Preserve esse arquivo de compilação separadamente e de forma privada, sem colocá-lo nos ZIPs públicos. Ele não é recuperado pelo backup da central. Perder a chave de assinatura do APK pode impedir uma atualização por cima, mesmo que o emissor das licenças tenha sido recuperado. Planeje a assinatura comercial antes de ampliar a distribuição.

## Pendência de HTTPS para o produtor

Ainda falta escolher/configurar um endereço público estável. O caminho documentado é Caddy no Windows com um domínio seu, certificado público válido e proxy apenas da ativação. Exige DNS e conectividade de entrada; sob CGNAT será necessário outro caminho de entrada estável. O modelo `Caddyfile.example` não está implantado.

Depois de validar o HTTPS fora da rede local, siga o [guia de compilação](../../README.md#compilar-apk-de-teste).

Consulte TESTES-E-PENDENCIAS.md para distinguir os testes executados dos cenários ainda não conferidos.
