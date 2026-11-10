# AgroGestor 2.1.2 — revisão de proporções e leitura

Revisão realizada em 14/10/2026. Mantidos o padrão de cores, a linguagem e os dados do aplicativo.

## Ajustes

- Cartões do painel com larguras iguais e alturas alinhadas em cada linha. Os quatro indicadores usam uma, duas ou quatro colunas, conforme a largura e o tamanho das letras; evitada a composição com três cartões e um isolado.
- Busca e sincronização reunidas em “Mais opções” no cabeçalho de celulares estreitos. Os títulos podem ocupar duas linhas e a altura acompanha a fonte.
- Menu lateral permanente somente quando houver largura e altura suficientes. Girar um celular para a horizontal não força o painel lateral de desktop.
- Ações de propriedades passam para outra linha quando necessário, sem espremer “Nova propriedade”.
- Cabeçalho de Operações pode rolar, liberando espaço para os registros, especialmente na horizontal e com letras ampliadas.
- Seletores de tipo de operação, origem do combustível e perfil de convite respeitam a largura disponível.
- Seletores de talhão/safra e das opções de oficina permitem a altura necessária para seus nomes em duas linhas.
- Formulários de propriedades, operações e oficina respeitam a largura útil da tela. O conteúdo continua rolável com teclado aberto.
- Ações para conferir e reenviar conflitos ficam abaixo da descrição, sem ocupar o espaço do título na lateral.
- Total do relatório anterior aparece abaixo da descrição, evitando que um valor grande comprima o texto.
- Confirmações de sincronização não aparecem mais como avisos laranja de erro. Avisos de desconexão e pendências continuam visíveis, com a orientação inteira.

## Validação

Foram reproduzidos estouros laterais no formulário de operação antes da correção. Os testes passaram após os ajustes.

- Formulários em 320 × 640 e 720 × 460 com letras a 150%.
- Cartões em larguras de 320, 360, 514 e 900, conferindo alinhamento dos números, dimensões e limites laterais.
- Propriedades e diário da oficina com teclado aberto.
- Seleção de abastecimento e cancelamento sem gerar lançamentos.
- Altura do texto selecionado de talhão/safra dentro do campo, além da ausência de erros de renderização.
- Aviso de sincronização concluída sem ícone de erro; fila pendente e orientação offline preservadas.
- Suíte geral: 93 testes aprovados, incluindo fila SQLite, API real em banco temporário, estoque e relatórios. Os testes focados de componentes e formulários foram executados novamente após os refinamentos da conferência visual, incluindo os novos casos de aviso e alinhamento. São execuções com testes em comum; as contagens não devem ser somadas.
- Análise estática aprovada sem apontamentos.

A conferência manual utiliza somente os dois emuladores autorizados, com resolução de captura 720 × 1280 e densidades diferentes. Foram verificadas letras ampliadas e orientação horizontal. Os formulários foram cancelados, sem salvar operações de teste adicionais.

## Preservação e entrega

Antes da instalação foi feita cópia do banco do piloto e dos dados dos dois aplicativos. Os bancos copiados passaram na verificação de integridade e vínculos. A atualização é instalada sobre o aplicativo existente, com a mesma assinatura; não usa desinstalação nem limpeza de dados.

Na conferência da primeira instalação, os 16 registros anteriores do emulador gestor permaneceram idênticos. O outro emulador não tinha registros na coleção antiga. A nova versão mantém o banco local e as contas existentes.

O servidor piloto está disponível para a conferência das telas sincronizadas. Sua migração aditiva 8, preparada na etapa anterior, foi aplicada após o backup. A capacidade de Logística continua desabilitada: esta versão não entrega viagens, fretes ou contas de caminhoneiro.

Arquivo de entrega: `APK/AgroGestor-2.1.2-piloto.apk`, na pasta da versão piloto. Backups e capturas ficam fora do Git, nas pastas privadas de backups e temporários. Os outros emuladores e o banco antigo de produção não foram atualizados.
