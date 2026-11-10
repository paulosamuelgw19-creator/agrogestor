# AgroGestor

> Esta cópia contém o piloto **2.1.6+2015**, com [contratações personalizadas e controle de uso](docs/contratos-personalizados-2.1.6.md). Consulte [Gestão, fazendas, relatórios e validação](docs/gestao-relatorios-2.1.5.md). Os registros existentes foram preservados. IA e n8n continuam reservados para uma entrega separada.

Aplicativo Flutter para gestão de máquinas, serviços e manutenção agrícola, com armazenamento local e sincronização privada por fazenda.

## Arquitetura encontrada

Antes desta implementação, o app era Flutter/Dart, iniciado em `lib/main.dart`. As telas e repositórios ficam em `lib/features/`; máquinas, serviços, manutenção, combustível, operadores, implementos, clientes e produtos eram salvos como listas JSON em `SharedPreferences`. Não havia servidor de fazenda nem sincronização.

O app agora mantém os registros de uma conta de fazenda em SQLite no aparelho e grava alterações em uma fila local (`sync_outbox`). As fotos de máquinas ficam numa pasta persistente do app e são enviadas como anexos. A tela **Sincronização** mostra a fila, a última comunicação, erros e conflitos, e oferece reenvio manual. A tentativa automática ocorre ao abrir ou retomar o app, ao recuperar a conectividade e por tarefa periódica do Android; o sistema operacional pode adiar tarefas em segundo plano.

O PC gestor executa uma API Python/FastAPI e um SQLite local com uma fazenda. Para acesso remoto, a API escuta apenas em `127.0.0.1`; Tailscale Serve publica a conexão HTTPS somente na rede privada. O cliente não acessa o arquivo SQLite remoto diretamente.

## Ordem de implantação

1. Concluir e configurar primeiro o app móvel: cadastros locais, fila de sincronização, indicação de pendências e revisão de conflitos.
2. Depois, preparar as credenciais e a conexão privada da fazenda.
3. Por último, instalar e configurar o PC gestor para receber e sincronizar os dados.

O código do app já preserva os cadastros offline depois que o usuário entrou na fazenda ao menos uma vez. A primeira entrada ainda exige conexão com o PC gestor para validar a conta e associar o aparelho. A instalação e configuração do PC gestor são a última etapa do processo; as instruções dessa etapa estão mais abaixo para uso quando o app móvel estiver pronto.

## Limitações e decisões

- O primeiro login precisa alcançar o PC gestor. Depois que o usuário autentica, os cadastros podem ser criados offline e aguardam na fila até a conexão retornar.
- O PC inicia o teste de 30 dias na primeira ativação de aparelho. O servidor permite aparelhos ativos sem limite de quantidade e o administrador pode revogar a sessão de um aparelho. O app permite gravações offline enquanto o teste/licença está válido e a última validação tem menos de sete dias.
- Quando o teste termina, os dados sincronizados continuam disponíveis para consulta; alterações novas ficam bloqueadas no app e na API.
- Há dois backends centrais alternativos para licenças: Firebase (mantido) ou serviço Windows auto-hospedado (`central_license/`). Cada servidor de fazenda aponta para um deles por configuração privada; não configure ambos no mesmo servidor ao mesmo tempo. O painel central lista fazendas e controla licenças, sem consultar registros operacionais nem senhas. O gestor continua administrando usuários e aparelhos dentro da própria fazenda.
- O modo de sincronização com fazenda está disponível no aplicativo Android. A demonstração local continua disponível em desenvolvimento e usa as preferências locais antigas.
- Dados antigos em `SharedPreferences` continuam guardados no aparelho. O administrador pode importá-los pela tela **Sincronização** depois da primeira sincronização, se a fazenda estiver vazia; o app mantém a cópia antiga e bloqueia a importação para fazendas que já tenham registros.
- O celular precisa participar da mesma rede Tailscale que o PC. A VPN e a API são camadas separadas: a API valida login, fazenda e perfil em toda operação.
- O PC precisa ficar ligado e conectado à internet para ser o ponto de sincronização. Enquanto estiver desligado, o app conserva os dados no celular.
- A sincronização é por registro. Se duas pessoas alterarem o mesmo registro antes de sincronizar, o app mantém ambas as versões e pede que alguém escolha qual fica.
- Agora há foto de máquina como anexo. Outros tipos de anexos ainda não são usados pelos formulários existentes.

