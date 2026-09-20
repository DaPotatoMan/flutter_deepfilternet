/// Log levels accepted by the platform implementations.
enum DeepFilterNetLogLevel {
  error,
  warn,
  info,
  debug,
  trace,
}

/// Runs an asynchronous action once and returns the same future on later calls.
final class Once<T>(final Future<T> Function() _action) {
  Future<T>? _result;

  /// Whether this action has been invoked.
  bool get isInvoked => _result != null;

  Future<T> call() => _result ??= _action();
}

/// A value that must be set before it can be read.
final class Required<T>({required final Never Function() onThrow}) {
  late T _value;
  bool _isSet = false;

  bool get isSet => _isSet;
  T get value => _isSet ? _value : onThrow();

  void set(T value) {
    _value = value;
    _isSet = true;
  }

  void setOnce(T value) {
    if (!isSet) set(value);
  }
}
