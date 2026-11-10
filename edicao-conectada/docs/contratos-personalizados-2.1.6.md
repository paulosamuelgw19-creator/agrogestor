# Contratações personalizadas — AgroGestor 2.1.6+2015

## Diagnóstico e alterações

Base examinada: commit a58a0c0, versão 2.1.5, sem alterações locais no início.
Flutter/Dart e SQLite no celular; FastAPI/Python e SQLite no PC gestor e na central Windows.
Permanecem os perfis, autenticação, filas, concessões por propriedade e Tailscale.
A central anterior controlava emissão/ativação, suspensão, revogação e validade. Não havia
contratação individual, quotas numéricas nem telemetria de uso. Aparelhos tinham revogação,
mas limite numérico ilimitado. Não foi acrescentado gateway de pagamento, IA ou n8n.

Arquivos principais: `central_license/license_server/contracts.py`, `central_license/public/contracts.js`,
`server/agrogestor_server/commercial.py`, rotas existentes em `app.py`, `v2_api.py` e `v2_catalog.py`,
`lib/features/licensing/plan_screen.dart` e filas existentes de `properties/catalog_store.dart`.

## Contratação, uso e permissões

Somente o administrador central edita condições comerciais. O gestor consulta **Meu plano**,
administra seus registros e solicita alterações ao responsável comercial. Operador/mecânico
não recebem preço, notas comerciais ou a ficha administrativa de uso. Recursos/limites
operacionais disponíveis por `/licensing/features` não substituem permissões individuais.

Cada contratação contém nome, organização, plano comercial, preço inteiro em centavos,
periodicidade, início, vencimento/cortesia, situação, limites independentes, módulos,
implantação, treinamento, suporte e notas. `null` é explicitamente **Sem limite**; `0` é
nenhuma vaga. Uso desconhecido não é zero. Limites inteiros entre 0 e 1.000.000; preço
entre 0 e 1.000.000.000.000 centavos. Datas têm fuso horário.

Modelos opcionais são cópias: salvar/editar modelo não modifica clientes. Aplicar um
modelo preenche condições no formulário; somente salvar a ficha afeta aquele cliente.
Nome do cliente e datas não são substituídos pelo botão de cópia do modelo.

Revisões usam comparação com revisão esperada; edição simultânea exige atualizar.
Reduções exibem prévia com uso, reservas, novo limite e excedente, incluindo aviso
quando não existe medição recente. O salvamento exige motivo e confirmação de redução.
Auditoria preserva administrador, organização, antes/depois, motivo, horário e revisão.
Rotação de credencial também é auditada, sem armazenar o segredo bruto no banco.

## Fontes dos contadores

As contagens são calculadas no PC, dentro da mesma transação que valida as inclusões:

| Recurso | Origem | Regra |
|---|---|---|
| Fazendas | `v2_properties` e propriedades embutidas nos `records/clients` | Identidades ativas; arquivadas preservadas fora da quota |
| Máquinas/veículos | `v2_machines` e `records/machines` | Uma identidade, independentemente de quantos vínculos em `v2_machine_properties` |
| Caminhões | Identidade da máquina em `v2_machines` | Perfil complementar em `v2_trucks` não acrescenta vaga |
| Contas | `users` com `disabled=0` | Todos os perfis; funcionário sem conta não ocupa vaga |
| Convites | `invitations`, não usados e não vencidos | Uma reserva por e-mail, por sete dias; renovação substitui reserva; aceite troca reserva por conta |
| Aparelhos | `devices` com `revoked_at IS NULL` | Ativações separadas das contas; um usuário pode usar vários aparelhos |
| Implementos | `records/implements`, ativos/não excluídos | Quota independente, ilimitada por padrão |

A união entre legado e v2 reconhece **somente** IDs iguais ou os UUIDv5 determinísticos
do importador existente (`agrogestor-v2/{organização}/{tipo}/{origem}`). A identidade
relacional, inclusive seu arquivamento, prevalece quando existe mapeamento. Nomes
iguais ou parecidos nunca provocam fusão. Cadastros manuais com IDs distintos precisam
de revisão administrativa; o software não adivinha que representam a mesma máquina.
Históricos não são renumerados, fundidos ou apagados para alterar contadores.

## Fluxo e endpoints

1. Central: `GET/POST /api/v1/admin/contracts`, `GET/PUT /api/v1/admin/contracts/{org}`,
   `POST .../{org}/preview`, `POST .../{org}/integration-key` e modelos em
   `GET/PUT /api/v1/admin/contract-templates[/{nome}]`.
2. PC: `POST /api/v1/contracts/exchange` na central, autenticado por
   `X-Agrogestor-Organization-Key`. Cada chave pertence a uma única organização.
   A chave global antiga de validação da licença não autoriza essa integração.
3. PC valida organização, revisão, datas, limites, módulos/dependências e guarda
   `commercial_entitlements`. Revisão anterior ou conteúdo diferente na mesma revisão
   é rejeitado. Troca de credencial exige atualizar o `.env` privado do PC.
4. PC envia somente contagens, reservas, revisão aplicada, versão e horário da medição.
   Não envia operações, valores operacionais, funcionários, senhas, fotos ou banco.
5. A revisão recebida aparece como aplicada somente após a próxima confirmação do PC.
   A ficha distingue salvo, aplicado, pendente, data de medição e comunicação.
   Sem medição mostra **Não informado**; após 24 horas sinaliza desatualização.
6. Atualização periódica no próprio processo do PC a cada cinco minutos; consulta
   **Meu plano** também força conferência. Nenhum serviço extra de fila é necessário.
