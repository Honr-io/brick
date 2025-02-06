import 'package:brick_core/core.dart';
import 'package:brick_supabase/src/query_supabase_transformer.dart';
import 'package:brick_supabase/src/supabase_model.dart';
import 'package:brick_supabase/src/supabase_model_dictionary.dart';
import 'package:brick_supabase/src/supabase_provider_query.dart';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:supabase/supabase.dart';

/// An internal definition for remote requests.
/// In rare cases, a specific `update` or `insert` is preferable to `upsert`;
/// this enum explicitly declares the desired behavior.
enum UpsertMethod {
  /// Translates to a Supabase `.insert`
  insert,

  /// Translates to a Supabase `.update`
  update,

  /// Translates to a Supabase `.upsert`
  upsert,
}

class _AssociationInfoToUpsert{
  Map<String, dynamic> serializedInstance;
  UpsertMethod method;
  Type type;
  Query? query;
  ModelRepository<SupabaseModel>? repository;

  _AssociationInfoToUpsert({
    required this.serializedInstance,
    required this.method,
    required this.type,
    this.query,
    this.repository,
  });
}

/// Retrieves from a Supabase server
class SupabaseProvider implements Provider<SupabaseModel> {
  /// The client used to connect to the Supabase server.
  /// For some cases, like offline repositories, the offl
  final SupabaseClient client;

  /// The glue between app models and generated adapters.
  @override
  final SupabaseModelDictionary modelDictionary;

  ///
  @protected
  final Logger logger;

  /// Retrieves from a Supabase server
  SupabaseProvider(
    this.client, {
    required this.modelDictionary,
  }) : logger = Logger('SupabaseProvider');

