import 'package:syncfusion_flutter_pdf/pdf.dart';

/// Extrahiert den kompletten Text aller Seiten einer PDF.
String extractPdfText(List<int> bytes) {
  final document = PdfDocument(inputBytes: bytes);
  final buffer = StringBuffer();
  for (var i = 0; i < document.pages.count; i++) {
    buffer.writeln(PdfTextExtractor(document).extractText(startPageIndex: i));
  }
  document.dispose();
  return buffer.toString();
}

const _einheitFamilien = <String, List<String>>{
  'stueck': ['stück', 'stk'],
  'karton': ['karton', 'kart', 'ktn'],
  'beutel': ['beutel', 'btl'],
  'flasche': ['flasche', 'pipette'],
  'packung': ['pack', 'pck'],
  'rolle': ['rolle'],
  'paar': ['paar'],
  'tube': ['tube'],
};

Set<String> _familien(String text) {
  final t = text.toLowerCase();
  final result = <String>{};
  _einheitFamilien.forEach((familie, schluessel) {
    if (schluessel.any((s) => t.contains(s))) result.add(familie);
  });
  return result;
}

/// Entfernt die letzte Klammer im Namen NUR, wenn ihr Inhalt zur Einheit
/// passt (z.B. "(Stück)" bei Einheit "Stück"). Klammern mit Artikelmerkmalen
/// (Farbe, Größe, ...) bleiben erhalten.
String cleanArticleName(String name, String einheit) {
  if (einheit.isEmpty) return name;
  final m = RegExp(r'^(.*)\(([^()]*)\)\s*$').firstMatch(name);
  if (m == null) return name;
  final klammerInhalt = m.group(2)!;
  if (_familien(klammerInhalt).intersection(_familien(einheit)).isNotEmpty) {
    return m.group(1)!.trim();
  }
  return name;
}

class ArtikelOrt {
  final String name;
  String lagerort;
  /// Manuell festgelegte Position innerhalb des Lagerorts (0-basiert);
  /// -1 = keine eigene Reihenfolge gesetzt, dann wird natürlich sortiert.
  int reihenfolge;
  /// true, wenn der Lagerort per Hand zugewiesen wurde (statt aus der PDF
  /// übernommen). Bleibt bei einem erneuten Inventurliste-Import erhalten,
  /// damit eine manuelle Korrektur nicht wieder von den PDF-Daten
  /// überschrieben wird.
  bool lagerortManuell;
  ArtikelOrt(this.name, this.lagerort, {this.reihenfolge = -1, this.lagerortManuell = false});
  Map<String, dynamic> toJson() => {'n': name, 'l': lagerort, 'r': reihenfolge, 'lm': lagerortManuell};
  factory ArtikelOrt.fromJson(Map<String, dynamic> m) => ArtikelOrt(
      m['n'] as String, m['l'] as String,
      reihenfolge: m['r'] as int? ?? -1, lagerortManuell: m['lm'] as bool? ?? false);
}

/// Baut aus dem "Inventurliste"-PDF (Spalten: Artikelnummer, Lagerort,
/// Stückpreis, Einheit, Ist-Bestand, Artikelbeschreibung, Preis-Zeile 2)
/// eine reine Name->Lagerort-Zuordnung. Der PDF-Textextraktor legt jede
/// Tabellenzelle als eigene Zeile ab, getrennt durch Leerzeilen; das
/// Einheit-Feld fehlt bei manchen Zeilen ganz.
List<ArtikelOrt> parseInventurliste(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

  final nrRe = RegExp(r'^(\d+):$');
  final priceRe = RegExp(r'^\d+,\d{2}');
  final intRe = RegExp(r'^\d+');

  final items = <ArtikelOrt>[];
  int state = 0; // 0=Nr, 1=Lagerort, 2=Preis1, 3=Einheit/Ist-Bestand, 4=Ist-Bestand, 5=Name, 6=Preis2/Name-Fortsetzung
  String lagerort = '', einheit = '', name = '';
  bool haveNr = false;

  void flush() {
    if (haveNr && name.isNotEmpty && lagerort.isNotEmpty) {
      items.add(ArtikelOrt(cleanArticleName(name, einheit), lagerort));
    }
    haveNr = false;
  }

  for (final l in lines) {
    switch (state) {
      case 0:
        if (nrRe.hasMatch(l)) { haveNr = true; state = 1; }
        break;
      case 1:
        lagerort = l; state = 2;
        break;
      case 2:
        if (priceRe.hasMatch(l)) state = 3;
        break;
      case 3:
        if (intRe.hasMatch(l)) { einheit = ''; state = 5; }
        else { einheit = l; state = 4; }
        break;
      case 4:
        if (intRe.hasMatch(l)) state = 5;
        break;
      case 5:
        name = l; state = 6;
        break;
      case 6:
        if (priceRe.hasMatch(l)) { flush(); state = 0; lagerort = ''; einheit = ''; name = ''; }
        else { name = '$name $l'; }
        break;
    }
  }
  flush();
  return items;
}

