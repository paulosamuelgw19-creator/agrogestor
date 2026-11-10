# AgroGestor 2.0.0 — homologação

> Registro histórico. Para configurar o piloto atual, siga o README da edição Conectada. Os APKs, relatórios gerados e iniciador da entrega antiga ficam fora deste repositório.

Entrega de 14/10/2026: frota, insumos, consumo, talhões e operações. **IA e n8n ficam em trabalho separado.** Esta entrega não conclui todo o plano de expansão financeira/agronômica.

## Arquivos

- `APK/AgroGestor-2.0.0-2003-HOMOLOGACAO-universal.apk`: aplicativo Android 2.0.0+2003.
- raiz do repositório: fontes do app, servidor operacional e central de licenças preservada.
- `Iniciar-piloto.cmd`: inicia uma instalação de servidor isolada, na porta 8766, usando `server/data-piloto`.
- `docs/exemplos/Relatorio-FICTICIO.pdf` e `.xlsx`: arquivos gerados pelo mesmo código do app, somente com dados fictícios.
- `validacao-v2.md`: evidências, limites e pendências.

O APK é **debug/de homologação**, não uma distribuição definitiva com chave própria. O certificado é igual ao APK debug 1.0.1+2002 da pasta de correções. Pacote `com.campo.agrogestao`, Android 7/API 24+, ARM 32/64 bits e x86_64, aproximadamente 188 MiB.

Como o pacote é o mesmo, pode atualizar o app de teste anterior. Preserve um backup antes de testar em aparelho com dados. Não desinstale o app para contornar erro de assinatura. Nenhum Android estava conectado: não houve instalação ou validação física nesta entrega.

## Uso

Abra **Operações e insumos**, também disponível no botão Operações da barra inferior.

1. Administrador: cadastre cliente → propriedade → talhão → cultura → safra/ciclo. Cadastre máquinas e insumos.
2. Vincule a máquina à propriedade e confira o inventário inicial de cada insumo nela. Ausências e valores antigos padrão não são saldos conferidos.
3. Conceda acesso às contas em Permissões da propriedade. O vínculo define proprietário, gerente, funcionário ou consultor.
4. Registre a operação com data, ciclo/talhão, área, máquinas/horímetros, insumos e observações. O autor é a conta autenticada.
5. Confira a fila. Um lançamento pendente não altera estoque ou custo confirmado. O PC verifica novamente acesso, saldo e horímetro ao receber.
6. Gere o relatório por safra/ciclo e período. Propriedade e ciclo identificam talhão e cultura. Abra as operações de origem e salve PDF ou Excel.

Cadastros, entradas, ajustes e estornos exigem conexão. Operações podem ser salvas offline após carregar a propriedade online, com autorização de até 8 horas, limitada também pelo vencimento da sessão/licença. O servidor revalida o acesso antes de confirmar cada envio.

Conflitos não são sobrescritos automaticamente. Confira a mensagem na fila, tente o mesmo pedido novamente ou consulte o servidor e retire-o da fila para refazer, quando necessário. Um UUID já confirmado não consome duas vezes. Falha de estoque/horímetro cancela toda a gravação.

## Histórico anterior e permissões

**Com v2 habilitado, somente o administrador mantém acesso aos dados e módulos v1.** Contas não administrativas usam as propriedades autorizadas na nova área. As rotas antigas de sincronização e anexos são bloqueadas para elas, inclusive após revogar o último vínculo, evitando contornar o isolamento por propriedade.

O administrador mantém o histórico e os módulos anteriores de manutenção, abastecimento e serviços. A reformulação desses módulos por propriedade e a migração completa do histórico ainda são pendências. Confira o impacto nos perfis antigos de mecânico/operador antes de substituir a operação diária. O servidor da pasta original não foi alterado ou substituído.

## Servidor de teste

Use um aparelho de teste e uma instalação isolada. `Iniciar-piloto.cmd` exige Python 3.11+ e instala dependências num ambiente desta cópia. Na primeira execução, cria configuração e chave próprias e pede o cadastro do administrador. Mantenha `.env` e senhas privados.

O servidor escuta em `127.0.0.1:8766`. Para acesso pelo telefone, encaminhe **esse serviço de teste** para um endereço HTTPS da rede privada e configure o endereço no app. Não substitua o encaminhamento do servidor em uso. O Tailscale/encaminhamento HTTPS do PC não foi alterado nesta entrega; a API não deve ficar exposta diretamente à internet.

O iniciador só aceita dados em `./data-piloto`, v2 ligado e porta 8766. O `.env.example` mantém v2 desligado por padrão. Não compartilhe banco ou ambiente Python com a instalação atual.

## Ensaio da migração

Faça backup consistente do banco/anexos com o serviço parado e guarde configurações/segredos de forma protegida. Restaure numa **cópia isolada** da mesma organização antes de importar. Uma base criada do zero terá outra organização e não aceitará o plano da organização anterior.

A partir de `server`:

```text
python -m agrogestor_server.v2_import plan --source-db CAMINHO_DO_BANCO_COPIADO --output plano-importacao.json
python -m agrogestor_server.v2_import apply --plan plano-importacao.json --server URL_HTTPS_DO_PILOTO
```

A aplicação solicita token temporário do administrador sem gravá-lo e confere a organização. O plano contém dados dos cadastros: mantenha-o privado. Clientes, propriedades, talhões e insumos com unidade normalizada podem ser propostos. Máquinas exigem vínculo explícito com propriedades: `--machine-properties arquivo.json`, com mapa do ID legado da máquina para lista dos IDs v2 das propriedades. Os IDs do plano são determinísticos e os reenvios são idempotentes.

Confira áreas, culturas/safras, vínculos e inventário inicial. Áreas padrão, saldos, preços e safras não confirmados não são promovidos a dados conferidos. Serviços e movimentos antigos permanecem no histórico v1; esta ferramenta não importa todo esse histórico.

## Pendências antes da produção

Validar no celular/PC reais, testar a migração e restauração dos dados reais, definir a assinatura de distribuição e conferir o impacto dos perfis legados. Os testes automatizados não substituem essa homologação.

Os relatórios somam somente custos registrados de máquinas e insumos. A tarifa da máquina exclui combustível e mão de obra. Não representam custo total da cultura, lucro, margem ou fluxo de caixa. Financeiro completo, produção/vendas, planejamento, comparações consolidadas, lotes/fornecedores/transferências, reconciliação histórica complexa e grandes relatórios em segundo plano continuam como expansão. IA/n8n ficam separados.
