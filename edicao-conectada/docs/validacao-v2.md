# Implementação e validação — v2

14/10/2026. App 2.0.0+2003, para homologação. Fontes e dados originais preservados; sem instalação no servidor em uso, sem importação de registros reais e sem IA/n8n.

## Desenvolvido

- Telas ligadas à API para propriedades, cadastros relacionais, frota, estoque, operações e relatórios.
- Cliente/propriedade/talhão/cultura/ciclo, máquinas vinculadas às propriedades e insumos com unidade explícita.
- Operação com autor autenticado, data, tipo, área, observações, horas de mão de obra opcionais, várias máquinas e vários insumos.
- Inventário inicial, entradas, média móvel de custo, consumo e ajuste físico/valor com motivo e conferência do último movimento.
- Horímetros validados; intervalo sem apontamento explícito; nome/tarifa e vínculos de máquina editáveis com auditoria e detecção de alteração concorrente. Mudanças de tarifa não reescrevem o custo de operações anteriores.
- Operação/estoque/horímetro/auditoria confirmados atomicamente; reenvios idempotentes; falhas não deixam gravações parciais.
- Estorno da última operação elegível preserva o original e recompõe estoque/valor/horímetro. Movimentos posteriores impedem o estorno e exigem reconciliação.
- Permissões por propriedade: administrador, proprietário, gerente, funcionário e consultor. Funcionário vê suas operações sem preços; consultor consulta custos, sem lançar; cadastro de catálogos e concessão de acessos são do administrador.
- Isolamento por organização/propriedade no servidor e por servidor/organização/conta no cache e na fila móveis. Dados v1 ficam bloqueados a contas não administrativas com v2 habilitado, inclusive após revogar acessos.
- Fila SQLite persistente de operações, lease offline de até 8 horas limitado pela sessão, revalidação por envio, conflito explícito e suspensão da sequência daquela propriedade até conferência.
- Relatório por ciclo/período com identificação, geração, filtros, horas, área de passadas, consumo, custos registrados, custo por hectare e operações de origem; gráficos de custos conhecidos e estados distintos para ausência/incompletude.
- PDF com fonte embarcada e XLSX verdadeiro; aba numérica com ausências em branco e texto protegido contra interpretação como fórmula. Ambos usam o mesmo retrato confirmado.
- Migrações aditivas com versão/checksum e transação; plano de importação de cadastros e aplicação autenticada/idempotente, sem reescrever o histórico v1.
- Iniciador do piloto isolado no PC/rede privada; mecanismo existente de backup/restauração testado com o v2; central de licenças preservada.

## Validação

| Evidência | Resultado | Registro |
|---|---|---|
| Servidor Python | 32 testes passaram, incluindo 8 contratos anteriores | `validacao-servidor-v2-final.txt` |
| Suíte Flutter | 50 testes passaram; integração real omitida nessa execução por depender de fixture | `validacao-flutter-v2-final.txt` |
| Novo teste de cache restrito | O arquivo correspondente passou seus 8 testes, incluindo o novo; total único local Flutter: 51 | `validacao-cache-isolado.txt` |
| Cliente Dart contra FastAPI real | 1 teste passou: fila SQLite → API → estoque → relatório; repetição de UUID não duplica consumo | `validacao-integracao-real-v2.txt` |
| Análise Flutter | Nenhum problema encontrado | `analise-flutter-v2-final.txt` |
| APK | Compilado; assinatura validada; pacote/versão/arquiteturas conferidos | `compilacao-apk-v2-final.txt`, `validacao-assinatura-apk.txt`, `metadados-apk.txt`, `APK/verificacao.json` |
| PDF | Duas páginas renderizadas com Poppler e inspecionadas | `docs/exemplos/` |
| Excel | Aberto com openpyxl; indicadores numéricos reconciliados, ausências em branco, sem fórmulas originadas de texto | `docs/exemplos/Relatorio-FICTICIO.xlsx` |
| Iniciador | Sem erros na análise de sintaxe PowerShell | `server/run-pilot.ps1` |

**84 casos únicos aprovados**: 32 servidor + 51 Flutter local + 1 integração real. Subconjuntos repetidos não são contados novamente.

Testes cobrem isolamento de propriedade/organização, referências cruzadas, revogação e tentativa de contorno pelo v1; cache restrito; ausência versus zero; custo médio e resíduos de centavos; concorrência, reenvio, rollback, estorno/ajuste e tarifa histórica; prazo offline; migração repetida/falha e preservação do legado; backup/restauração dos relatórios.

O exemplo fictício confere: 7 h, R$840 de máquina + R$534 de insumos = R$1.374; 10 ha cultivados → R$137,40/ha; duas passadas → 20 ha de passadas. Diesel restante 80 L/R$496 e foliar 8 L/R$400. Horas de mão de obra ausentes não viram zero. Os cálculos são feitos por código, sem IA.

## Limites e pendências

- Nenhum Android estava conectado. Não houve teste em dispositivo/emulador, instalação no servidor operacional ou migração de registros reais. A integração real usou servidor local e dados fictícios temporários.
- O login atual continua com uma organização por instalação. Não é um SaaS multi-organização homologado só por usar `tenant_id`.
- Com v2 ligado, manutenção/abastecimento e os demais dados v1 ficam disponíveis somente ao administrador. A migração/permissão por propriedade desses módulos deve ser concluída antes de substituir a rotina dos perfis antigos de mecânico/operador.
- APK debug/de homologação. Produção exige chave de distribuição própria e validação da atualização/backup dos aparelhos.
- Somente operações têm fila offline. Cadastro/estoque/estorno/ajuste exigem conexão; relatório offline é o último retrato confirmado daquele filtro, com sua data.
- Estorno com movimentos posteriores e reconciliação histórica complexa não estão implementados; a recusa é explícita e atômica.
- Importação de todo o histórico, lotes/transferências/fornecedores, mão de obra remunerada, financeiro completo, produção/vendas, comparações agregadas, planejamento, jobs duráveis e alertas de produção permanecem no plano de expansão. IA/n8n ficam em trabalho separado.
- Não houve teste de carga, homologação da infraestrutura real nem auditoria externa de segurança.

Os documentos da etapa 1A registram a entrega anterior. Este documento e `guia-v2.md` descrevem o estado atual, com telas e APK de homologação. Nenhuma versão anterior foi apagada.
