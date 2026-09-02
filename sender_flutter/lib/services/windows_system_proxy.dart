import 'dart:io';

/// The manual proxy configured in Windows' Internet Settings.
class WindowsSystemProxy {
  const WindowsSystemProxy({
    this.httpServer,
    this.httpsServer,
    this.bypass = const <String>[],
  });

  /// Endpoint for plain HTTP, with a scheme, e.g. `http://127.0.0.1:10808`.
  final String? httpServer;

  /// Endpoint for HTTPS, null when `ProxyServer` names one only for HTTP --
  /// WinINET leaves HTTPS direct in that case, so we must not invent a proxy.
  final String? httpsServer;

  /// Raw `ProxyOverride` entries, still in WinINET syntax.
  final List<String> bypass;
}

const String _localToken = '<local>';

const List<String> _proxyEnvironmentNames = <String>[
  'HTTP_PROXY',
  'http_proxy',
  'HTTPS_PROXY',
  'https_proxy',
  'ALL_PROXY',
  'all_proxy',
];

/// True when the parent environment already names a proxy, in which case the
/// user's explicit choice wins over whatever Windows has configured.
bool hasExplicitProxyEnvironment(Map<String, String> environment) =>
    _proxyEnvironmentNames.any(
      (String name) => (environment[name] ?? '').trim().isNotEmpty,
    );

/// Extra environment for the yt-dlp child process so it honours the Windows
/// system proxy.
///
/// yt-dlp runs on CPython, whose `urllib.request.getproxies()` is
/// `getproxies_environment() or getproxies_registry()`. `getproxies_environment`
/// treats `no_proxy` as a proxy entry (it matches the `_proxy` suffix test), so
/// a machine that has only `NO_PROXY` set yields a non-empty, truthy map and the
/// registry lookup is never reached -- the system proxy is silently ignored.
/// Injecting the proxy into the child environment sidesteps that. The bypass is
/// preserved by deciding here, per host, before injecting -- not by the
/// environment, which deliberately carries an empty `no_proxy` so CPython
/// applies no second, uncontrolled bypass of its own.
Map<String, String> ytDlpProxyEnvironment({
  required Map<String, String> parentEnvironment,
  required WindowsSystemProxy? systemProxy,
  required String targetHost,
  bool targetIsHttp = false,
}) {
  if (systemProxy == null) return const <String, String>{};
  if (hasExplicitProxyEnvironment(parentEnvironment)) {
    return const <String, String>{};
  }
  // The bypass decision is made here, per host, rather than by handing the list
  // to `no_proxy`. WinINET's syntax is strictly richer: it accepts `10.*` and
  // `*.corp.example`, whereas CPython's proxy_bypass_environment only does
  // exact and suffix matching, so those entries would be silently inert and
  // intranet requests would be tunnelled to an external proxy.
  if (targetHost.trim().isEmpty) return const <String, String>{};
  // Honour the caller's own no_proxy too. It is not a proxy *server* setting so
  // it does not suppress injection, but discarding it would tunnel a host the
  // user had explicitly excluded -- and before this feature existed, a bare
  // NO_PROXY was precisely what kept everything direct.
  final List<String> bypass = <String>[
    ...systemProxy.bypass,
    // CPython's no_proxy matches by suffix, so mirror that with an extra
    // wildcard form rather than letting the exact-match rule narrow it. A bare
    // `*` only means "everything" when it is the whole value; as a list member
    // CPython matches nothing, so it is dropped rather than fed to the glob.
    for (final String entry in _noProxyEntries(parentEnvironment))
      ...<String>[entry, '*.$entry'],
  ];
  if (shouldBypassProxy(targetHost, bypass)) {
    return const <String, String>{};
  }
  final String? httpServer = systemProxy.httpServer;
  final String? httpsServer = systemProxy.httpsServer;
  if (httpServer == null && httpsServer == null) return const <String, String>{};
  // An `http=`-only WinINET config leaves HTTPS direct. Injecting nothing at
  // all is the way to reproduce that for an https page, because omitting
  // HTTPS_PROXY does NOT achieve it: yt-dlp copies the http proxy onto https,
  // and would then send CONNECT to a proxy that may not speak it.
  if (httpsServer == null && !targetIsHttp) return const <String, String>{};
  return <String, String>{
    'HTTP_PROXY': ?httpServer,
    // For a plain-http page under an http-only proxy, still guard any https
    // sub-request with yt-dlp's "no proxy for this scheme" sentinel. It is an
    // internal constant rather than documented CLI surface, so it is only a
    // second line of defence -- the check above is what carries the https case.
    'HTTPS_PROXY': httpsServer ?? '__noproxy__',
    // The bypass decision was already made above, so clear any inherited
    // no_proxy: a broad value (`*`, `.com`) would otherwise apply a second,
    // uncontrolled bypass inside CPython and quietly defeat the proxy. Both
    // cases are emitted because the child environment merge is case-sensitive.
    'NO_PROXY': '',
    'no_proxy': '',
  };
}

