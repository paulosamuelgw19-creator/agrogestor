import '../licensing/plan_screen.dart';
import '../operations_v2/management_reports_screen.dart';
import 'package:flutter/material.dart';
import '../local_activation/activation_gate.dart';
import '../../app/app_theme.dart';
import '../auth/auth_service.dart';
import '../auth/user_model.dart';
import '../dashboard/dashboard_screen.dart';
import '../machines/machines_screen.dart';
import '../operators/operators_screen.dart';
import '../implements/implements_screen.dart';
import '../services/services_screen.dart';
import '../maintenance/maintenance_screen.dart';
import '../fuel/fuel_screen.dart';
import '../reports/reports_screen.dart';
import '../clients/clients_screen.dart';
import '../products/products_area.dart';
import '../sync/sync_settings_screen.dart';
import '../sync/sync_service.dart';
import '../sync/sync_notice.dart';
import '../sync/farm_api_client.dart';
import '../licensing/license_notice.dart';
import '../placeholders/module_screen.dart';
import '../operations_v2/operations_screen.dart';
import '../properties/properties_screen.dart';
import '../work/work_screen.dart';
import 'global_search.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int selected = AuthService().currentUser?.farmId != null &&
          AuthService().currentUser?.role != UserRole.admin
      ? 13
      : 0;
  int _pageRevision = 0;
  bool _syncing = false;
  bool _v2Available = false;

  @override
  void initState() {
    super.initState();
    _syncing = SyncService().state == SyncState.syncing;
    SyncService().addListener(_onSyncChanged);
    _checkCapabilities();
  }

  @override
  void dispose() {
    SyncService().removeListener(_onSyncChanged);
    super.dispose();
  }

  void _onSyncChanged() {
    final syncingNow = SyncService().state == SyncState.syncing;
    if (_syncing && !syncingNow && mounted) {
      setState(() => _pageRevision++);
      _checkCapabilities();
    }
    _syncing = syncingNow;
  }

  Future<void> _checkCapabilities() async {
    final user = AuthService().currentUser?.id;
    final token = AuthService().accessToken;
    if (user == null || token == null) return;
    try {
      final capabilities =
          await FarmApiClient.instance.v2('GET', '/capabilities');
      if (mounted &&
          AuthService().currentUser?.id == user &&
          AuthService().accessToken == token) {
        setState(() => _v2Available = capabilities['propertyCatalog'] == true);
      }
    } catch (_) {}
  }

  Widget _catalogPage(OperationsSection section, Widget previous) =>
      Column(children: [
        Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
                icon: const Icon(Icons.history),
                label: const Text('Consultar registros anteriores'),
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => previous)))),
        Expanded(child: OperationsScreen(section: section))
      ]);

  Future<void> _openSearch() async {
    final hit = await showSearch<SearchHit?>(
      context: context,
      delegate: GlobalSearchDelegate(),
    );
    if (hit != null && mounted) {
      setState(() => selected =
          FarmApiClient.standaloneLocalMode && hit.destination == 2
              ? 11
              : hit.destination);
    }
  }

  static const allItems =
      <({String label, IconData icon, List<UserRole> roles})>[
    (
      label: 'Visão geral',
      icon: Icons.grid_view_rounded,
      roles: [UserRole.admin, UserRole.operator, UserRole.mechanic],
    ),
    (
      label: 'Máquinas',
      icon: Icons.agriculture_rounded,
      roles: [UserRole.admin, UserRole.operator, UserRole.mechanic],
    ),
    (
      label: 'Tarefas',
      icon: Icons.assignment_rounded,
      roles: [UserRole.admin, UserRole.operator],
    ),
    (
      label: 'Oficina',
      icon: Icons.build_circle_outlined,
      roles: [UserRole.admin, UserRole.mechanic],
    ),
    (
      label: 'Funcionários',
      icon: Icons.engineering_rounded,
      roles: [UserRole.admin],
    ),
    (
      label: 'Implementos',
      icon: Icons.handyman_outlined,
      roles: [UserRole.admin, UserRole.operator],
    ),
    (
      label: 'Combustível',
      icon: Icons.local_gas_station_rounded,
      roles: [UserRole.admin, UserRole.operator],
    ),
    (
      label: 'Produtos e insumos',
      icon: Icons.inventory_2_outlined,
      roles: [UserRole.admin, UserRole.operator],
    ),
    (
      label: 'Clientes',
      icon: Icons.groups_rounded,
      roles: [UserRole.admin],
    ),
    (
      label: 'Relatórios',
      icon: Icons.bar_chart_rounded,
      roles: [UserRole.admin],
    ),
    (
      label: 'Sincronização',
      icon: Icons.sync_rounded,
      roles: [UserRole.admin, UserRole.operator, UserRole.mechanic],
    ),
    (
      label: 'Operações',
      icon: Icons.assignment_turned_in_outlined,
      roles: [UserRole.admin, UserRole.operator, UserRole.mechanic],
    ),
    (
      label: 'Propriedades e Talhões',
      icon: Icons.landscape_outlined,
      roles: [UserRole.admin, UserRole.operator, UserRole.mechanic],
    ),
    (
      label: 'Tarefas e oficina',
      icon: Icons.fact_check_outlined,
      roles: [UserRole.admin, UserRole.operator, UserRole.mechanic],
    ),
    (
      label: 'Meu plano',
      icon: Icons.assignment_outlined,
      roles: [UserRole.admin]
    ),
  ];

  List<({String label, IconData icon, List<UserRole> roles})> _filteredItems(
      UserRole role) {
    if (AuthService().currentUser?.farmId != null && role != UserRole.admin) {
      return allItems
          .where((item) => (role == UserRole.mechanic
                  ? ['Tarefas e oficina', 'Sincronização']
                  : [
                      'Tarefas e oficina',
                      'Sincronização',
                      'Operações',
                      'Máquinas',
                      'Propriedades e Talhões',
                    ])
              .contains(item.label))
          .toList();
    }
    return allItems
        .where((item) =>
            item.roles.contains(role) &&
            !(FarmApiClient.standaloneLocalMode &&
                ['Tarefas', 'Meu plano', 'Clientes'].contains(item.label)) &&
            !(role == UserRole.admin && item.label == 'Tarefas e oficina'))
        .toList();
  }

  Widget _getPageForIndex(int index) {
    if (AuthService().currentUser?.farmId != null &&
        AuthService().currentUser?.role != UserRole.admin &&
        index != 13 &&
        index != 10 &&
        index != 12 &&
        index != 1) {
      return AuthService().currentUser?.role == UserRole.mechanic
          ? const WorkScreen(section: 'orders')
          : const OperationsScreen();
    }
    switch (index) {
      case 0:
        if (AuthService().currentUser?.farmId != null) {
          return const WorkScreen();
        }
        return DashboardScreen(
          onNavigate: (destination) => setState(() => selected =
              FarmApiClient.standaloneLocalMode && destination == 2
                  ? 11
                  : destination),
        );
      case 1:
        if (AuthService().currentUser?.role == UserRole.operator &&
            AuthService().currentUser?.farmId != null) {
          return const OperationsScreen(section: OperationsSection.fleet);
        }
        if (_v2Available) {
          return _catalogPage(OperationsSection.fleet, const MachinesScreen());
        }
        return const MachinesScreen();
      case 2:
        if (AuthService().currentUser?.farmId != null) {
          return const WorkScreen(section: 'tasks');
        }
        return const ServicesScreen();
      case 3:
        if (AuthService().currentUser?.farmId != null) {
          return const WorkScreen(section: 'orders');
        }
        return const MaintenanceScreen();
      case 4:
        if (AuthService().currentUser?.farmId != null) {
          return const WorkScreen(section: 'team');
        }
        return const OperatorsScreen();
      case 5:
        return const ImplementsScreen();
      case 6:
        if (_v2Available) {
          return _catalogPage(OperationsSection.refuelings, const FuelScreen());
        }
        return const FuelScreen();
      case 7:
        return ProductsArea(
          usageOnly: AuthService().currentUser?.role == UserRole.operator,
        );
      case 8:
        if (_v2Available) {
          return _catalogPage(
              OperationsSection.catalogs, const ClientsScreen());
        }
        return const ClientsScreen();
      case 9:
        if (_v2Available) {
          return const ManagementReportsScreen(embedded: true);
        }
        return const ReportsScreen();
      case 10:
        return const SyncSettingsScreen();
      case 11:
        return FarmApiClient.standaloneLocalMode
            ? const ServicesScreen()
            : const OperationsScreen();
      case 12:
        return const PropertiesScreen();
      case 13:
        return WorkScreen(
            section: AuthService().currentUser?.role == UserRole.mechanic
                ? 'orders'
                : 'tasks');
      case 14:
        return const PlanScreen();
      default:
        return ModuleScreen(
          title: allItems[selected].label,
          icon: allItems[selected].icon,
        );
    }
  }

  String _profileLabel(String label, UserRole role) =>
      label == 'Tarefas e oficina'
          ? role == UserRole.operator
              ? 'Minhas tarefas'
              : role == UserRole.mechanic
                  ? 'Oficina'
                  : 'Tarefas'
          : label;

  void _showUserDialog(BuildContext context, AppUser user) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Perfil do Usuário'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CircleAvatar(
                backgroundColor: AppTheme.primary,
                child: Text(user.name.substring(0, 1).toUpperCase(),
                    style: const TextStyle(color: Colors.white)),
              ),
              title: Text(user.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              subtitle: Text(user.email,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
            const Divider(),
            const SizedBox(height: 8),
            Text('Nível de Acesso:',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 4),
            Chip(
              avatar: Icon(
                user.role == UserRole.admin
                    ? Icons.admin_panel_settings
                    : user.role == UserRole.operator
                        ? Icons.engineering
                        : Icons.build,
                size: 16,
              ),
              label:
                  Text(user.role.label, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Navigator.pop(ctx);
              AuthService().logout();
            },
            icon: const Icon(Icons.logout, color: Colors.red),
            label: const Text('Sair da conta',
                style: TextStyle(color: Colors.red)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService().currentUser ??
        const AppUser(
          id: 'admin',
          name: 'Administrador',
          email: 'admin@agrogestor.com',
          role: UserRole.admin,
        );

    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 900 && box.maxHeight >= 600;
        final compact = box.maxWidth < 440;
        final titleHeight =
            MediaQuery.textScalerOf(context).scale(20) * 2.4 + 12;
        return Scaffold(
          appBar: AppBar(
            toolbarHeight: titleHeight < 56 ? 56 : titleHeight,
            title: Text(
              wide
                  ? 'AgroGestor'
                  : FarmApiClient.standaloneLocalMode && selected == 10
                      ? 'Dados locais'
                      : _profileLabel(allItems[selected].label, user.role),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
            ),
            actions: [
              if (compact)
                PopupMenuButton<String>(
                  tooltip: 'Mais opções',
                  onSelected: (value) {
                    if (value == 'search') {
                      _openSearch();
                    } else {
                      SyncService().syncNow();
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'search', child: Text('Buscar')),
                    if (!FarmApiClient.standaloneLocalMode)
                      const PopupMenuItem(
                          value: 'sync', child: Text('Sincronizar agora')),
                  ],
                ),
              if (!compact)
                IconButton(
                  tooltip: 'Buscar',
                  onPressed: _openSearch,
                  icon: const Icon(Icons.search),
                ),
              if (!compact && !FarmApiClient.standaloneLocalMode)
                IconButton(
                  tooltip: 'Sincronizar agora',
                  onPressed: () => SyncService().syncNow(),
                  icon: const Icon(Icons.sync),
                ),
              IconButton(
                tooltip: 'Perfil (${user.name})',
                onPressed: () => _showUserDialog(context, user),
                icon: CircleAvatar(
                  radius: 14,
                  backgroundColor: AppTheme.primary,
                  child: Text(
                    user.name.substring(0, 1).toUpperCase(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
          drawer: wide ? null : Drawer(child: _menu(context, false, user)),
          body: Column(
            children: [
              const LocalActivationNotice(),
              LicenseNotice(user: user),
              if (!FarmApiClient.standaloneLocalMode)
                AnimatedBuilder(
                    animation: SyncService(),
                    builder: (context, _) => SyncNotice(
                        state: SyncService().state,
                        message: SyncService().message)),
              Expanded(
                child: Row(
                  children: [
                    if (wide)
                      SizedBox(width: 250, child: _menu(context, true, user)),
                    Expanded(
                      child: KeyedSubtree(
                        key: ValueKey('$selected-${[
                          0,
                          11,
                          13
                        ].contains(selected) ? 0 : _pageRevision}'),
                        child: _getPageForIndex(selected),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: wide
              ? null
              : user.farmId != null && user.role != UserRole.admin
                  ? NavigationBar(
                      selectedIndex: user.role == UserRole.mechanic
                          ? (selected == 10 ? 1 : 0)
                          : selected == 11
                              ? 1
                              : selected == 1
                                  ? 2
                                  : selected == 12
                                      ? 3
                                      : 0,
                      onDestinationSelected: (index) => setState(() =>
                          selected = (user.role == UserRole.mechanic
                              ? const [13, 10]
                              : const [13, 11, 1, 12])[index]),
                      destinations: [
                          NavigationDestination(
                              icon: const Icon(Icons.fact_check_outlined),
                              label: user.role == UserRole.mechanic
                                  ? 'Oficina'
                                  : 'Tarefas'),
                          if (user.role == UserRole.mechanic)
                            const NavigationDestination(
                                icon: Icon(Icons.sync), label: 'Sincronização'),
                          if (user.role != UserRole.mechanic)
                            const NavigationDestination(
                                icon: Icon(Icons.assignment_rounded),
                                label: 'Operações'),
                          if (user.role != UserRole.mechanic)
                            const NavigationDestination(
                                icon: Icon(Icons.agriculture_outlined),
                                label: 'Máquinas'),
                          if (user.role != UserRole.mechanic)
                            const NavigationDestination(
                                icon: Icon(Icons.landscape_outlined),
                                label: 'Propriedades')
                        ])
                  : NavigationBar(
                      selectedIndex: selected == 11
                          ? 2
                          : selected >= 0 && selected <= 3
                              ? selected
                              : 0,
                      onDestinationSelected: (index) =>
                          setState(() => selected = const [0, 1, 11, 3][index]),
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.grid_view_rounded),
                          label: 'Início',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.agriculture_rounded),
                          label: 'Máquinas',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.assignment_rounded),
                          label: 'Operações',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.build_circle_outlined),
                          label: 'Oficina',
                        ),
                      ],
                    ),
        );
      },
    );
  }

  Widget _menu(BuildContext context, bool expanded, AppUser user) {
    final menuItems = _filteredItems(user.role);

    return Container(
      color: AppTheme.forest,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 16, 20),
              child: Row(
                children: [
                  const Icon(
                    Icons.agriculture,
                    color: Color(0xFFA5D6A7),
                    size: 34,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'AgroGestor',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          user.role.label.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFFB5CABC),
                            fontSize: 10,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: menuItems.length,
                itemBuilder: (context, i) {
                  final item = menuItems[i];
                  final originalIndex = allItems.indexOf(item);
                  final active = selected == originalIndex;

                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    child: ListTile(
                      selected: active,
                      selectedTileColor: Colors.white.withValues(alpha: .14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      leading: Icon(
                        item.icon,
                        color:
                            active ? const Color(0xFFA5D6A7) : Colors.white70,
                      ),
                      title: Text(
                        FarmApiClient.standaloneLocalMode &&
                                item.label == 'Sincronização'
                            ? 'Dados locais'
                            : _profileLabel(item.label, user.role),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight:
                              active ? FontWeight.w700 : FontWeight.w400,
                        ),
                      ),
                      onTap: () {
                        setState(() => selected = originalIndex);
                        if (!expanded) Navigator.of(context).pop();
                      },
                    ),
                  );
                },
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.white70),
              title: const Text('Encerrar Sessão',
                  style: TextStyle(color: Colors.white70)),
              onTap: () {
                if (!expanded) Navigator.of(context).pop();
                AuthService().logout();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
