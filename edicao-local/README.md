# AgroGestor Local 2.1.8

Os dados agrícolas ficam no aparelho. A central de licenças é usada para a primeira ativação de cada instalação.

No Windows, execute `./Iniciar-servidor.ps1 -Preparar` na pasta [licenciamento/servidor-licencas](licenciamento/servidor-licencas/). Configure o administrador pelo terminal. O [painel local](http://127.0.0.1:8790/) fica no mesmo PC. O arquivo `dados-privados/issuer-public.json` contém a chave pública usada no APK. O servidor também guarda material privado nessa pasta. Use somente o arquivo público para compilar.

## Compilar APK de teste

Use Flutter 3.38.9, Java 17 e Android SDK. No PowerShell, a partir de `edicao-local`, informe uma origem HTTPS de ativação previamente configurada e verificada:

```powershell
$issuer = Get-Content ./licenciamento/servidor-licencas/dados-privados/issuer-public.json -Raw | ConvertFrom-Json
[Environment]::SetEnvironmentVariable('ORG_GRADLE_PROJECT_agro-issuer-public-key', $issuer.publicKey, 'Process')
$activationOrigin = Read-Host 'Origem HTTPS de ativação'
Set-Location ./fonte-local
flutter pub get
flutter build apk --debug --dart-define=AGRO_STANDALONE_LOCAL=true --dart-define=AGRO_HIDE_MANAGER_CONFIG=true "--dart-define=AGRO_LOCAL_ACTIVATION_URL=$activationOrigin"
```

Para teste no MuMu no mesmo Windows, use `adb reverse tcp:8790 tcp:8790`, configure `http://127.0.0.1:8790` como origem e acrescente `--dart-define=AGRO_LOCAL_ACTIVATION_LOOPBACK_TEST=true` ao comando de compilação. Para distribuição, configure a assinatura de release com `android/key.properties.example` como referência e valide a ativação por HTTPS em um aparelho físico.