List<String> _noProxyEntries(Map<String, String> environment) {
  final String raw =
      (environment['NO_PROXY'] ?? environment['no_proxy'] ?? '').trim();
  if (raw == '*') return const <String>['*'];
  return raw
      .split(',')
      .map((String entry) => entry.trim().replaceFirst(RegExp(r'^\.'), ''))
      .where((String entry) => entry.isNotEmpty && entry != '*')
      .toList(growable: false);
}

/// WinINET bypass matching for [host] against a parsed `ProxyOverride` list.
bool shouldBypassProxy(String host, List<String> bypass) {
  final String target = host.trim().toLowerCase();
  if (target.isEmpty) return false;
  for (final String raw in bypass) {
    final String entry = raw.trim().toLowerCase();
    if (entry.isEmpty) continue;
    if (entry == _localToken) {
      // `<local>` means "any host name without a dot", plus the loopback names
      // Windows always treats as local.
      if (!target.contains('.') ||
          target == 'localhost' ||
          target == '::1' ||
          target.startsWith('127.')) {
        return true;
      }
      continue;
    }
    if (_matchesBypassEntry(target, entry)) return true;
  }
  return false;
}

/// WinINET glob match: `*` spans any run of characters, `?` exactly one.
///
/// Written as a two-pointer walk rather than a translated RegExp on purpose.
/// `ProxyOverride` is registry data and the host comes from a pasted URL, and
/// joining escaped segments with `.*` backtracks catastrophically on entries
/// like `*a*a*a*a*z` -- seconds to minutes, on the UI isolate. This is linear.
///
/// Note there is no implicit suffix match: WinINET does not treat `corp.example`
/// as covering `a.corp.example` (which is why bypass lists are written with a
/// leading `*.`). Adding one here would diverge from the browser and, with a
/// bare entry like `com`, silently bypass the proxy for everything under it.
bool _matchesBypassEntry(String host, String entry) {
  int hostIndex = 0;
  int entryIndex = 0;
  int starEntry = -1;
  int starHost = 0;
  while (hostIndex < host.length) {
    // '*' is tested first: a host may itself contain '*' (Uri.host permits it),
    // and matching it literally would consume the wildcard and lose the
    // backtrack point.
    if (entryIndex < entry.length && entry[entryIndex] == '*') {
      starEntry = entryIndex;
      starHost = hostIndex;
      entryIndex += 1;
    } else if (entryIndex < entry.length &&
        (entry[entryIndex] == '?' || entry[entryIndex] == host[hostIndex])) {
      hostIndex += 1;
      entryIndex += 1;
    } else if (starEntry >= 0) {
      // Backtrack to the last '*' and let it consume one more character.
      entryIndex = starEntry + 1;
      starHost += 1;
      hostIndex = starHost;
    } else {
      return false;
    }
  }
  while (entryIndex < entry.length && entry[entryIndex] == '*') {
    entryIndex += 1;
  }
  return entryIndex == entry.length;
}

