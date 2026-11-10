import 'package:flutter_test/flutter_test.dart';
import 'package:agrogestao/features/sync/collection_changes.dart';
import 'package:agrogestao/features/sync/sync_errors.dart';

void main() {
  const original = {'id': 'a', 'name': 'Trator'};
  const edited = {'id': 'a', 'name': 'Trator editado'};
  const remote = {'id': 'a', 'name': 'Mudou no outro aparelho'};

  test('preserva registros recebidos depois de abrir a tela', () {
    final changes = CollectionChanges.plan(
      previous: {'a': original},
      incoming: {'a': edited},
      current: {
        'a': original,
        'b': {'id': 'b', 'name': 'Novo remoto'}
      },
    );
    expect(changes.upserts.keys, ['a']);
    expect(changes.deletes, isEmpty);
  });

  test('preserva edição remota em registro não alterado pelo usuário', () {
    final changes = CollectionChanges.plan(
      previous: {'a': original},
      incoming: {
        'a': original,
        'b': {'id': 'b'}
      },
      current: {'a': remote},
    );
    expect(changes.upserts.keys, ['b']);
    expect(changes.deletes, isEmpty);
  });

  test('recusa sobrescrever uma edição recebida durante o formulário', () {
    expect(
        () => CollectionChanges.plan(
              previous: {'a': original},
              incoming: {'a': edited},
              current: {'a': remote},
            ),
        throwsA(isA<SyncConflictWriteBlocked>()));
  });

  test('recusa excluir um registro alterado remotamente', () {
    expect(
        () => CollectionChanges.plan(
              previous: {'a': original},
              incoming: {},
              current: {'a': remote},
            ),
        throwsA(isA<SyncConflictWriteBlocked>()));
  });

  test('exclusão intencional afeta somente o registro visto na tela', () {
    final changes = CollectionChanges.plan(
      previous: {'a': original},
      incoming: {},
      current: {
        'a': original,
        'b': {'id': 'b'}
      },
    );
    expect(changes.deletes, {'a'});
    expect(changes.upserts, isEmpty);
  });

  test('não ressuscita exclusão remota nem sobrescreve ID já existente', () {
    expect(
        () => CollectionChanges.plan(
              previous: {'a': original},
              incoming: {'a': edited},
              current: {},
              tombstones: {'a'},
            ),
        throwsA(isA<SyncConflictWriteBlocked>()));
    expect(
        () => CollectionChanges.plan(
              previous: {},
              incoming: {'a': edited},
              current: {'a': original},
            ),
        throwsA(isA<SyncConflictWriteBlocked>()));
  });

  test('não permite alteração de registro em conflito', () {
    expect(
        () => CollectionChanges.plan(
              previous: {'a': original},
              incoming: {'a': edited},
              current: {'a': original},
              conflicts: {'a'},
            ),
        throwsA(isA<SyncConflictWriteBlocked>()));
  });

  test('ordem de campos JSON não cria alteração falsa', () {
    final changes = CollectionChanges.plan(
      previous: {'a': original},
      incoming: {
        'a': {'name': 'Trator', 'id': 'a'}
      },
      current: {'a': remote},
    );
    expect(changes.upserts, isEmpty);
  });
}
