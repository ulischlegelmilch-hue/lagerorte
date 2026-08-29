import 'dart:js_interop';

@JS('speechSynthesis')
external JSObject? get _speechSynthesis;

@JS('speechSynthesis.speak')
external void _speak(JSObject utterance);

@JS('SpeechSynthesisUtterance')
extension type _Utterance._(JSObject _) implements JSObject {
  external _Utterance(String text);
  external set lang(String value);
}

/// Begrüßt per Browser-Sprachausgabe (Web Speech API), kein Audio-Asset
/// nötig. Wird direkt aus dem Login-Klick heraus aufgerufen (Nutzer-Geste),
/// damit Browser-Autoplay-Sperren nicht greifen.
void sagHalloFleissige() {
  try {
    if (_speechSynthesis == null) return;
    _speak(_Utterance('Hallo ihr Fleißigen!')..lang = 'de-DE');
  } catch (_) {
    // Nice-to-have – darf die App nie zum Absturz bringen.
  }
}