/// Parses `reg query "...\Internet Settings"` output.
///
/// Returns null when no usable manual proxy is configured. A PAC script
/// (`AutoConfigURL`) is deliberately not honoured: evaluating it needs a
/// JavaScript engine, and guessing at it would be worse than going direct.
WindowsSystemProxy? parseWindowsProxyRegistry(String registryOutput) {
  final Map<String, String> values = <String, String>{};
  for (final String line in registryOutput.split(RegExp(r'\r?\n'))) {
    final Match? match = RegExp(
      r'^\s*(\S+)\s+REG_(?:SZ|DWORD|EXPAND_SZ)\s+(.*)$',
    ).firstMatch(line);
    if (match != null) {
      values[match.group(1)!.toLowerCase()] = match.group(2)!.trim();
    }
  }
  // WinINET prefers a PAC script when one is configured, so honouring the
  // manual proxy here would route yt-dlp differently from the rest of the
  // system. Evaluating PAC needs a JavaScript engine, so go direct instead.
  if ((values['autoconfigurl'] ?? '').isNotEmpty) return null;
  final String enable = values['proxyenable'] ?? '';
  final int enabled = enable.startsWith('0x')
      ? int.tryParse(enable.substring(2), radix: 16) ?? 0
      : int.tryParse(enable) ?? 0;
  if (enabled == 0) return null;
  final String server = values['proxyserver'] ?? '';
  if (server.isEmpty) return null;
  final (String?, String?) endpoints = _endpointsFor(server);
  final String? httpEndpoint = endpoints.$1;
  final String? httpsEndpoint = endpoints.$2;
  if (httpEndpoint == null && httpsEndpoint == null) return null;
  return WindowsSystemProxy(
    httpServer: httpEndpoint,
    httpsServer: httpsEndpoint,
    bypass: _parseBypass(values['proxyoverride'] ?? ''),
  );
}

/// `ProxyServer` is either a bare `host:port` covering every protocol, or a
/// per-protocol list such as `http=host:80;https=host:443`.
(String?, String?) _endpointsFor(String proxyServer) {
  if (!proxyServer.contains('=')) {
    final String? shared = _withScheme(proxyServer);
    return (shared, shared);
  }
  String? httpEndpoint;
  String? httpsEndpoint;
  for (final String part in proxyServer.split(';')) {
    final int separator = part.indexOf('=');
    if (separator <= 0) continue;
    final String scheme = part.substring(0, separator).trim().toLowerCase();
    final String value = part.substring(separator + 1).trim();
    if (value.isEmpty) continue;
    if (scheme == 'https') httpsEndpoint = _withScheme(value);
    if (scheme == 'http') httpEndpoint = _withScheme(value);
  }
  return (httpEndpoint, httpsEndpoint);
}

String? _withScheme(String endpoint) {
  final String trimmed = endpoint.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.contains('://')) return trimmed;
  // WinINET stores a bare host:port and treats it as an HTTP proxy.
  return 'http://$trimmed';
}

/// Splits `ProxyOverride` while keeping WinINET syntax intact -- wildcards and
/// `<local>` are interpreted by [shouldBypassProxy], not rewritten here.
List<String> _parseBypass(String proxyOverride) => proxyOverride
    .split(RegExp(r'[;,]'))
    .map((String entry) => entry.trim())
    .where((String entry) => entry.isNotEmpty)
    .toList(growable: false);

WindowsSystemProxy? _cachedProxy;
bool _proxyCacheValid = false;

/// Drops the cached registry read; for tests and for a settings change.
void resetWindowsSystemProxyCache() {
  _proxyCacheValid = false;
  _cachedProxy = null;
}

/// Reads the manual proxy from the current user's Internet Settings.
///
/// Cached, because this spawns a process and every resolve would otherwise pay
/// for it. Returns null on any failure; a missing proxy must never block
/// resolution.
Future<WindowsSystemProxy?> readWindowsSystemProxy() async {
  if (!Platform.isWindows) return null;
  if (_proxyCacheValid) return _cachedProxy;
  try {
    final String systemRoot =
        Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final ProcessResult result = await Process.run(
      '$systemRoot\\System32\\reg.exe',
      <String>[
        'query',
        r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
      ],
      runInShell: false,
    ).timeout(const Duration(seconds: 5));
    _cachedProxy = result.exitCode == 0
        ? parseWindowsProxyRegistry(result.stdout.toString())
        : null;
    _proxyCacheValid = true;
    return _cachedProxy;
  } on Object {
    // Cache the failure too. A machine where reg.exe hangs would otherwise pay
    // the full timeout on every single resolve.
    _cachedProxy = null;
    _proxyCacheValid = true;
    return null;
  }
}
