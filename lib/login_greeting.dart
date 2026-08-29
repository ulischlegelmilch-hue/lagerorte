import 'dart:js_interop';

@JS('Audio')
extension type _Audio._(JSObject _) implements JSObject {
  external _Audio(String src);
  external void play();
}

/// Spielt die Login-Begrüßung ("Hallo ihr Fleißigen!", ElevenLabs-Stimme
/// "Marie") ab. Wird direkt aus dem Login-Klick heraus aufgerufen
/// (Nutzer-Geste), damit Browser-Autoplay-Sperren nicht greifen.
void sagHalloFleissige() {
  try {
    _Audio('audio/login-hallo.mp3').play();
  } catch (_) {
    // Nice-to-have – darf die App nie zum Absturz bringen.
  }
}
