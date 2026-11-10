# Propriedades e Talhões — cadastro local 2.0.4

O gestor cadastra responsáveis, propriedades e talhões no aplicativo. Cada
alteração fica gravada em SQLite junto de uma fila persistente, antes de tentar
contatar o PC gestor. O PC confirma os cadastros e distribui os dados aos
operadores da mesma organização. O operador consulta áreas autorizadas e registra
operações; não administra propriedades nem talhões.

## Preservação e sincronização

- A fila envia os responsáveis antes das propriedades e os talhões antes das
  safras. Os identificadores permanecem iguais nos reenvios.
- Edições usam uma versão esperada. Um conflito é conservado para conferência,
  sem sobrescrever automaticamente o cadastro confirmado no PC.
- Cache e fila são separados por servidor, organização e usuário. Dados
  autorizados em cache vencem em até oito horas ou no vencimento da sessão,
  o que ocorrer primeiro. Uma revogação confirmada limpa o cache correspondente.
- Novas propriedades criadas por este aplicativo são compartilhadas com
  operadores ativos da própria organização. Contas com perfis específicos por
  propriedade não são elevadas automaticamente. Revogações existentes são
  respeitadas. Novos operadores convidados recebem áreas marcadas como
  compartilhadas; o servidor audita essas concessões.
- Arquivamento preserva identificadores e histórico. Áreas inconsistentes
  são recusadas no aparelho e verificadas novamente pelo servidor.
- Dados sem área conhecida permanecem ausentes; não se inventa área zero.

## Compatibilidade

A migração 5 acrescenta uma indicação de compartilhamento às propriedades,
com padrão desligado para propriedades antigas. Não altera os lançamentos
existentes nem converte cadastros antigos automaticamente. O servidor oferece
a capacidade `offlineCatalog` para identificar a versão compatível.

Se o PC antigo não oferecer essa função, o cadastro local continua disponível
e a fila permanece salva. A tela explica que o PC precisa de atualização,
em lugar de apresentar o texto `Not Found`.

O modo de demonstração possui seu próprio espaço local. Rascunhos de um perfil
de demonstração não são transferidos automaticamente para uma conta real.
Para compartilhar, use desde o início a conta do gestor vinculada ao PC;
depois do primeiro acesso, os cadastros podem ser feitos sem conexão.

## Validação

Foram executados 43 testes do servidor e 71 testes do aplicativo, incluindo
o fluxo real entre SQLite do cliente móvel e FastAPI: cadastro offline,
envio ordenado, recebimento por operador, lançamento de aplicação e baixa
de estoque. Análise estática sem problemas. Testes adicionais conferem
persistência após reabertura, versões sucessivas, isolamento de contas,
restrição do operador, vencimento de cache, revogação e área excedente.

Também foi validado no MuMu: gestor cadastra um responsável, uma propriedade
de 10 ha e um talhão de 5 ha com o servidor do piloto desligado. Ao religar
e sincronizar, o operador recebe a área. Na tela do operador foi registrada
uma aplicação fictícia de 2 kg de adubo. O PC confirmou uma única operação,
um único consumo de R$ 20 e saldo de 8 kg / R$ 80 a partir de 10 kg / R$ 100.
O histórico guarda autor e contexto da propriedade, do talhão e da safra.
SQLite íntegro, sem violações de chaves estrangeiras. Os números são somente
do teste; custos não informados não foram considerados zero.

## Pendências do projeto completo

Conferência dos dados dos emuladores antigos antes de migração real;
interface para resolução orientada de conflitos de cadastro;
rateio manual entre vários talhões; histórico consolidado de todas as
categorias de despesa; manutenção contabilizada separadamente; relatórios
financeiros completos por propriedade e talhão. IA e n8n ficam para etapa
separada, conforme solicitado.
