import 'package:flutter_test/flutter_test.dart';
import 'package:lan_media_cast_sender/services/windows_system_proxy.dart';
import 'package:lan_media_cast_sender/services/yt_dlp_resolver.dart';

const String _enabledRegistry = '''
HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:10808
    ProxyOverride    REG_SZ    *.corp.example;10.*;<local>
    User Agent    REG_SZ    Mozilla/4.0 (compatible; MSIE 8.0)
''';

void main() {
  group('parseWindowsProxyRegistry', () {
    test('reads an enabled manual proxy and keeps WinINET bypass syntax', () {
      final WindowsSystemProxy proxy = parseWindowsProxyRegistry(
        _enabledRegistry,
      )!;
      // WinINET stores a bare host:port and means an HTTP proxy by it.
      expect(proxy.httpServer, 'http://127.0.0.1:10808');
      expect(proxy.httpsServer, 'http://127.0.0.1:10808');
      // Wildcards must survive parsing; they are interpreted at match time.
      expect(proxy.bypass, <String>['*.corp.example', '10.*', '<local>']);
    });

    test('ignores value names containing spaces', () {
      // `User Agent` lives in the same key and must never be mistaken for one
      // of the proxy values.
      expect(parseWindowsProxyRegistry(_enabledRegistry)!.httpServer, isNotNull);
    });

    test('returns null when the proxy is switched off', () {
      expect(
        parseWindowsProxyRegistry(_enabledRegistry.replaceAll('0x1', '0x0')),
        isNull,
      );
    });

    test('prefers going direct when a PAC script is configured', () {
      // WinINET gives PAC precedence over the manual proxy, so honouring the
      // manual entry here would route yt-dlp differently from the browser.
      expect(
        parseWindowsProxyRegistry('''
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    127.0.0.1:10808
    AutoConfigURL    REG_SZ    http://wpad/wpad.dat
'''),
        isNull,
      );
    });

    test('keeps per-protocol endpoints apart', () {
      final WindowsSystemProxy proxy = parseWindowsProxyRegistry('''
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http=10.0.0.1:80;https=10.0.0.2:443
''')!;
      expect(proxy.httpServer, 'http://10.0.0.1:80');
      expect(proxy.httpsServer, 'http://10.0.0.2:443');
    });

    test('an http-only ProxyServer leaves httpsServer null', () {
      // Must come from the parser, not a hand-built object: the fallback that
      // used to copy http onto https lives here.
      final WindowsSystemProxy proxy = parseWindowsProxyRegistry('''
    ProxyEnable    REG_DWORD    0x1
    ProxyServer    REG_SZ    http=10.0.0.1:80
''')!;
      expect(proxy.httpServer, 'http://10.0.0.1:80');
      expect(proxy.httpsServer, isNull);
    });

    test('the cached read can be reset', () async {
      // Guards the cache-invalidation hook against becoming dead code.
      resetWindowsSystemProxyCache();
      final WindowsSystemProxy? first = await readWindowsSystemProxy();
      resetWindowsSystemProxyCache();
      final WindowsSystemProxy? second = await readWindowsSystemProxy();
      expect(first?.httpServer, second?.httpServer);
    });
  });

  group('shouldBypassProxy edge cases', () {
    test('a host containing * does not consume the wildcard', () {
      // Uri.host permits '*', and testing the literal branch before the '*'
      // branch made the star match itself and lose the backtrack point.
      expect(shouldBypassProxy('a*b.example', <String>['*.example']), isTrue);
      expect(shouldBypassProxy('a*b.example', <String>['a*b.example']), isTrue);
    });
  });

  group('shouldBypassProxy', () {
    test('matches wildcard entries the way WinINET does', () {
      // These are exactly the forms CPython's no_proxy cannot express, which is
      // why the decision is made here instead of being delegated to it.
      expect(shouldBypassProxy('sub.corp.example', <String>['*.corp.example']), isTrue);
      expect(shouldBypassProxy('10.1.2.3', <String>['10.*']), isTrue);
      expect(shouldBypassProxy('192.168.1.9', <String>['192.168.*']), isTrue);
      expect(shouldBypassProxy('www.youtube.com', <String>['10.*']), isFalse);
    });

    test('a bare entry matches exactly, like WinINET', () {
      expect(shouldBypassProxy('corp.example', <String>['corp.example']), isTrue);
      // No implicit suffix match: WinINET requires an explicit `*.` for
      // subdomains, and inferring one would make a bare `com` entry bypass the
      // proxy for every .com host.
      expect(
        shouldBypassProxy('a.corp.example', <String>['corp.example']),
        isFalse,
      );
      expect(shouldBypassProxy('www.youtube.com', <String>['com']), isFalse);
      expect(
        shouldBypassProxy('notcorp.example', <String>['corp.example']),
        isFalse,
      );
    });

    test('supports the ? single-character wildcard', () {
      expect(shouldBypassProxy('host1', <String>['host?']), isTrue);
      expect(shouldBypassProxy('host12', <String>['host?']), isFalse);
    });

    test('a pathological wildcard entry still matches in linear time', () {
      // Translating globs to `.*` regexes backtracks catastrophically here;
      // this ran for minutes before the matcher was rewritten.
      final Stopwatch watch = Stopwatch()..start();
      expect(
        shouldBypassProxy('a' * 244, <String>['*a*a*a*a*a*a*z']),
        isFalse,
      );
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });

    test('<local> covers dotless names and loopback', () {
      expect(shouldBypassProxy('intranet', <String>['<local>']), isTrue);
      expect(shouldBypassProxy('127.0.0.5', <String>['<local>']), isTrue);
      expect(shouldBypassProxy('localhost', <String>['<local>']), isTrue);
      expect(shouldBypassProxy('www.youtube.com', <String>['<local>']), isFalse);
    });
  });

  group('ytDlpProxyEnvironment', () {
    const WindowsSystemProxy proxy = WindowsSystemProxy(
      httpServer: 'http://127.0.0.1:10808',
      httpsServer: 'http://127.0.0.1:10808',
      bypass: <String>['10.*', '<local>'],
    );

    test('injects the system proxy when the environment names none', () {
      // Reproduces the real trap: NO_PROXY alone makes CPython's
      // getproxies_environment() truthy, so the registry is never consulted and
      // the system proxy is silently ignored.
      final Map<String, String> env = ytDlpProxyEnvironment(
        parentEnvironment: <String, String>{'NO_PROXY': 'corp.example'},
        systemProxy: proxy,
        targetHost: 'www.youtube.com',
      );
      expect(env['HTTP_PROXY'], 'http://127.0.0.1:10808');
      expect(env['HTTPS_PROXY'], 'http://127.0.0.1:10808');
    });

    test('leaves a bypassed intranet host on a direct connection', () {
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{},
          systemProxy: proxy,
          targetHost: '10.1.2.3',
        ),
        isEmpty,
      );
    });

    test('defers to an explicit proxy already in the environment', () {
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{
            'HTTPS_PROXY': 'http://10.1.1.1:3128',
          },
          systemProxy: proxy,
          targetHost: 'www.youtube.com',
        ),
        isEmpty,
      );
    });

    test('ignores an empty proxy variable', () {
      // Empty values are what a shell leaves behind; they must not be mistaken
      // for a deliberate choice.
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{'HTTPS_PROXY': '  '},
          systemProxy: proxy,
          targetHost: 'www.youtube.com',
        ),
        isNotEmpty,
      );
    });

    test('honours the caller own no_proxy, including subdomains', () {
      // no_proxy is not a proxy *server* setting, so it does not suppress
      // injection -- but discarding it would tunnel a host the user excluded.
      // CPython matches it by suffix, so subdomains must be covered too.
      for (final String host in <String>[
        'internal.example',
        'deep.internal.example',
      ]) {
        expect(
          ytDlpProxyEnvironment(
            parentEnvironment: <String, String>{'NO_PROXY': '.internal.example'},
            systemProxy: proxy,
            targetHost: host,
          ),
          isEmpty,
          reason: host,
        );
      }
    });

    test('an https page goes direct under an http-only proxy', () {
      // WinINET does not proxy HTTPS for `ProxyServer = http=...`. Omitting
      // HTTPS_PROXY does not reproduce that -- yt-dlp copies the http proxy
      // onto https and would CONNECT to a proxy that may not speak it
      // (verified against the real binary) -- so nothing is injected at all.
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{},
          systemProxy: const WindowsSystemProxy(
            httpServer: 'http://10.0.0.1:80',
          ),
          targetHost: 'www.youtube.com',
        ),
        isEmpty,
      );
    });

    test('an http page still uses an http-only proxy, https guarded', () {
      final Map<String, String> env = ytDlpProxyEnvironment(
        parentEnvironment: <String, String>{},
        systemProxy: const WindowsSystemProxy(httpServer: 'http://10.0.0.1:80'),
        targetHost: 'intranet.example',
        targetIsHttp: true,
      );
      expect(env['HTTP_PROXY'], 'http://10.0.0.1:80');
      expect(env['HTTPS_PROXY'], '__noproxy__');
    });

    test('a bare * in no_proxy list position is ignored', () {
      // CPython honours `*` only as the entire value; as a list member it
      // matches nothing, so feeding it to the glob would kill the proxy.
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{'NO_PROXY': '*,corp.example'},
          systemProxy: proxy,
          targetHost: 'www.youtube.com',
        ),
        isNotEmpty,
      );
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{'NO_PROXY': '*'},
          systemProxy: proxy,
          targetHost: 'www.youtube.com',
        ),
        isEmpty,
      );
    });

    test('adds nothing for a URL with no host', () {
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{},
          systemProxy: proxy,
          targetHost: '',
        ),
        isEmpty,
      );
    });

    test('adds nothing when no system proxy is configured', () {
      expect(
        ytDlpProxyEnvironment(
          parentEnvironment: <String, String>{},
          systemProxy: null,
          targetHost: 'www.youtube.com',
        ),
        isEmpty,
      );
    });
  });

  group('isCookieSourceFailureStderr', () {
    test('matches the Chromium app-bound encryption failure', () {
      expect(
        isCookieSourceFailureStderr(
          'ERROR: Failed to decrypt with DPAPI. See  https://... for more info',
        ),
        isTrue,
      );
    });

    test('matches a locked or missing cookie database', () {
      expect(
        isCookieSourceFailureStderr(
          'ERROR: Could not copy Chrome cookie database',
        ),
        isTrue,
      );
      expect(
        isCookieSourceFailureStderr(
          "ERROR: could not find firefox cookies database in 'C:\\...'",
        ),
        isTrue,
      );
    });

    test('does not match a page that merely needs an account', () {
      expect(
        isCookieSourceFailureStderr(
          'ERROR: [vimeo] 76979871: The web client only works when logged-in.',
        ),
        isFalse,
      );
    });
  });

  group('isLoginRequiredStderr', () {
    test('matches the phrasings real extractors use', () {
      // Verified against live yt-dlp output; matching only "sign in" missed the
      // Vimeo wording entirely and produced a bare exit-code message.
      expect(
        isLoginRequiredStderr(
          'ERROR: [vimeo] 76979871: The web client only works when logged-in. '
          'Use --cookies, --cookies-from-browser, --username and --password ...',
        ),
        isTrue,
      );
      expect(
        isLoginRequiredStderr("ERROR: Sign in to confirm you're not a bot."),
        isTrue,
      );
      expect(
        isLoginRequiredStderr('ERROR: This video is private'),
        isTrue,
      );
    });

    test('does not classify a plain network failure as needing login', () {
      expect(
        isLoginRequiredStderr(
          'ERROR: unable to download webpage: <urlopen error timed out>',
        ),
        isFalse,
      );
    });
  });
}