  /// Sends a DELETE request method to the endpoint
  @override
  Future<bool> delete<TModel extends SupabaseModel>(
    TModel instance, {
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    final adapter = modelDictionary.adapterFor[TModel]!;
    final tableBuilder = client.from(adapter.supabaseTableName);
    final output = await adapter.toSupabase(instance, provider: this, repository: repository);

    final builder = adapter.uniqueFields.fold(tableBuilder.delete(), (acc, uniqueFieldName) {
      final columnName = adapter.fieldsToSupabaseColumns[uniqueFieldName]!.columnName;
      if (output.containsKey(columnName)) {
        return acc.eq(columnName, output[columnName]);
      }
      return acc;
    });

    final resp = await builder;
    return resp != null;
  }

  @override
  Future<bool> exists<TModel extends SupabaseModel>({
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    final adapter = modelDictionary.adapterFor[TModel]!;
    final queryTransformer =
        QuerySupabaseTransformer<TModel>(modelDictionary: modelDictionary, query: query);
    final builder = queryTransformer.select(client.from(adapter.supabaseTableName));

    final resp = await builder.count(CountOption.exact);
    return resp.count > 0;
  }

  @override
  Future<List<TModel>> get<TModel extends SupabaseModel>({
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    final adapter = modelDictionary.adapterFor[TModel]!;
    final queryTransformer =
        QuerySupabaseTransformer<TModel>(modelDictionary: modelDictionary, query: query);
    final builder = queryTransformer.select(client.from(adapter.supabaseTableName));

    final resp = await queryTransformer.applyQuery(builder);

    return Future.wait<TModel>(
      resp
          .map((r) => adapter.fromSupabase(r, repository: repository, provider: this))
          .toList()
          .cast<Future<TModel>>(),
    );
  }

  /// In almost all cases, use [upsert]. This method is provided for cases when a table's
  /// policy permits inserts without updates.
  Future<TModel> insert<TModel extends SupabaseModel>(
    TModel instance, {
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    final adapter = modelDictionary.adapterFor[TModel]!;
    final output = await adapter.toSupabase(instance, provider: this, repository: repository);

    final result = await recursiveAssociationUpsert(
      output,
      method: UpsertMethod.insert,
      type: TModel,
      query: query,
      repository: repository,
    ) as TModel?;

    if (result == null) {
      // Information of the exact error is not available here, but logged earlier 
      // in recursiveAssociationUpsert
      logger.finest('Failed to upsert $TModel');
      return instance;
    }
    return result;
  }

  /// In almost all cases, use [upsert]. This method is provided for cases when a table's
  /// policy permits updates without inserts.
  Future<TModel> update<TModel extends SupabaseModel>(
    TModel instance, {
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    final adapter = modelDictionary.adapterFor[TModel]!;
    final output = await adapter.toSupabase(instance, provider: this, repository: repository);

    final result = await recursiveAssociationUpsert(
      output,
      method: UpsertMethod.update,
      type: TModel,
      query: query,
      repository: repository,
    ) as TModel?;

    if (result == null) {
      // Information of the exact error is not available here, but logged earlier 
      // in recursiveAssociationUpsert
      logger.finest('Failed to upsert $TModel');
      return instance;
    }
    return result;
  }

  /// Association models are upserted recursively before the requested instance is upserted.
  /// Because it's unknown if there has been any change from the local association to the remote
  /// association, all associations and their associations are upserted on a parent's upsert.
  ///
  /// For example, given model `Room` has association `Bed` and `Bed` has association `Pillow`,
  /// when `Room` is upserted, `Pillow` is upserted and then `Bed` is upserted.
  @override
  Future<TModel> upsert<TModel extends SupabaseModel>(
    TModel instance, {
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    final adapter = modelDictionary.adapterFor[TModel]!;
    final output = await adapter.toSupabase(instance, provider: this, repository: repository);

    final result = await recursiveAssociationUpsert(
      output,
      type: TModel,
      query: query,
      repository: repository,
    ) as TModel?;

    if (result == null) {
      // Information of the exact error is not available here, but logged earlier 
      // in recursiveAssociationUpsert
      logger.finest('Failed to upsert $TModel');
      return instance;
    }
    return result;
  }

  /// Used by [recursiveAssociationUpsert], this performs the upsert to Supabase
  /// and selects the model's fields in the response.
  @protected
  Future<SupabaseModel> upsertByType(
    Map<String, dynamic> serializedInstance, {
    UpsertMethod method = UpsertMethod.upsert,
    required Type type,
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    assert(modelDictionary.adapterFor.containsKey(type), '$type not found in the model dictionary');

    final adapter = modelDictionary.adapterFor[type]!;

    final queryTransformer =
        QuerySupabaseTransformer(adapter: adapter, modelDictionary: modelDictionary, query: query);

    final builderFilter = () {
      switch (method) {
        case UpsertMethod.insert:
          return client.from(adapter.supabaseTableName).insert(serializedInstance);
        case UpsertMethod.update:
          return client.from(adapter.supabaseTableName).update(serializedInstance);
        case UpsertMethod.upsert:
          return client
              .from(adapter.supabaseTableName)
              .upsert(serializedInstance, onConflict: adapter.onConflict);
      }
    }();

    final builder = adapter.uniqueFields.fold(builderFilter, (acc, uniqueFieldName) {
      final columnName = adapter.fieldsToSupabaseColumns[uniqueFieldName]!.columnName;
      if (serializedInstance.containsKey(columnName)) {
        return acc.eq(columnName, serializedInstance[columnName]);
      }
      return acc;
    });
    final resp = await builder.select(queryTransformer.selectFields).limit(1).maybeSingle();

    if (resp == null) {
      throw StateError('Upsert of $type failed');
    }

    return adapter.fromSupabase(resp, repository: repository, provider: this);
  }

  /// Discover all SupabaseModel-like associations of a serialized instance and
  /// upsert them recursively before the requested instance is upserted.
  @protected
  Future<SupabaseModel?> recursiveAssociationUpsert(
    Map<String, dynamic> serializedInstance, {
    UpsertMethod method = UpsertMethod.upsert,
    required Type type,
    Query? query,
    ModelRepository<SupabaseModel>? repository,
  }) async {
    assert(modelDictionary.adapterFor.containsKey(type), '$type not found in the model dictionary');

    final adapter = modelDictionary.adapterFor[type]!;
    final associations = adapter.fieldsToSupabaseColumns.values
        .where((a) => a.association && a.associationType != null);

    List<_AssociationInfoToUpsert> associationsToUpsert = [];

    for (final association in associations) {
      if (!serializedInstance.containsKey(association.columnName)) {
        continue;
      }

      if (serializedInstance[association.columnName] is Map) {
        await recursiveAssociationUpsert(
          Map<String, dynamic>.from(serializedInstance[association.columnName]),
          type: association.associationType!,
          query: query,
          repository: repository,
        );
        if (association.foreignKey != null) {
          serializedInstance[association.foreignKey!] = serializedInstance[association.columnName]['id'];  /// Very bold assumption in general case
        }
        serializedInstance.remove(association.columnName);
      } else if (serializedInstance[association.columnName] is List) {
        for (var item in serializedInstance[association.columnName]) {
          associationsToUpsert.add(
            _AssociationInfoToUpsert(
              serializedInstance: Map<String, dynamic>.from(item),
              method: method,
              type: association.associationType!,
              query: query,
              repository: repository,
            ),
          );
        }
        serializedInstance.remove(association.columnName);
      } else if (association.associationIsNullable && association.foreignKey != null && serializedInstance[association.columnName] == null) {
        serializedInstance.remove(association.columnName);
        serializedInstance[association.foreignKey!] = null;
      }
    }

    SupabaseModel? result;
    try {
      result = await upsertByType(
        serializedInstance,
        method: method,
        type: type,
        query: query,
        repository: repository,
      );
    } catch (e) {
      // Just logging the error, because allowing it to be thrown here propagates it all the way up,
      // and after being thrown in the inner-most recursive call, previous calls don't attempt upsertByType
      // and, consequently, don't add the upsert to retry queue
      logger.finest('Error upserting $type: $e');
    }

    for (final association in associationsToUpsert) {
      await recursiveAssociationUpsert(
        association.serializedInstance,
        method: association.method,
        type: association.type,
        query: association.query,
        repository: association.repository,
      );
    }

    return result;
  }
}
