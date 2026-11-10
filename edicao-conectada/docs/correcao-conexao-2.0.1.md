# Correção da conexão — 2.0.1+2004

Data: 14/10/2026. APK de teste/homologação.

## Problema e correção

Ao salvar o endereço do PC gestor, o campo do diálogo podia ser descartado antes do término da animação de fechamento. O teste anterior à correção reproduziu `TextEditingController was used after being disposed` e a mesma asserção `_dependents.isEmpty` apresentada na captura.

Os diálogos de endereço e convites agora possuem seu próprio ciclo de vida e devolvem valores imutáveis. As operações assíncronas verificam se a tela ainda existe antes de atualizá-la. A troca de servidor pode encerrar a sessão; a tela de sincronização respeita esse encerramento. Botões ficam indisponíveis durante o salvamento.

Não há mudança no esquema do banco nem migração de registros nesta correção. As regras existentes de HTTPS continuam aplicadas.

## Validação

- Suíte Flutter: 57 testes passaram, um teste de integração dependente de ambiente foi omitido nessa execução.
- Após o ajuste final de estilo: os seis testes específicos de endereço/convites passaram novamente; `flutter analyze` sem problemas.
- APK compilado e assinatura conferida; pacote `com.campo.agrogestao`, versão 2.0.1, código 2004.
- No MuMu que executava 2.0.0: backup privado validado, atualização por instalação sobreposta, versão instalada conferida.
- Teste manual no MuMu: abrir configuração, selecionar o campo e salvar o endereço existente; retorno à tela de entrada com confirmação, sem tela vermelha.
- Consulta HTTP de dentro do MuMu a `http://10.0.2.2:8765/api/v1/health`: resposta 200 com servidor configurado. Consulta validada sem redirecionamento ADB.
- A outra instância, com versão 1.0.0, não foi atualizada.

## Uso

Neste PC, o servidor anterior usa `http://10.0.2.2:8765` no MuMu e deve permanecer em execução. O piloto v2 usa a porta 8766 e exige configuração própria; esta correção não configura nem migra automaticamente o servidor anterior para v2. O acesso à saúde do servidor confirma conectividade, mas não substitui o teste autenticado de sincronização com a conta do usuário.

O APK 2.0.1 está na pasta `APK` da entrega. Não é necessário desinstalar o aplicativo nem limpar seus dados para atualizar. O backup privado permanece fora do repositório e não deve ser publicado.
