import 'package:brick_sqlite/src/db/migration_commands/migration_command.dart';


class CustomCommand extends MigrationCommand {
  final String _statement;

  const CustomCommand(this._statement);

  @override
  String get statement => _statement;

  @override
  String get forGenerator => _statement;
}
