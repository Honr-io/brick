import 'package:brick_sqlite/src/db/migration_commands/migration_command.dart';


class CustomCommand extends MigrationCommand {
  final String _statement;

  const CustomCommand(this._statement);

  @override
  String get statement => (_statement.toLowerCase().contains('insert') || 
        _statement.toLowerCase().contains('update') || 
        _statement.toLowerCase().contains('delete'))
    ? _statement
    : throw ArgumentError('CustomCommand statement must contain INSERT, UPDATE, or DELETE');

  @override
  String get forGenerator => _statement;
}
