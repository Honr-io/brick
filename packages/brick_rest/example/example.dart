import 'package:brick_core/core.dart';
import '../lib/rest.dart';

/// This class and code is always generated.
/// It is included here as an illustration.
/// Rest adapters are generated by domains that utilize the brick_rest_build package,
/// such as brick_offline_first_with_rest_build
class UserAdapter extends RestAdapter<User> {
  final fromKey = 'users';
  final toKey = 'user';

  fromRest(data, {provider, repository}) async {
    return User(
      name: data['name'],
    );
  }

  toRest(instance, {provider, repository}) async {
    return {
      'name': instance.name,
    };
  }

  restEndpoint({query, instance}) => "/users";
}

/// This value is always generated.
/// It is included here as an illustration.
/// Import it from `lib/app/brick.g.dart` in your application.
final dictionary = RestModelDictionary({
  User: UserAdapter(),
});

/// A model is unique to the end implementation (e.g. a Flutter app)
class User extends RestModel {
  final String name;

  User({
    this.name,
  });
}

class MyRepository extends SingleProviderRepository<RestModel> {
  MyRepository(String baseApiUrl)
      : super(
          RestProvider(
            baseApiUrl,
            modelDictionary: dictionary,
          ),
        );
}

void main() async {
  final repository = MyRepository('http://localhost:8080');

  final users = await repository.get<User>();
  print(users);
}
