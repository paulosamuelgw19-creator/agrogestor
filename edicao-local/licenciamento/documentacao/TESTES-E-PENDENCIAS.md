# Testes e pendências - AgroGestor Local 2.1.8

> Os nomes de arquivos de evidência identificam registros da entrega original, guardados separadamente dos fontes.

## Resultados executados

- **18 testes Python do servidor: aprovados.** Evidência: testes/servidor-ativacao-final.txt. Incluem transação concorrente, prova de posse, recuperação idempotente, replay, cancelamento, autenticação/CSRF/origem, limites, ausência de código/senha em texto puro, envelope adulterado e backup/restauração. Os cenários Windows também executaram a configuração inicial sem conta padrão e a CLI real com DPAPI, proteção dos caminhos de dados e preservação da pasta anterior.
- **56 testes locais Flutter: aprovados.** Incluem os 12 novos cenários de ativação, os cenários anteriores de operação/estoque/backup, migração e interface. Evidência: testes/regressao-local.txt.
- **126 testes existentes de regressão: aprovados.** Evidência: testes/regressao-existente.txt. Há 15 casos sobrepostos com o conjunto local; não somar como testes únicos.
- **Análise estática: sem problemas.** Evidência: testes/analise-app.txt.
- **Android nativo em dois MuMu: aprovado.** Evidência consolidada: testes/MUMU-RESULTADO-ATIVACAO.json. Foram usadas instalações independentes, cada uma com sua chave P-256 não exportável pelo fluxo do app.
- **Guia PDF: duas páginas renderizadas e inspecionadas visualmente.** Textos, margens e paginação conferidos.

## Matriz dos cenários solicitados

| Cenário | Verificação executada | Resultado |
|---|---|---|
| 1. Instalação nova exige ativação | Widget a 320px e Android nativo: sessão antiga não libera catálogo sem licença; destino inicia sem autorização | Aprovado |
| 2. Código válido libera uma instalação | API e Android Keystore no MuMu | Aprovado |
| 3. Mesmo código não libera outra instalação | API e segundo MuMu com chave diferente | Aprovado |
| 4. Concorrência não duplica autorização | Duas ativações paralelas contra SQLite real temporário; uma licença | Aprovado automatizado |
| 5. Resposta perdida recupera autorização original | Nova prova da mesma chave e comparação do documento; falha de salvamento/repetição no cliente | Aprovado automatizado; perda real de pacote não foi induzida no celular |
| 6. Licença adulterada/copiada é recusada | Assinatura alterada no verificador Android e licença do primeiro apresentada ao segundo | Aprovado |
| 7. Servidor desligado não bloqueia | Processo de ativação parado antes das verificações nativas; dados e backup acessíveis | Aprovado MuMu |
| 8. Modo avião, fechamento e reinício | Modo avião confirmado pelo próprio Android antes/depois da validação e backup em ambos; processo fechado/reaberto; Android reiniciado com central desligada | Aprovado MuMu |
| 9. Atualização preserva licença, chave e dados | Dados 2.1.7 atualizados para 2.1.8 e snapshot lógico idêntico; reinstalação compatível 2.1.8 por cima preservou licença/fingerprint/dados | Aprovado MuMu; não foi inventado upgrade 2.1.8 para versão futura |
| 10. Backup comercial não clona ativação | Conteúdo exportado sem autorização/chave; restauração sem licença bloqueada no destino | Aprovado |
| 11. Destino ativa e restaura com licença própria | Segundo código, segunda chave, restauração dos dados e comparação da licença/fingerprint do destino | Aprovado MuMu |
| 12. Código inválido/cancelado não libera | API real temporária e mensagens do cliente | Aprovado automatizado |
| 13. Rotas administrativas protegidas | Sem sessão, sem CSRF, origem inválida e conexão não local | Aprovado automatizado |
| 14. Segredos fora de logs/APK | Respostas de validação sanitizadas, códigos só por corpo, listas sem código completo, conferência de arquivos e binários na embalagem final | Evidência adicional em VERIFICACAO-PACOTES.json |
| 15. Recuperar central mantém emissor/códigos | Backup cifrado, senha errada recusada, restauração para outro diretório, CLI Windows/DPAPI, assinatura e estado utilizado preservados | Aprovado; mudança física de PC não executada |
| 16. Fluxos locais anteriores preservados | Regressão Flutter, igualdade dos registros existentes no Android e backup offline/restauração no destino | Aprovado nos cenários cobertos |

O teste de modo avião e o teste de reinício foram executados separadamente. No teste de reinício, o Wi-Fi do emulador estava restaurado, mas o servidor de ativação continuava desligado. A autorização foi validada localmente e o snapshot de dados permaneceu idêntico.

## Observações da execução

O modo avião do MuMu interrompe o transporte TCP do ADB. As primeiras tentativas de coleta ficaram sem resposta e não foram consideradas aprovadas. O teste final colocou uma espera controlada no executável de instrumentação, habilitou o modo avião, verificou o estado pelo próprio Android, validou a licença/backup dentro do app e só recolheu o resultado após restaurar a rede. O controle nativo MuMuManager sh permitiu restaurar a conectividade sem apagar dados. Não foi contornada uma barreira de certificados.

Os APKs normais foram separados dos executáveis de instrumentação. A instrumentação recebe códigos apenas por um arquivo privado de teste; os códigos não ficam embutidos no APK, e o arquivo é substituído por parâmetros offline depois da ativação. O aplicativo normal foi recolocado ao final. Ativações e senhas administrativas de teste usaram bancos temporários, separados dos dados reais da central.

## O que ainda não foi executado

1. **HTTPS externo e ativação fora da rede local.** Não existe domínio/endereço público configurado. O caminho de implantação está documentado, mas não foi publicado nem testado em produção. O APK para envio ao produtor ainda depende disso.
2. **Celular Android físico do produtor.** Instalação, Keystore desse aparelho, câmera, seleção de arquivos, restauração e uso no campo precisam de conferência real. Nenhum desses cenários físicos foi marcado como aprovado.
3. **Revisão visual manual das telas Android e do painel.** A captura de janela Windows retornou timeout. Há testes de widget e de API; isso não foi apresentado como inspeção visual completa do aplicativo instalado.
4. **Primeira conta administrativa real.** O proprietário deve escolher usuário/senha ao executar Iniciar-servidor.ps1. Não foi criada credencial padrão para contornar essa etapa.
5. **Migração da central entre dois PCs físicos.** A cifragem portátil e a restauração para outra pasta foram testadas, incluindo DPAPI no Windows atual. Uma troca física de Windows/usuário ainda precisa ser ensaiada antes de depender dela.
6. **Publicação comercial.** APKs são de teste e usam assinatura de depuração compatível com a base anterior. Uma versão comercial precisa de gestão da chave de assinatura definitiva, sem prometer proteção absoluta contra aparelhos comprometidos ou APK modificado.

## Limitações permanentes do modelo escolhido

Licença offline sem vencimento não pode ser revogada imediatamente em aparelho desconectado. Uma nova autorização não desativa o antigo. Reinstalação com perda da chave da instalação pode exigir nova autorização; preserve os dados e contate o responsável antes de desinstalar. Restaurar um backup antigo da central pode fazê-la esquecer códigos consumidos depois do snapshot; isso exige conferência administrativa, pois as licenças já emitidas continuam válidas offline.
