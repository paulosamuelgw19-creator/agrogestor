# AgroGestor Café Conectado

A edição conectada parte do Café Local 2.1.7-cafe.9 para manter a navegação por fazenda e talhão. A Central, o painel de contratos e o PC gestor vieram do código de referência da Conectada 2.1.6+2015. O projeto usa Flutter e SQLite no Android, FastAPI e SQLite no PC gestor e na Central.

## Diagnóstico e escopo

| Componente | Base encontrada | Decisão do piloto |
| --- | --- | --- |
| Aplicativo Café | A edição local usa uma identidade do gestor no aparelho. O SQLite e parte da fila de sincronização coexistem no código. Os módulos Café estavam restritos ao modo local. | Instalação Android separada `com.campo.agrogestao.cafe.conectado`, com conta de PC gestor. Habilitar cada módulo quando o servidor validar suas regras. |
| PC gestor | Autenticação e contas por organização, aparelhos, rotas V2 de propriedades/talhões, eventos com cursor e licença. O banco legado tem uma organização por instância. | Uma instância por cliente, com banco e credenciais próprios. Dois bancos fictícios no piloto. |
| Central | Painel administrativo, licenças, contratos por cliente, limites, revisão contratual e troca por chave da organização. | A Central recebe dados comerciais e contagens. O PC gestor armazena registros de campo. |
| Caderno de campo | O SQLite local já registra notas e pendências com IDs de fazenda e talhão. | Primeiro módulo conectado. Sincronização pelo PC gestor com autenticação, licença, versão por registro, fila e autorização de gestor. |
| Outros módulos Café | Colheita, acertos, aplicações, estoque, financeiro, beneficiamento e análises têm regras locais e anexos específicos. | Cada etapa precisa de validação equivalente no PC gestor, escrita atômica, reenvio idempotente e testes de backup. A versão Café Local continua disponível para esses fluxos. |

Os gestores autenticados podem consultar e gravar no Caderno conforme a licença e o contrato. Operador e mecânico têm seus perfis de base. O acesso deles ao Caderno exige uma futura regra de autorização por propriedade. A migração dos registros Café existentes é uma etapa própria e deverá preservar os IDs e as relações de origem.

## Iniciar o piloto Windows

Abra o PowerShell na pasta `agrogestor-cafe-conectado`. Prepare um ambiente de Python 3.11 ou superior. Execute a instalação de dependências e o preparo uma vez.

```powershell
python -m venv .venv
& .\.venv\Scripts\python.exe -m pip install -r server/requirements.txt -r central_license/requirements.txt
& .\.venv\Scripts\python.exe tool/piloto_conectado.py preparar
```

Em terminais separados, dentro da mesma pasta, execute:

```powershell
& .\.venv\Scripts\python.exe tool/piloto_conectado.py iniciar central
& .\.venv\Scripts\python.exe tool/piloto_conectado.py iniciar pc-a
& .\.venv\Scripts\python.exe tool/piloto_conectado.py iniciar pc-b
```

