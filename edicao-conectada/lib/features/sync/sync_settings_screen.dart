import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../auth/auth_service.dart';
import '../auth/connection_dialogs.dart';
import '../auth/user_model.dart';
import '../licensing/licensing_service.dart';
import 'app_database.dart';
import 'farm_api_client.dart';
import 'legacy_farm_data_import.dart';
import 'sync_service.dart';

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final _url = TextEditingController();
  final _licenseKey = TextEditingController();
  bool _busy = false;
  bool _loaded = false;
  Future<List<DeviceActivation>>? _devicesFuture;
  Future<List<Map<String, dynamic>>>? _usersFuture;
  Future<LegacyFarmDataPreview>? _legacyPreviewFuture;

  @override
  void initState() {
    super.initState();
    _loadUrl();
    _loadDevices();
    _loadUsers();
    _legacyPreviewFuture = LegacyFarmDataImport().preview();
  }

  @override
  void dispose() {
    _url.dispose();
    _licenseKey.dispose();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _loaded = true;
      _legacyPreviewFuture = LegacyFarmDataImport().preview();
    });
  }

  Future<void> _loadUrl() async {
    if (FarmApiClient.standaloneLocalMode) return;
    if (_loaded) return;
    final address = await FarmApiClient.instance.baseUrl ?? '';
    if (!mounted) return;
    _url.text = address;
    _refresh();
  }

  void _loadDevices() {
    if (FarmApiClient.standaloneLocalMode) return;
    final user = AuthService().currentUser;
    if (user?.farmId != null && user?.role == UserRole.admin) {
      _devicesFuture = LicensingService().devices();
    }
  }

  void _loadUsers() {
    if (FarmApiClient.standaloneLocalMode) return;
    if (AuthService().currentUser?.farmId != null &&
        AuthService().currentUser?.role == UserRole.admin) {
      _usersFuture = SyncService().users();
    }
  }

  Future<void> _setUserAccess(Map<String, dynamic> user) async {
    final active = user['active'] == true;
    final enable = !active;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(enable ? 'Reativar conta?' : 'Bloquear conta?'),
        content: Text(enable
            ? '${user['displayName']} poderá entrar novamente com o e-mail e a senha cadastrados.'
            : '${user['displayName']} perderá acesso ao servidor e aos dados protegidos imediatamente.${user['id'] == AuthService().currentUser?.id ? ' Como esta é sua conta, você precisará de outro administrador para reativá-la.' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(enable ? 'Reativar' : 'Bloquear')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await SyncService().setUserActive(user['id'] as String, enable);
      if (mounted) {
        setState(() => _usersFuture = SyncService().users());
        _message(enable ? 'Conta reativada.' : 'Conta bloqueada.');
      }
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _releaseDevice(DeviceActivation device) async {
    final currentDeviceId = await LicensingService().deviceId();
    if (!mounted) return;
    if (device.id == currentDeviceId) {
      _message(
          'Este é o aparelho que você está usando. Libere o aparelho antigo ou faça isso no PC gestor.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Liberar aparelho?'),
        content: Text(
            '${device.name} perderá acesso. Uma nova ativação poderá usar esta vaga.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Liberar')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await LicensingService().releaseDevice(device.id);
      if (mounted) setState(_loadDevices);
      _message('Aparelho liberado.');
    } catch (error) {
      _message(error.toString());
    }
  }

  Future<void> _saveUrl() async {
    if (_busy) return;
    final address = _url.text;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await FarmApiClient.instance.configure(address);
      if (!mounted) return;
      _message('Endereço privado salvo.');
      if (!AuthService().isAuthenticated) return;
      await SyncService().syncNow();
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() => _busy = true);
    await SyncService().syncNow();
    if (mounted) {
      setState(() => _busy = false);
      _refresh();
    }
  }

  Future<void> _importLegacyData() async {
    final farmId = AuthService().currentUser?.farmId;
    final preview = await _legacyPreviewFuture;
    if (!mounted || farmId == null || preview == null || !preview.canImport) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Importar cadastros deste aparelho?'),
        content: Text(
          'Serão colocados ${preview.total} cadastro(s) antigo(s) na fazenda $farmId e enviados quando a conexão estiver disponível. '
          'Confirme que esta é a fazenda correta. A cópia antiga continuará guardada neste aparelho.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Importar')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final count = await LegacyFarmDataImport().importToCurrentFarm();
      _message('$count cadastro(s) adicionados à fila de sincronização.');
      await SyncService().syncNow();
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _legacyPreviewFuture = LegacyFarmDataImport().preview();
        });
      }
    }
  }

  Future<void> _activateLicense() async {
    final farmId = AuthService().currentUser?.farmId;
    if (farmId == null || _licenseKey.text.trim().isEmpty) {
      _message('Informe a chave de licença recebida.');
      return;
    }
    setState(() => _busy = true);
    try {
      await LicensingService().activate(farmId, _licenseKey.text);
      _licenseKey.clear();
      _loadDevices();
      _message('Licença vitalícia ativada para esta fazenda.');
    } catch (error) {
      _message(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _invite() async {
    final code = await showDialog<String>(
        context: context,
        builder: (_) => CreateInvitationDialog(
            create: (email, role) => SyncService().inviteUser(email, role)));
    if (!mounted || code == null) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Convite pronto'),
        content: SelectableText(code),
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: code));
              if (ctx.mounted) Navigator.pop(ctx);
              _message(
                  'Código copiado. Envie-o em canal privado à pessoa convidada.');
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copiar'),
          ),
        ],
      ),
    );
  }

  Future<void> _resolve(LocalRecord record, {required bool useServer}) async {
    await SyncService().resolveConflict(record, useServerVersion: useServer);
    _refresh();
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (FarmApiClient.standaloneLocalMode) {
      return ListView(
        padding: const EdgeInsets.all(18),
        children: [
          Text('Dados neste aparelho',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 10),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Modo local ativo. Máquinas, serviços e demais cadastros ficam salvos somente neste aparelho. Esta versão não sincroniza com outros dispositivos e ainda não inclui backup automático.',
              ),
            ),
          ),
        ],
      );
    }
    final user = AuthService().currentUser;
    final isServer = user?.farmId != null;
    return AnimatedBuilder(
      animation: SyncService(),
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.all(18),
          children: [
            Text('Sincronização da fazenda',
                style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 10),
            if (isServer) ...[
              _licenseCard(),
              const SizedBox(height: 10),
              if (user?.role == UserRole.admin)
                Card(
                    child: ListTile(
                        title: const Text('ID desta fazenda'),
                        subtitle: SelectableText(user?.farmId ?? '—'))),
              if (user?.role == UserRole.admin) _deviceCard(),
              if (user?.role == UserRole.admin) const SizedBox(height: 10),
              if (user?.role == UserRole.admin) _usersCard(),
              if (user?.role == UserRole.admin) const SizedBox(height: 10),
              _summaryCard(),
              const SizedBox(height: 10),
              if (user?.role == UserRole.admin) _legacyImportCard(),
              FilledButton.icon(
                onPressed: _busy ? null : _syncNow,
                icon: const Icon(Icons.sync),
                label: Text(_busy ? 'Sincronizando…' : 'Sincronizar agora'),
              ),
              if (user?.role == UserRole.admin) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                    onPressed: _invite,
                    icon: const Icon(Icons.person_add_alt_1),
                    label: const Text('Convidar usuário')),
                const SizedBox(height: 12),
                TextField(
                  controller: _licenseKey,
                  decoration: const InputDecoration(
                      labelText: 'Chave da licença vitalícia',
                      hintText: 'Cole a chave recebida após a compra'),
                ),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _activateLicense,
                  icon: const Icon(Icons.key),
                  label: const Text('Ativar licença'),
                ),
              ],
              const SizedBox(height: 16),
              Text('Fila neste aparelho',
                  style: Theme.of(context).textTheme.titleMedium),
              _queueList(),
              const SizedBox(height: 16),
              Text('Conflitos para revisar',
                  style: Theme.of(context).textTheme.titleMedium),
              _conflictList(),
            ] else ...[
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                      'Demonstração local. Os cadastros ficam neste aparelho e não entram na fila de uma fazenda até você entrar na conta dela.'),
                ),
              ),
            ],
            if (FarmApiClient.showServerConfiguration) ...[
              const SizedBox(height: 20),
              Text('Endereço privado do PC gestor',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              const Text(
                  'No emulador Android deste PC, o piloto v2 usa http://10.0.2.2:8766; o servidor anterior usa a porta 8765. No celular físico, use a URL HTTPS privada do PC gestor.'),
              const SizedBox(height: 8),
              TextField(
                controller: _url,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                    labelText: 'Endereço do servidor',
                    hintText: 'http://10.0.2.2:8766'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                  onPressed: _busy ? null : _saveUrl,
                  child: const Text('Salvar conexão')),
            ],
          ],
        );
      },
    );
  }

  Widget _legacyImportCard() => FutureBuilder<LegacyFarmDataPreview>(
        future: _legacyPreviewFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Card(
                child: ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: const Text('Cadastros antigos não puderam ser lidos'),
              subtitle: Text('${snapshot.error}'),
            ));
          }
          final preview = snapshot.data;
          if (preview == null || preview.total == 0) {
            return const SizedBox.shrink();
          }
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Cadastros antigos neste aparelho',
                        style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                        'Encontrados ${preview.total} cadastro(s): ${preview.counts.entries.map((entry) => '${entry.value} ${_moduleLabel(entry.key)}').join(', ')}.'),
                    const SizedBox(height: 6),
                    const Text(
                        'A cópia antiga será mantida. A importação só é liberada depois da sincronização inicial e se a fazenda ainda estiver vazia.'),
                    if (preview.reason case final reason?) ...[
                      const SizedBox(height: 8),
                      Text(reason,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                    ],
                    if (preview.canImport) ...[
                      const SizedBox(height: 10),
                      FilledButton.tonalIcon(
                        onPressed: _busy ? null : _importLegacyData,
                        icon: const Icon(Icons.move_to_inbox_outlined),
                        label: const Text('Importar para esta fazenda'),
                      ),
                    ],
                  ]),
            ),
          );
        },
      );

  String _moduleLabel(String module) => switch (module) {
        'machines' => 'máquinas',
        'services' => 'serviços',
        'maintenance' => 'manutenções',
        'fuel' => 'abastecimentos',
        'operators' => 'operadores',
        'implements' => 'implementos',
        'clients' => 'clientes',
        'products' => 'produtos',
        'productUsage' => 'registros de uso de produtos',
        _ => module,
      };

  Widget _licenseCard() => AnimatedBuilder(
        animation: LicensingService(),
        builder: (context, _) {
          final entitlement = LicensingService().current;
          if (entitlement == null) {
            return const Card(
                child: ListTile(title: Text('Validando teste ou licença…')));
          }
          final effectiveStatus = entitlement.effectiveStatus;
          final expired = effectiveStatus == 'expired';
          final statusColor = expired
              ? Colors.red
              : effectiveStatus == 'validation_required'
                  ? Colors.orange.shade800
                  : Colors.green;
          return Card(
            child: ListTile(
              leading: Icon(
                  expired ? Icons.lock_clock : Icons.verified_user_outlined,
                  color: statusColor),
              title: Text(effectiveStatus == 'trial'
                  ? 'Teste grátis de 30 dias'
                  : effectiveStatus == 'licensed'
                      ? 'Licença ativa'
                      : effectiveStatus == 'validation_required'
                          ? 'Validação da licença pendente'
                          : 'Somente consulta'),
              subtitle: Text(
                  '${entitlement.notice}\nAparelhos ativos: ${entitlement.activeDevices} (sem limite)\nID da fazenda: ${AuthService().currentUser?.farmId ?? "—"}'),
              isThreeLine: true,
            ),
          );
        },
      );

  Widget _deviceCard() => FutureBuilder<List<DeviceActivation>>(
        future: _devicesFuture,
        builder: (context, result) {
          if (result.hasError) {
            return Card(
                child: ListTile(
                    title: Text(
                        'Não foi possível carregar os aparelhos: ${result.error}')));
          }
          final devices = result.data ?? const [];
          if (devices.isEmpty) {
            return const Card(
                child: ListTile(title: Text('Nenhum aparelho vinculado.')));
          }
          return Card(
            child: Column(
              children: [
                const ListTile(
                    title: Text('Aparelhos desta fazenda'),
                    subtitle: Text('Quantidade de aparelhos sem limite.')),
                for (final device in devices)
                  ListTile(
                    leading: Icon(device.active
                        ? Icons.phone_android
                        : Icons.phonelink_erase_outlined),
                    title: Text(device.name),
                    subtitle: Text(device.active
                        ? 'Ativo · última conexão ${device.lastSeenAt}'
                        : 'Liberado'),
                    trailing: device.active
                        ? IconButton(
                            tooltip: 'Liberar aparelho',
                            onPressed: () => _releaseDevice(device),
                            icon: const Icon(Icons.link_off))
                        : null,
                  ),
              ],
            ),
          );
        },
      );

  Widget _usersCard() => FutureBuilder<List<Map<String, dynamic>>>(
        future: _usersFuture,
        builder: (context, result) {
          if (result.hasError) {
            return Card(
                child: ListTile(
                    title: Text(
                        'Não foi possível carregar as contas: ${result.error}')));
          }
          final users = result.data;
          if (users == null) {
            return const Card(
                child: ListTile(title: Text('Carregando contas…')));
          }
          if (users.isEmpty) {
            return const Card(
                child: ListTile(title: Text('Nenhuma conta cadastrada.')));
          }
          final currentUserId = AuthService().currentUser?.id;
          return Card(
            child: Column(
              children: [
                const ListTile(
                    title: Text('Contas da fazenda'),
                    subtitle: Text(
                        'Bloquear uma conta revoga o acesso no servidor, inclusive em sessões abertas.')),
                for (final account in users)
                  ListTile(
                    leading: Icon(account['active'] == true
                        ? Icons.person_outline
                        : Icons.person_off_outlined),
                    title: Text(account['displayName'] as String? ??
                        account['email'] as String? ??
                        'Usuário'),
                    subtitle: Text(
                        '${account['email']} · ${_roleLabel(account['role'] as String?)} · ${account['active'] == true ? 'Ativa' : 'Bloqueada'}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (account['id'] == currentUserId)
                          const Chip(label: Text('Você')),
                        IconButton(
                          tooltip: account['active'] == true
                              ? 'Bloquear conta'
                              : 'Reativar conta',
                          onPressed:
                              _busy ? null : () => _setUserAccess(account),
                          icon: Icon(account['active'] == true
                              ? Icons.block
                              : Icons.check_circle_outline),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      );

  String _roleLabel(String? role) => switch (role) {
        'admin' => 'Administrador',
        'operator' => 'Operador',
        'mechanic' => 'Mecânico',
        _ => 'Perfil desconhecido',
      };

  Widget _summaryCard() => FutureBuilder<SyncSnapshot>(
        future: SyncService().snapshot(),
        builder: (context, result) {
          final snapshot = result.data;
          final state = SyncService().state;
          final icon = switch (state) {
            SyncState.syncing => Icons.sync,
            SyncState.pending => Icons.schedule,
            SyncState.offline => Icons.cloud_off,
            SyncState.needsAttention => Icons.error_outline,
            SyncState.notConfigured => Icons.settings_ethernet,
            SyncState.idle => Icons.cloud_done_outlined,
          };
          final title = switch (state) {
            SyncState.syncing => 'Sincronizando dados…',
            SyncState.pending => 'Há registros aguardando envio',
            SyncState.offline => 'PC gestor ou VPN indisponível',
            SyncState.needsAttention => 'Há itens que precisam de atenção',
            SyncState.notConfigured => 'Conexão ainda não configurada',
            SyncState.idle => 'Dados sincronizados',
          };
          final last = snapshot?.lastSyncedAt;
          return Card(
            child: ListTile(
              leading: Icon(icon,
                  size: 30,
                  color: state == SyncState.needsAttention
                      ? Colors.deepOrange
                      : null),
              title: Text(title),
              subtitle: Text([
                'Pendentes: ${snapshot?.pending ?? 0} · Erros: ${snapshot?.errors ?? 0} · Conflitos: ${snapshot?.conflicts ?? 0}',
                if (last != null)
                  'Última sincronização: ${last.toString().split('.').first}',
                if (SyncService().message case final message?) message,
              ].join('\n')),
            ),
          );
        },
      );

  Widget _queueList() => FutureBuilder<List<SyncOutboxEntry>>(
        future: SyncService().outboxEntries(),
        builder: (context, result) {
          final rows = result.data ?? const [];
          if (rows.isEmpty) {
            return const ListTile(title: Text('Nenhum registro pendente.'));
          }
          return Column(
              children: rows.take(30).map((row) {
            final error = row.state == 'error' || row.state == 'conflict';
            return ListTile(
              dense: true,
              leading: Icon(error ? Icons.sync_problem : Icons.schedule,
                  color: error ? Colors.deepOrange : Colors.orange),
              title: Text('${row.module} · ${row.recordId}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(row.lastError ??
                  (row.state == 'sending' ? 'Enviando' : 'Aguardando conexão')),
              trailing:
                  Text(row.operation == 'delete' ? 'Exclusão' : 'Cadastro'),
            );
          }).toList());
        },
      );

  Widget _conflictList() => FutureBuilder<List<LocalRecord>>(
        future: SyncService().conflicts(),
        builder: (context, result) {
          final rows = result.data ?? const [];
          if (rows.isEmpty) {
            return const ListTile(title: Text('Nenhum conflito encontrado.'));
          }
          return Column(
              children: rows
                  .map((row) => Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${row.module} · ${row.recordId}',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                const Text(
                                    'Este registro foi alterado em mais de um aparelho. Escolha qual versão manter.'),
                                Wrap(spacing: 8, children: [
                                  TextButton(
                                      onPressed: () =>
                                          _resolve(row, useServer: true),
                                      child: const Text(
                                          'Usar versão do servidor')),
                                  FilledButton.tonal(
                                      onPressed: () =>
                                          _resolve(row, useServer: false),
                                      child: const Text(
                                          'Manter versão deste aparelho')),
                                ]),
                              ]),
                        ),
                      ))
                  .toList());
        },
      );
}