7. Aplicativo: `GET /api/v1/licensing/plan` exclusivo do gestor, e
   `GET /api/v1/licensing/features` com direitos operacionais para os demais perfis.

Definir `AGROGESTOR_CONTRACT_ORGANIZATION_KEY` no `.env` privado do PC. Em produção,
o destino normalmente é `AGROGESTOR_LICENSE_API_BASE` já configurado para a central
Windows. `AGROGESTOR_CONTRACT_API_BASE` é uma substituição opcional para teste isolado.
HTTPS é obrigatório fora de localhost; a integração não segue redirecionamentos.
Segredos não são incluídos no APK. O backend Firebase antigo continua funcionando
para sua política anterior; contratos personalizados são oferecidos pela central Windows.

Uma edição comercial explícita aplica status e validade à licença central correspondente.
A configuração inicial de compatibilidade copia validade/situação existentes e deixa
quantidades ilimitadas. Editar apenas uma quantidade não renova o prazo. Cortesia em
situação de teste usa a menor data entre vencimento e fim da cortesia. Suspensão e
vencimento impedem novas gravações, preservando consultas autorizadas.

## Transações e política de excedente

`BEGIN IMMEDIATE` protege conferência e gravação de fazendas, máquinas, contas,
convites, aparelhos e cadastros legados. Reenvio por ID já confirmado não ocupa vaga.
Fazenda com vários talhões continua uma gravação atômica. Lotes legados retornam
confirmação/rejeição individual; todos os eventos aceitos ficam consistentes ao commit.

Redução não desativa ninguém nem arquiva recursos. Uso acima do limite impede
inclusões/reativações que aumentem uso; operações, estoque, ordens e trabalho em
recursos existentes continuam sujeitos às permissões e à validade da licença.
Arquivamento de máquina é auditado, com versão e endpoint
`PATCH /api/v1/licensing/machines/{id}/archive`. Reativação confere quota.
Não selecionar máquinas arquivadas/rascunhos para novas operações.

Erros preservam `detail` textual para clientes antigos e acrescentam `code/resource`:
`QUOTA_EXCEEDED`, `CONTRACT_OVERAGE`, `MODULE_DISABLED`, `CONTRACT_EXPIRED`,
`CONTRACT_SUSPENDED` e `USAGE_REVIEW_REQUIRED`. Falha de comunicação preserva a
última configuração confirmada e segue a política de licença existente; não cancela dados.

Módulos reconhecidos: propriedades, frota, estoque, operações, combustível, oficina,
tarefas e relatórios. As tarefas agrícolas existentes exigem operações habilitadas. Operações dependem de propriedades/frota/estoque; combustível
depende de frota/estoque; oficina depende de frota/estoque; demais dependências são
validadas pela API. Desabilitar módulo bloqueia novos trabalhos/cadastros correspondentes,
mas mantém leitura e exportação histórica autorizada. Progresso de tarefas/ordens e
conclusão de trabalhos já programados continuam permitidos. Desativar relatórios não
retira o direito de consultar/exportar históricos existentes. Nenhum aumento de plano
altera isolamento entre organizações ou a privacidade das tarefas individuais.

## Offline e migrações

Permanecem o prazo da licença existente (sete dias desde confirmação válida, respeitando
vencimento) e o cache autorizado de oito horas, limitado pelo token. Nenhuma edição
de contrato estende esses prazos automaticamente.
Plano e recursos confirmados ficam no cache SQLite separado por servidor/organização/conta.
Fazendas e máquinas criadas offline são rascunhos; disponibilidade de vaga depende do PC.
Rejeição comercial conserva rascunho e filhos, interrompe reenvios automáticos e apresenta
**Conferir cadastros salvos**. Só uma ação de conferência recoloca o pedido na fila.
Rascunho não concede acesso a estoque/operações antes da confirmação.

Migrações anteriores 1–9 permanecem com os mesmos checksums. A nova migração 10
acrescenta `archived` e `version` às máquinas. Tabelas comerciais adicionais não
reescrevem históricos. `tool/commercial_backup.py` faz backup SQLite, restaura uma cópia,
ensaia a migração duas vezes e compara todos os valores das colunas anteriores.
O banco vivo só é atualizado depois desse ensaio. Preservadas as correções SQLite
de conexão por isolate, WAL, timeout e fechamento de conexão no sincronismo em segundo plano.

## Validação e implantação

Testes usam bancos temporários e dados sintéticos. Cobrem contratos independentes,
revisões, auditoria, redução, ilimitados, módulos/dependências, credenciais por organização,
preço/datas, último lugar, concorrência, replay, fazenda com filhos, reserva/aceite/expiração
de convites, usuário com múltiplos aparelhos, vínculo múltiplo de máquina, arquivamento,
reativação, sincronização de direitos e queda da central. A regressão cobre operações,
estoque, manutenção, relatórios, isolamento e backup/restauração anteriores.

No Android, o teste nativo usa arquivos descartáveis: reproduz COMMIT na configuração
antiga e executa a configuração corrigida três vezes. Não opera sobre o banco do usuário.
Atualização dos emuladores é `install -r`, precedida de cópia completa e comparação
do banco/filas antes e depois. Nunca desinstalar/limpar dados para contornar erro.

Primeiro implantar central Windows; depois PC com credencial própria; finalmente APK.
Antes de produção, repetir backup/restauração na base correspondente e conferir a
revisão aplicada. Piloto central usa 8771 e operacional 8766 em localhost. A central
anterior de produção e as rotas Tailscale não são alteradas por esse piloto.
Teste em celulares reais e migração do ambiente de produção continuam etapas de implantação.