### Perfis e módulos

O app e a API usam a mesma matriz de acesso. A API valida o perfil em cada envio e filtra os módulos recebidos; no aparelho, os repositórios também ocultam módulos fora do perfil ativo.

| Perfil | Módulos disponíveis |
| --- | --- |
| Administrador | Máquinas, serviços, manutenção, combustível, operadores, implementos, clientes e produtos |
| Operador | Máquinas, serviços, implementos, combustível, produtos e consumo |
| Mecânico | Máquinas e manutenção |

Convites e gestão de aparelhos/licenças são exclusivos do administrador. Os perfis não substituem a autenticação: cada pessoa entra com a própria conta.

### Área de clima

Removida do aplicativo a pedido do usuário.

### Gestão de contas

Na tela **Sincronização**, administradores podem consultar as contas da fazenda e bloquear ou reativar cada conta. A API confere a função administrativa no servidor, impede bloquear o último administrador ativo e verifica se a conta continua ativa em cada solicitação autenticada. Assim, um bloqueio também invalida tokens já emitidos. O usuário bloqueado não pode liberar a própria conta; um administrador ativo deve reativá-la.

O primeiro administrador é criado pelo assistente `server/run.ps1` (ou pelo comando `python -m agrogestor_server.cli init-admin`) com senha digitada de forma oculta; não há credenciais padrão no código. Novos usuários entram por convites do administrador, e definem sua própria senha, com pelo menos 12 caracteres.

## Executar o app

Requisitos: Flutter compatível com o SDK declarado em `pubspec.yaml`, Android SDK e Java 17.

No PowerShell, na pasta do projeto:

```powershell
flutter pub get
flutter analyze
flutter run -d <ID_DO_DISPOSITIVO>
```

Na versão de desenvolvimento, os perfis de demonstração podem ser abertos pelos botões da tela de login. Eles não usam senha, não criam contas de fazenda e não sincronizam; o login real sempre exige conexão com o PC gestor configurado.

## Instalar o servidor no PC gestor

Para testar a edição Conectada em uma cópia nova no Windows, execute `Iniciar-piloto.cmd` na raiz desta edição. O iniciador habilita a API v2, usa a porta `8766` e exige um banco separado em `server/data-piloto`. Na primeira execução, ele cria a configuração local e pede o cadastro do administrador. Use uma cópia separada se já tiver um `server/.env` para outra instalação.

Cada PC gestor deve ter uma pasta de dados própria para uma única fazenda. Não copie `server/data` para um repositório ou serviço público; essa pasta contém os dados operacionais e hashes de senha. Requisitos: Windows PowerShell, Python 3.11 ou superior e Tailscale instalado no PC e nos celulares autorizados.

1. Abra PowerShell na pasta `server` deste projeto.
2. Execute `Set-ExecutionPolicy -Scope Process Bypass` se o Windows bloquear scripts nesta sessão.
3. Inicie `./run.ps1`. Na primeira execução, o script cria `.venv`, instala as dependências e cria `.env` com uma chave JWT local; depois pede nome da fazenda, e-mail, nome e senha do primeiro administrador. Nas próximas inicializações, ele só confere o hash de `requirements.txt` e instala novamente se a lista mudar. A senha não é gravada no código.
4. Mantenha a janela aberta enquanto a API estiver em uso. A API ficará em `127.0.0.1:8765`.
5. No painel do Tailscale, habilite MagicDNS/HTTPS, atribua a tag privada do exemplo ao PC e configure uma regra de acesso que permita somente celulares autorizados à porta TCP `8443`. O arquivo `server/tailnet-grants.example.json` é um modelo incompleto para adaptação à política real do tailnet.
6. No PC, publique a API com o proxy HTTPS privado do Tailscale:

   ```powershell
   tailscale serve --https=8443 http://127.0.0.1:8765
   tailscale serve status
   ```

