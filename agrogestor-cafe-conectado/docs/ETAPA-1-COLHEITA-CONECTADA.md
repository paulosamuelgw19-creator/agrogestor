# Etapa 1 — Colheita Conectada

Gestores autenticados podem registrar o total do dia por fazenda, talhão e safra ou lançar a colheita por pessoa. Sem conexão com o PC gestor, a gravação fica na fila do aparelho. Na reconexão, o PC gestor aplica as permissões, valida os vínculos do catálogo e confirma a versão gravada.

O cálculo preserva a unidade original. Uma anotação de 7 medidas de 60 L mais 40 L avulsos dá 460 L. O detalhamento por pessoa é somado e comparado ao total declarado, que entra uma única vez no histórico. Se dois aparelhos lançarem o mesmo total diário de forma independente, a fila sinaliza o conflito para revisão.

## Roteiro no MuMu

1. Inicie a Central (8870) e o PC gestor A (8865) pelos atalhos do piloto. Use o encaminhamento ADB descrito no Guia do Piloto. Entre como gestor do cliente A em dois emuladores.
2. Em um aparelho, abra **Colheita → Fazenda → Talhão → Abrir colheita**. Também é possível entrar pelo **Caderno do talhão → Colheita**. Use a fazenda fictícia do piloto.
3. Interrompa a conexão com o PC gestor. Em **Registrar produção do dia**, use uma data livre da safra e informe 7 medidas, 60 L por medida e 40 L de sobra. Confira 460 L e salve.
4. Use **Registrar colheita** para informar uma parte do total por pessoa. A produção do dia vem uma vez no histórico. Havendo diferença, use **Conferir produção** para escolher o total aplicável.
5. Reconecte, toque **Sincronizar agora** no primeiro e no segundo aparelho. O registro deve chegar com a quantidade e o detalhamento originais. Repita o envio e confira que o total fica igual.
6. Use **Ver fila e conflitos** caso o aparelho mostre alguma pendência. Para testar a concorrência, cadastre quantidades diferentes para o mesmo dia nos dois aparelhos offline e sincronize em sequência.

## Verificações concluídas

- Análise estática do código Dart sem ocorrências.
- 13 regressões Flutter da edição local aprovadas, incluindo histórico, backup e pagamentos locais.
- Quatro testes de integração da API aprovados. Cobrem reenvio, conflito, isolamento, papéis, medidas e sobras, litros, carretas, conferência e rejeição de tarifas.
- Revisão independente de segurança confirmou que dois envios simultâneos do mesmo dia deixam uma declaração, que os dados administrativos são exclusivos do gestor da organização e que um ZIP restaurado preserva o evento e a versão.

## Pendências de produção

Validar HTTPS em Android físico, troca de perfil e sessão expirada no aparelho. Importar dados existentes somente na etapa de migração. Pagamentos e tarifas da equipe seguem disponíveis na edição Café Local.

A etapa 2 trata da conferência do volume recebido. O lançamento de colheita representa o volume em campo, e a futura entrada confirmada representará o café recebido para estoque. Os dois registros devem ficar vinculados e manter a comparação de volumes.

## Validação no MuMu

O APK 2.1.7-cafe-conectado.2 foi instalado por cima do anterior nas instâncias 0 e 2. O lançamento offline de 7 medidas de 60 L mais 40 L apareceu nos dois aparelhos depois da reconexão. O detalhamento de 120 L por pessoa mostrou 340 L de diferença e o consolidado manteve 460 L. O PC A guardou uma declaração e um lançamento por pessoa. O PC B ficou sem registros de colheita. Se o MuMu apresentar problema de renderização, pode-se iniciar o aplicativo pelo ADB com o extra Android enable-impeller=false.
SHA-256 do APK de teste: 97E36F6FC9CD879CE62D732312A3E4B6A631A6F056DA5DD45E3F4B3B345CE30D