class BestellPosition {
  final String name;
  final int menge;
  final String einheit;
  bool abgehakt;
  bool nichtVerfuegbar;
  BestellPosition(this.name, this.menge, this.einheit, {this.abgehakt = false, this.nichtVerfuegbar = false});
  Map<String, dynamic> toJson() => {'n': name, 'm': menge, 'e': einheit, 'a': abgehakt, 'nv': nichtVerfuegbar};
  factory BestellPosition.fromJson(Map<String, dynamic> j) => BestellPosition(
      j['n'] as String, j['m'] as int, j['e'] as String,
      abgehakt: j['a'] as bool? ?? false, nichtVerfuegbar: j['nv'] as bool? ?? false);
}

class Bestellung {
  final String? bestellNr;
  final String? wache;
  final DateTime? erstelltAm;
  final List<BestellPosition> positionen;
  Bestellung({this.bestellNr, this.wache, this.erstelltAm, required this.positionen});
}

/// Baut aus dem "Bestellung"-PDF (Spalten: Pos., Bezeichnung, Artikel-Nr.,
/// Anzahl, Einheit) die Liste der bestellten Artikel. Gleiche Zeilen-pro-
/// Zelle-Struktur wie bei der Inventurliste, aber andere Spaltenreihenfolge;
/// eine über zwei Zeilen umgebrochene Einheit (z.B. "Packung"/"( en )") wird
/// verworfen.
Bestellung parseBestellung(String text, List<String> bekannteWachen) {
  final nrMatch = RegExp(r'Bestellung\s+(\d{8}-\d+)').firstMatch(text);
  final erstelltMatch = RegExp(r'Dokument erstellt am:\s*(\d{2})\.(\d{2})\.(\d{4})').firstMatch(text);
  final erstelltAm = erstelltMatch == null
      ? null
      : DateTime(int.parse(erstelltMatch.group(3)!), int.parse(erstelltMatch.group(2)!), int.parse(erstelltMatch.group(1)!));
  String? wache;
  for (final w in bekannteWachen) {
    if (RegExp('Au[ßss]enlager\\s+$w', caseSensitive: false).hasMatch(text)) {
      wache = w;
      break;
    }
  }

  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final headerIdx = lines.indexOf('Pos.');
  if (headerIdx < 0) {
    return Bestellung(bestellNr: nrMatch?.group(1), wache: wache, erstelltAm: erstelltAm, positionen: []);
  }

  final posRe = RegExp(r'^\d{1,3}$');
  final nrRe = RegExp(r'^\d{4,7}$');
  final anzahlRe = RegExp(r'^\d{1,4}$');

  final items = <BestellPosition>[];
  int state = 0; // 0=Pos, 1=Bezeichnung, 2=Artikel-Nr., 3=Anzahl, 4=Einheit, 5=Einheit-Fortsetzung
  int? pos;
  String name = '';
  int menge = 0;
  String einheit = '';

  void flush() {
    if (pos != null && name.isNotEmpty && menge > 0) {
      items.add(BestellPosition(cleanArticleName(name, einheit), menge, einheit));
    }
    pos = null;
  }

  for (var i = headerIdx + 5; i < lines.length; i++) {
    final l = lines[i];
    switch (state) {
      case 0:
        if (posRe.hasMatch(l)) { pos = int.parse(l); state = 1; }
        break;
      case 1:
        name = l; state = 2;
        break;
      case 2:
        if (nrRe.hasMatch(l)) state = 3;
        break;
      case 3:
        if (anzahlRe.hasMatch(l)) { menge = int.parse(l); state = 4; }
        break;
      case 4:
        einheit = l; state = 5;
        break;
      case 5:
        if (posRe.hasMatch(l) && int.parse(l) == (pos ?? 0) + 1) {
          flush();
          pos = int.parse(l);
          state = 1;
        }
        break;
    }
  }
  flush();
  return Bestellung(bestellNr: nrMatch?.group(1), wache: wache, erstelltAm: erstelltAm, positionen: items);
}