7. Confira o nome HTTPS MagicDNS completo do PC no painel do Tailscale. Na tela **Sincronização** do app, informe `https://<nome-magicdns-do-pc>:8443`. Use o nome real apresentado pelo seu tailnet; os nomes do projeto são apenas exemplos.
8. No celular, entre no mesmo tailnet pelo app Tailscale, confirme que a política permite a conexão e faça o primeiro login AgroGestor usando a conta administradora.
9. Na tela **Sincronização**, o administrador pode gerar convites para operadores e mecânicos. Envie cada código em canal privado; o convidado define sua senha no próprio app.

O servidor bloqueia iniciar fora de `127.0.0.1` pelo script. Não configure redirecionamento de portas no roteador nem regras de firewall para expor a API. O celular alcança a URL HTTPS pelo Tailscale Serve; as permissões de rede devem liberar somente a porta configurada.

### Configuração de uma fazenda

Uma instalação limpa do servidor cria o identificador da fazenda e a primeira conta administradora. Convide cada pessoa pelo app; cada usuário tem uma conta, um perfil e o mesmo `farmId` atribuído no servidor. Para uma nova fazenda, use outra instalação e outra pasta `AGROGESTOR_DATA_DIR`. Não reutilize a base de uma fazenda diferente.

Os valores editáveis ficam em `server/.env.example`; o script cria `.env`, que é ignorado pelo Git. `AGROGESTOR_JWT_SECRET` é gerado localmente no primeiro início. Não compartilhe a chave, senhas, tokens, ou o banco `server/data/agrogestor.sqlite3`. O app não contém credenciais reais.

O primeiro administrador consegue consultar e liberar aparelhos na tela **Sincronização**. Se nenhum aparelho administrador ainda puder entrar, pare o servidor e use os comandos locais abaixo:

```powershell
.\.venv\Scripts\python.exe -m agrogestor_server.cli devices
.\.venv\Scripts\python.exe -m agrogestor_server.cli revoke-device <ID_DO_APARELHO>
```

O modo Firebase continua disponível: o esqueleto está em `functions/`, `public/`, `firebase.json` e `firestore.rules`; o painel fica no Firebase Hosting, os metadados ficam no Firestore, e as operações passam por Cloud Functions com uma lista privada de e-mails permitidos. A implantação de Cloud Functions exige vincular faturamento ao projeto Firebase (plano Blaze); o custo depende do uso.

### Alternativa: painel central no Windows

O painel Windows é independente do Firebase e guarda somente cadastro/contato das fazendas, situação da licença e eventos administrativos. Ele não acessa o banco de operações de nenhuma fazenda. O administrador é criado na primeira execução, sem usuário ou senha padrão.

1. Mantenha o Firebase como está. Para executar o painel Windows, abra PowerShell em `central_license` e rode `Set-ExecutionPolicy -Scope Process Bypass` caso o Windows bloqueie scripts; depois execute `./run.ps1`. Instale Python 3.11 ou superior se solicitado. Na primeira execução, o script cria ambiente, chaves privadas e pede um usuário e uma senha com pelo menos 14 caracteres.
2. Mantenha essa janela aberta. O painel local ficará em `http://127.0.0.1:8770`. Para entrar remotamente pelo tailnet, em outro PowerShell execute `tailscale serve --https=8444 http://127.0.0.1:8770` e consulte `tailscale serve status`. Não use Funnel nem redirecione portas do roteador.
3. Copie a chave compartilhada gerada para `central_license/.env` (`AGROGESTOR_LICENSE_SERVER_API_KEY`) de forma privada para o arquivo `.env` de cada PC gestor da fazenda. Essa chave autentica servidores; não é senha do painel nem chave do app.
4. Configure cada PC gestor na pasta `server` com `./configure-license.ps1`. Escolha Windows e informe a URL privada e a chave de servidor copiada de `central_license/.env`; o script salva os valores sem exibir a chave. Exemplo de configuração resultante:

   ```dotenv
   AGROGESTOR_LICENSE_PROVIDER=windows
   AGROGESTOR_LICENSE_API_BASE=https://NOME-PRIVADO-DO-PC:8444
   AGROGESTOR_LICENSE_API_KEY=CHAVE_PRIVADA_SALVA_PELO_SCRIPT
   ```

   Use o endereço Tailscale real do PC central. Reinicie o servidor da fazenda. Se estiver no mesmo Windows, `AGROGESTOR_LICENSE_API_BASE=http://127.0.0.1:8770` também funciona.
