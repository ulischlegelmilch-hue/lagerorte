import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/material.dart';

/// Wird beim Build per `--dart-define=BUILD_ID=...` gesetzt (siehe
/// Deploy-Ablauf: dieselbe ID landet zusätzlich in `build/web/build-id.txt`).
/// Ohne Define (z.B. `flutter run`) ist die Prüfung deaktiviert.
const _buildId = String.fromEnvironment('BUILD_ID');

@JS('fetch')
external JSPromise<_Response> _fetch(String url, JSObject options);

@JS('Object')
extension type _Options._(JSObject _) implements JSObject {
  external factory _Options();
}

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external JSPromise<JSString> text();
}

@JS('location.reload')
external void _reload();

@JS('navigator.serviceWorker.getRegistrations')
external JSPromise<JSArray<JSObject>> _swRegistrations();

@JS('caches.keys')
external JSPromise<JSArray<JSString>> _cacheKeys();

@JS('caches.delete')
external JSPromise<JSBoolean> _cacheDelete(String key);

Future<String?> _serverBuildId() async {
  try {
    final opts = _Options();
    opts.setProperty('cache'.toJS, 'no-store'.toJS);
    final url = 'build-id.txt?t=${DateTime.now().millisecondsSinceEpoch}';
    final res = await _fetch(url, opts).toDart;
    if (!res.ok) return null;
    final text = (await res.text().toDart).toDart.trim();
    // Ein Server, der statt der Datei die index.html ausliefert, darf nicht
    // als "neue Version" gelten.
    if (text.isEmpty || text.contains('<') || text.length > 64) return null;
    return text;
  } catch (_) {
    return null;
  }
}

/// Löscht Service-Worker und Caches, damit der Reload wirklich die neue
/// Version vom Server holt und nicht die gecachte alte.
Future<void> _neuLaden() async {
  try {
    final regs = (await _swRegistrations().toDart).toDart;
    for (final r in regs) {
      await (r.callMethod('unregister'.toJS) as JSPromise).toDart;
    }
  } catch (_) {}
  try {
    final keys = (await _cacheKeys().toDart).toDart;
    for (final k in keys) {
      await _cacheDelete(k.toDart).toDart;
    }
  } catch (_) {}
  _reload();
}

/// Legt über jeden Screen einen Hinweis-Balken, sobald auf dem Server eine
/// neuere Version liegt als die gerade laufende. Prüft beim Start, danach alle
/// 5 Minuten und beim Zurückkehren in die App.
class UpdateBanner extends StatefulWidget {
  final Widget child;
  const UpdateBanner({super.key, required this.child});
  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> with WidgetsBindingObserver {
  bool _neueVersion = false;
  bool _laedt = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (_buildId.isEmpty) return;
    WidgetsBinding.instance.addObserver(this);
    _pruefen();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _pruefen());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _pruefen();
  }

  Future<void> _pruefen() async {
    final server = await _serverBuildId();
    if (!mounted || server == null) return;
    if (server != _buildId && !_neueVersion) setState(() => _neueVersion = true);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (_neueVersion)
        Material(
          color: const Color(0xFFE30613),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                const Expanded(
                  child: Text('Neue Version verfügbar',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: _laedt
                      ? null
                      : () {
                          setState(() => _laedt = true);
                          _neuLaden();
                        },
                  style: TextButton.styleFrom(backgroundColor: Colors.white),
                  child: Text(_laedt ? 'LÄDT…' : 'JETZT NEU LADEN',
                      style: const TextStyle(color: Color(0xFFE30613), fontWeight: FontWeight.bold)),
                ),
              ]),
            ),
          ),
        ),
      Expanded(child: widget.child),
    ]);
  }
}
