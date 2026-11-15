# Entrega .5 — Contratos e ensaio de estoque

## O que entrou

- A licença informa os módulos contratados. A navegação e a busca do gestor seguem os módulos e suas dependências. Meu plano e Sincronização ficam acessíveis.
- O PC gestor aplica o contrato também a novas alterações e exclusões na sincronização e em rotas V2 de edição, estoque, tarefas, oficina e estorno. As consultas de histórico permanecem disponíveis pelas rotas autorizadas.
- Em cópia fictícia, a migração do estoque V2 registra saldo de abertura apenas com vínculo explícito entre produto e fazenda. O ensaio repetiu o saldo de 8 kg sem duplicação. O consumo histórico foi preservado na cópia e continua pendente de mapeamento, sem reaplicar uma baixa sobre o saldo já conferido.

## Roteiro curto

1. Inicie a Central e o PC gestor do piloto. No APK .5, entre como gestor fictício.
2. Confira Meu plano e os atalhos. Em um contrato de teste parcial, valide que o módulo removido some da navegação. O servidor deve recusar gravações diretas do módulo, e os históricos registrados continuam consultáveis pelas rotas autorizadas.
3. No ensaio de migração, use somente uma cópia do .agrobackup e um mapeamento privado com `countedOn` e `propertyByProduct`. Rode `tool/migrar_cafe_local.py COPIA.agrobackup --estoque MAPA.json` para conferir quantos saldos serão planejados.

## Onde retomar

Implementar a operação integrada em vários talhões com um identificador, vínculos por ciclo, efeitos de estoque e máquina gravados uma vez e rateios manuais em centavos por fonte. Usar os custos consolidados existentes no geral e as partições no recorte por talhão. Em seguida, concluir tarefas, mão de obra, aprovações, estornos e as demais decisões de produção, comércio, documentos, compras e estoque.

A distinção configurável entre administrador e gestor por ação ainda está pendente. Migração real depende da cópia privada do produtor, validação dos demais módulos e teste no Android físico com HTTPS.

## Resultados

121 testes do PC gestor e 18 da Central passaram. Depois da correção pontual para impedir a conclusão de tarefas por operações quando o plano desabilita Tarefas, passaram os cinco testes dirigidos de contrato, incluindo o reenvio autorizado. Passaram também 17 regressões Flutter. No MuMu abri Colheita e Beneficiamento e conferi o histórico sincronizado de 30 kg em estoque, R$ 350 recebidos e R$ 650 a receber. A conferência visual de um contrato parcial no MuMu fica pendente. O bloqueio das gravações do plano parcial foi testado pela API.

SHA-256 do APK .5: D0B578C8570A1BDCCE86AFBFD9417E5CA910AF3CFA6D5295B7E4831E06C2D22C

## Referência atual e compilação

A referência é o APK 2.1.7-cafe-conectado.5 publicado na área de Releases. O código e os três servidores ficam em agrogestor-cafe-conectado. O repositório Maven local necessário à compilação está em agrogestor-cafe-conectado/compilacao-maven.

No PowerShell, dentro da pasta android do projeto, use o JDK configurado e rode:

    .\gradlew.bat --offline -I piloto-offline.init.gradle :app:assembleDebug '-Ptarget-platform=android-arm,android-arm64,android-x64'

O ensaio usou uma cópia fictícia de teste. Os registros privados do produtor ficam na pasta piloto-local, reservados para conferência e migração.