- Central e painel em [127.0.0.1:8870](http://127.0.0.1:8870/).
- PC gestor A na porta 8865. PC gestor B na porta 8866.
- Usuário do painel, e-mails e senhas fictícias ficam em `piloto-local/credenciais.json`. Guarde esse arquivo na área privada do PC. O Git ignora todo o diretório `piloto-local`.
- O PC gestor e a Central escutam no próprio Windows. Para emulador compatível com o alias do host use `http://10.0.2.2:8865`. No MuMu, o comando abaixo encaminha o localhost do aparelho para o PC. Repita por emulador. Em aparelhos físicos, configure HTTPS em rede privada antes de usar dados reais.

```powershell
adb -s SERIAL reverse tcp:8865 tcp:8865
adb -s SERIAL reverse tcp:8866 tcp:8866
```

No MuMu com esse encaminhamento, use `http://127.0.0.1:8865` para o cliente A ou `http://127.0.0.1:8866` para o cliente B. Faça login com o e-mail e a senha do cliente correspondente. A Central usa um login administrativo próprio. Cadastre a fazenda e o talhão e abra **Caderno do talhão**. Em dois emuladores no cliente A, crie uma nota em um e atualize o Caderno no outro.

A conexão inicial exige PC gestor acessível. Após a autenticação, o aplicativo usa o cache da sessão e da licença. A janela offline da licença é limitada a sete dias desde a validação e termina antes se a licença vencer. A sessão e o catálogo em cache também precisam estar dentro de seus prazos. O contrato, a sessão e a permissão do perfil voltam a ser conferidos pelo servidor na reconexão. O aplicativo conserva os registros pendentes. Consulte **Sincronização** para ver envios recusados ou conflitos e tente novamente quando a condição for resolvida.

Uma revogação invalida a sessão do aparelho no PC gestor. O mesmo identificador não volta a entrar com senha. Uma instalação com novo identificador segue a quota de aparelhos e a política da conta. Um aparelho desconectado recebe a revogação quando volta a falar com o servidor.

## Validação do piloto

- A Central cadastrou dois clientes fictícios, com licença ativa e limite de três aparelhos em cada contrato. Os PCs gestores autenticaram as contas e consultaram o plano de cada cliente.
- No MuMu 2, uma nota foi salva com o encaminhamento para o PC gestor removido. Após restabelecer a conexão, a nota chegou ao PC gestor A e apareceu no MuMu 0. O registro permaneceu único e ficou fora do banco do cliente B.
- Os testes de servidor cobriram as permissões de gestor, operador e mecânico, bloqueio de anexos do Caderno, isolamento, reenvio, conflito de edição, licença vencida e revogação de aparelhos. Foram 110 testes do PC gestor e 17 da Central.
- Foram executadas 36 regressões no modo Café Local da cópia e 10 testes de concorrência SQLite e catálogo offline na edição conectada. O teste de concorrência usa duas conexões ao mesmo banco.
- Uma cópia isolada em memória do SQLite do piloto preservou a fazenda, o talhão e a nota. A verificação do SQLite retornou integridade OK.
- O teste em dois Android físicos e a migração dos módulos Café para o PC gestor continuam pendentes.

## Backup e migração

- No Café Local, abra **Dados neste aparelho → Salvar backup** e guarde uma cópia em local privado. Registre os totais de estoque, produção, saldos e a quantidade de cadastros e anexos.
- Para proteger o piloto, pare os serviços e copie as pastas `piloto-local/central`, `piloto-local/pc-a` e `piloto-local/pc-b` junto da configuração privada, preservando a correspondência entre elas. Teste a restauração em uma pasta separada antes de depender dela.
- A importação de um backup completo do Café Local para o PC gestor ainda depende da implementação dos módulos Café. Mantenha o backup original e a edição Café Local como referência dos dados do produtor.
- Uma futura migração deverá importar uma cópia, mapear os IDs de catálogo e dos lançamentos, reconciliar estoque, produção e saldos e conferir os anexos antes de liberar dados reais.

### Roteiro da migração futura

1. Escolha o cliente de destino e registre qual arquivo foi copiado, a versão e o SHA-256.
2. Restaure o backup em um Android isolado com o Café Local e confira se o arquivo abre com fotos e PDFs.
3. No PC gestor de teste, importe primeiro propriedades e talhões, depois pessoas, produtos, frota e lançamentos. Mantenha uma relação entre IDs de origem e destino e apresente colisões para revisão.
4. Compare quantidades de cadastros e anexos, estoque por produto e unidade, litros colhidos, quilos beneficiados e saldos em centavos. Um teste de reenvio precisa manter os mesmos totais.
5. Abra amostras de históricos e anexos no segundo aparelho. Com os totais conferidos, faça novo backup antes de qualquer migração real.

Esses passos orientam a próxima etapa. A edição atual ainda não tem importador completo para executá-los no PC gestor.

## Referências

As duas cópias ficam em `AgroGestor Cafe - Referencias e Resultado`.

| APK de referência | SHA-256 |
| --- | --- |
| Café Local 2.1.7-cafe.9 | `CCE25E09F4508C8565094DBDF0868FBC15165737E7410B087F5E5E0FC9CF94F1` |
| Conectada 2.1.6 Contratos | `8F1FA5C22FE933FDFC2271B47382B4B9D48205DC1ADBF580FAC24866B445E525` |

## Versão .5

- [Resumo da entrega](docs/ENTREGA-5-CONTRATOS-E-MIGRACAO.md)
- [Guia do piloto](docs/GUIA-DO-PILOTO.md)
- [Ponto de retomada](docs/PONTO-DE-RETOMADA.md)
- [Anotações de campo](docs/ANOTACOES-DE-CAMPO.md)

O APK de teste e seu SHA-256 ficam na release. Para compilar em outro computador, instale Flutter e o SDK Android e execute `flutter pub get` e `flutter build apk --debug` na pasta deste projeto. O script Gradle offline pressupõe uma cópia local de `compilacao-maven`; a compilação online usa a configuração padrão do Android.

O ambiente de teste usa três serviços (Central e dois PCs Gestor) com os comandos do guia. O código dos PCs Gestor é o mesmo e cada instância usa seu próprio banco.