5. Quando a fazenda acessar o servidor, ela aparecerá no painel Windows pelo ID da fazenda. O painel permite liberar/renovar um período depois de confirmar o pagamento e suspender o acesso a novos registros por inadimplência. A suspensão chega na próxima validação online; enquanto offline, vale a última validação permitida por até sete dias.

Para continuar usando Firebase em uma fazenda, execute `./configure-license.ps1` e escolha Firebase. O painel Firebase e os dados já existentes não são removidos pela opção Windows. Cada instalação de fazenda escolhe apenas um provedor por vez.

No modo Windows, ativação/renovação de períodos é manual: confirme o pagamento e clique em liberar/renovar. Nenhum gateway de pagamento foi conectado. Planos criados no painel são de 30, 90 ou 365 dias, ou vitalícios; a data de validade e as ações ficam no SQLite central em `central_license/data`. Faça backup dessa pasta e do `.env` do painel.

Etapas que precisam da conta Firebase:

1. Escolha/crie um projeto Firebase e use um acesso com permissão para configurar Authentication, Firestore, Functions, Hosting e faturamento. No Console, crie o banco Cloud Firestore padrão na região `us-central1`, habilite o provedor e-mail/senha no Firebase Authentication e confirme o e-mail do responsável pelo painel. Consulte os guias oficiais de [início do Firestore](https://firebase.google.com/docs/firestore/quickstart) e [login com e-mail e senha](https://firebase.google.com/docs/auth/web/password-auth) antes de configurar o projeto.
2. Instale Node.js 22 com npm. O projeto fixa Node.js 22 para as Cloud Functions, runtime ainda suportado e com mais tempo de vida que o Node.js 20, cuja desativação está prevista para 30/10/2026. Na raiz do projeto, instale o Firebase CLI e autentique a conta que tem acesso ao projeto:

   ```powershell
   npm install -g firebase-tools
   firebase --version
   firebase login
   firebase use --add
   ```

   Se o Windows deste computador não tiver npm disponível, instale Node.js primeiro ou use o binário standalone oficial. A implantação exige o plano Blaze. Consulte a [documentação oficial da CLI](https://firebase.google.com/docs/cli) e o [guia de implantação de Cloud Functions](https://firebase.google.com/docs/functions/get-started). A configuração local `.firebaserc` é ignorada pelo Git.
3. Na raiz do projeto, configure o e-mail permitido para administrar licenças:

   ```powershell
   firebase functions:secrets:set LICENSE_ADMIN_EMAILS
   ```

   Informe apenas o e-mail verificado do responsável. O segredo fica no Secret Manager do Firebase.
4. Copie `public/firebase-config.example.json` para `public/firebase-config.json` e preencha `apiKey`, `authDomain`, `projectId` e `appId` exibidos na configuração do app Web Firebase. Esses campos identificam o projeto no cliente Web; a autorização real do painel continua na Cloud Function.
5. Gere uma chave de servidor aleatória com `py -3 -c "import secrets; print(secrets.token_urlsafe(48))"`. Guarde-a em um gerenciador de senhas e configure-a como segredo Firebase:

   ```powershell
   firebase functions:secrets:set LICENSE_SERVER_API_KEY
   ```

   Use a mesma chave no campo `AGROGESTOR_LICENSE_API_KEY` do `server/.env` de cada PC gestor. Os endpoints HTTP de ativação e consulta recusam chamadas sem essa chave; ela não deve ficar no app móvel, no código ou no Git.
6. No `server/.env` de cada PC gestor, configure `AGROGESTOR_LICENSE_PROVIDER=firebase`, `AGROGESTOR_LICENSE_API_BASE` para `https://us-central1-SEU_PROJECT_ID.cloudfunctions.net` (ajuste a região se alterar a região em `functions/index.js`) e `AGROGESTOR_LICENSE_API_KEY` com a chave compartilhada acima.
7. Na raiz do projeto, instale as dependências e publique as regras, funções e painel:

   ```powershell
   npm install --prefix functions
   firebase deploy --only firestore:rules,functions,hosting
   ```

8. Abra o endereço Hosting do projeto, entre com a conta permitida e emita uma chave somente depois de confirmar a venda. A chave aparece uma vez. No app, o administrador cola a chave em **Sincronização → Ativar licença**. O painel central lista, revoga e transfere licenças; uma transferência usa o `ID da fazenda` exibido na tela de sincronização.

As Functions verificam o e-mail verificado contra `LICENSE_ADMIN_EMAILS`; as regras negam leitura direta do Firestore. Os endpoints de ativação e trial também exigem `LICENSE_SERVER_API_KEY`, compartilhada com os PCs gestores via arquivo `.env`. O código bruto da licença não é armazenado, apenas seu hash. Nenhuma chave de conta de serviço deve ser baixada para o app, para o PC gestor, ou colocada no Git. A ativação no PC consulta a Cloud Function e mantém a última validação por até sete dias sem internet.

Antes de publicar, o fluxo central de licenças pode ser exercitado localmente sem conta Firebase ou credenciais reais:

```powershell
node --test functions/test/license-functions.test.cjs
```

Esse teste simula Firestore em memória e cobre autorização do painel, emissão com hash, ativação única por fazenda, transferência entre fazendas, revogação auditada inclusive antes da ativação, falha de infraestrutura e trial de 30 dias. Também confirma que ativações e consultas de trial sem a chave do servidor recebem `401`. Ele verifica a lógica de negócio; a implantação ainda precisa ser validada no projeto Firebase real.

### Backup e restauração

Faça backup regular em disco externo ou local separado, protegido por senha do Windows. Para manter banco e fotos consistentes, pare o servidor e execute na pasta `server`:

```powershell
.\.venv\Scripts\python.exe -m agrogestor_server.cli backup C:\Backups\AgroGestor-2026-10-08
```

Restaure somente com o servidor parado. O comando substitui os dados da fazenda configurada nesta instalação, então confira a pasta de destino antes:

```powershell
.\.venv\Scripts\python.exe -m agrogestor_server.cli restore C:\Backups\AgroGestor-2026-10-08
```

Guarde uma cópia separada do arquivo `server/.env`, especialmente a chave JWT. Ao restaurar, use a configuração original do PC gestor e confirme acesso HTTPS pelo tailnet antes de liberar o app.

### Verificar o contrato da API

Os testes usam um banco temporário e contas fictícias; não acessam uma fazenda configurada nem o Firebase. No PowerShell, execute na pasta `server`:

```powershell
py -3 -m venv .venv-test
.\.venv-test\Scripts\python.exe -m pip install -r requirements-test.txt
.\.venv-test\Scripts\python.exe -m unittest discover -s tests -v
```

Eles cobrem autenticação, limite de aparelhos, perfis, reenvio idempotente, conflitos de versão, anexos, expiração, janela offline de sete dias, backup/restauração e o envio da chave privada nas chamadas de licença do PC gestor.

## Contrato de sincronização

A API implementa login e convites, `POST /api/v1/sync/push`, `GET /api/v1/sync/pull`, e envio/consulta autenticados de `PUT`/`GET /api/v1/attachments/{id}`. Os IDs de evento tornam reenvios idempotentes; a versão base detecta alteração concorrente; exclusões são sincronizadas como tombstones. O servidor responde por evento com confirmação, conflito ou rejeição. O controle de leitura e escrita dos perfis também é aplicado na API.

O banco do PC contém apenas uma fazenda. O `farmId` vem da identidade configurada no próprio servidor e o servidor ignora IDs de fazenda enviados pelo celular. Senhas são armazenadas com Argon2; tokens têm prazo de expiração e são guardados no armazenamento seguro do Android. O banco e as fotos permanecem no disco do PC gestor.

## Estrutura principal

- `lib/features/sync/`: SQLite móvel, fila durável, cliente HTTP, anexos, estado e tela de sincronização.
- `lib/features/auth/`: login remoto, sessão local e convites.
- `lib/features/*/*_repository.dart`: gravação local dos cadastros no novo armazenamento.
- `server/agrogestor_server/`: API privada, autenticação, permissões, sincronização e comandos de backup.
- `server/run.ps1`: instalação e execução local do servidor.
- `server/configure-license.ps1`: escolhe com segurança o provedor de licença de uma fazenda (Firebase, Windows ou local).
- `lib/features/licensing/`: estado da licença no aparelho, regra offline de sete dias e bloqueio central de gravações após a expiração.
- `functions/index.js` e `public/`: painel e API centrais Firebase para listar fazendas, emitir, suspender, renovar, revogar e transferir licenças (aguardam configuração/publicação no Firebase).
- `central_license/`: painel auto-hospedado no Windows, com sua própria base central e autenticação administrativa; opção de 30/90/365 dias ou vitalícia, renovação, suspensão, revogação e emissão de chaves.
- `test/`: testes de modelos, prazos de licença, perfis, fila SQLite (incluindo reabertura, eventos em voo, atualização da versão-base após confirmação e preservação de erros visíveis) e validação da importação de cadastros antigos.
- `server/tests/`: contrato da API, permissões, tentativas idempotentes, anexos, licença offline e backup/restauração em banco temporário.
- `functions/test/`: fluxo central de licenças contra um Firestore simulado, sem dependências de conta externa.

## Referências técnicas

- [FastAPI: JWT e hashing de senha](https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/)
- [Tailscale Serve: proxy HTTPS privado](https://tailscale.com/docs/reference/tailscale-cli/serve)
- [Tailscale grants: controle de acesso](https://tailscale.com/docs/features/access-control/grants)
- [SQLite no Python: backup online](https://docs.python.org/3/library/sqlite3.html#sqlite3.Connection.backup)


## Correções de segurança — 14/10/2026 (1.0.1+2002)

- O salvamento compara a edição com a lista original da tela. Registros recebidos depois são preservados; alterações concorrentes no mesmo registro exigem atualização antes de gravar.
- Estoque, consumo, serviço e atualização da máquina são confirmados em uma transação local no modo de fazenda com SQLite. O modo legado de demonstração usa preferências e não oferece a mesma garantia entre módulos. A sincronização remota continua resolvendo conflitos por registro.
- A validade offline de uma licença paga termina no vencimento conhecido ou no fim da tolerância, o que ocorrer primeiro. O app também bloqueia gravação ao detectar retrocesso significativo em relação à última validação salva.
- A central Windows não renova licença ao repetir a ativação. Renovação, revogação e transferência exigem conta administrativa; a chave dos PCs gestores dá acesso somente aos endpoints de consulta/ativação.
- Revogar um aparelho invalida suas sessões anteriores mesmo se ele entrar novamente depois. A atualização adiciona automaticamente `token_version` ao banco de dispositivos na inicialização do servidor; não exige apagar dados.
- Os dois servidores limitam tentativas de senha por conta: até oito em cinco minutos, com reinício do contador após sucesso. O limite é por processo, tem armazenamento limitado em memória e não substitui as restrições de rede privada.
- As fotos sincronizadas são imutáveis por identificador; uma foto nova recebe outro ID. O cache do app separa anexos por fazenda.
- Cada sincronização conserva o endereço e o token de origem. Alterar o servidor configurado encerra a sessão atual, e redirecionamentos HTTP autenticados não são seguidos.

### Assinatura e compilação

`flutter build apk --debug` continua disponível para testes. Builds `release` exigem `android/key.properties` com uma chave de distribuição própria. Use `android/key.properties.example` como referência. Chaves e senhas não devem entrar no código ou ser compartilhadas. A configuração de release não usa mais automaticamente a chave debug.

Antes de trocar a assinatura de um app já instalado, prepare a migração/preservação dos dados. Os APKs anteriores usam certificado Android Debug; uma chave de distribuição diferente não permite simplesmente substituí-los por atualização normal.

### Verificações locais

Na raiz do projeto, com as dependências correspondentes instaladas:

```powershell
flutter test --no-pub
dart analyze lib test
.\server\.venv\Scripts\python.exe -m unittest discover -s server/tests -q
.\server\.venv\Scripts\python.exe -m unittest discover -s central_license/tests -q
node --test functions/test/license-functions.test.cjs
```

Os testes do servidor e da central usam bancos temporários. `central_license/requirements-test.txt` declara as dependências de teste da central para quem usar um ambiente separado. Os testes Firebase simulam o Firestore e não validam uma implantação real.

As correções dos servidores entram em execução ao reiniciar os serviços existentes; as funções Firebase precisam ser implantadas separadamente para atualizar uma instalação remota. Os dados e as configurações privados existentes foram mantidos.
