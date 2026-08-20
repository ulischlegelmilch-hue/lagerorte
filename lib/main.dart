import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'pdf_utils.dart';

const _red = Color(0xFFE30613);
const _bg = Color(0xFF121212);
const _card = Color(0xFF1E1E22);

const _bekannteWachen = ['Bad Salzungen', 'Vacha', 'Gumpelstadt', 'Dermbach', 'Geisa'];

const _zugangsPasswort = 'DRK2026';
final _stichtag = DateTime(2026, 12, 31, 23, 59, 59);

/// Sortierschlüssel für Lagerorte – von Uli festgelegte Reihenfolge:
/// 0 = Schränke S1..S5, 1 = Kinderschrank, 2 = restliche Schränke (S6+, S7,
/// S8, MPG Schrank, ...), 3 = Regale, 4 = Palette, 5 = Desigarage, 6 =
/// KTW-Raum, 7 = alles andere (alphabetisch), 8 = "Lagerort unbekannt"
/// (immer zuletzt). Innerhalb eines Schranks/Regals wird zusätzlich nach
/// Ebene sortiert (z.B. "S1 E1" vor "S1 E2"; ein Schrank ohne Ebenenangabe
/// wie "S7" vor seinen Ebenen; "oben drauf" nach den nummerierten Ebenen).
/// Die Rohdaten schreiben denselben Ort teils unterschiedlich (z.B. "S8"
/// und "Schrank 8", "S4 E1" und "S4E1", "R2 E2" und "Regal 2 E1") – all
/// diese Schreibweisen werden erkannt, damit sie an derselben Stelle
/// einsortiert werden.
class _LagerortSortKey implements Comparable<_LagerortSortKey> {
  final int kategorie; // 0 = Schrank, 1 = Regal, 2 = Rest, 3 = unbekannt
  final int nummer;
  final int ebene;
  final String rest;
  _LagerortSortKey(this.kategorie, this.nummer, this.ebene, this.rest);

  @override
  int compareTo(_LagerortSortKey other) {
    if (kategorie != other.kategorie) return kategorie.compareTo(other.kategorie);
    if (nummer != other.nummer) return nummer.compareTo(other.nummer);
    if (ebene != other.ebene) return ebene.compareTo(other.ebene);
    return rest.compareTo(other.rest);
  }
}

/// Ermittelt die Ebenen-Nummer aus dem Rest eines Lagerort-Strings nach dem
/// Schrank-/Regal-Namen (z.B. " E1" -> 1). -1 = keine Ebene angegeben
/// (sortiert vor den Ebenen), 999 = "oben drauf" (sortiert nach den Ebenen).
int _ebeneVon(String rest) {
  final m = RegExp(r'E\s*(\d+)', caseSensitive: false).firstMatch(rest);
  if (m != null) return int.parse(m.group(1)!);
  if (rest.toLowerCase().contains('oben')) return 999;
  return -1;
}

_LagerortSortKey _lagerortSortKey(String ort) {
  if (ort == 'Lagerort unbekannt') return _LagerortSortKey(8, 0, 0, ort);

  final ortLower = ort.toLowerCase();

  if (ortLower.contains('kinderschrank')) return _LagerortSortKey(1, 0, 0, ort);

  final schrankM = RegExp(r'^S(?:chrank)?\.?\s*(\d+)', caseSensitive: false).firstMatch(ort);
  if (schrankM != null) {
    final nummer = int.parse(schrankM.group(1)!);
    final kategorie = nummer <= 5 ? 0 : 2;
    return _LagerortSortKey(kategorie, nummer, _ebeneVon(ort.substring(schrankM.end)), ort);
  }
  if (ortLower.contains('schrank')) return _LagerortSortKey(2, 999, 0, ort);

  final regalM = RegExp(r'^R(?:egal)?\.?\s*(\d+)', caseSensitive: false).firstMatch(ort);
  if (regalM != null) {
    return _LagerortSortKey(3, int.parse(regalM.group(1)!), _ebeneVon(ort.substring(regalM.end)), ort);
  }
  if (ortLower.contains('regal')) return _LagerortSortKey(3, 999, 0, ort);

  if (ortLower.contains('palette')) return _LagerortSortKey(4, 0, 0, ort);
  if (ortLower.contains('desigarage') || ortLower.contains('desiraum')) {
    return _LagerortSortKey(5, 0, 0, ort);
  }
  if (ortLower.contains('ktw')) return _LagerortSortKey(6, 0, 0, ort);

  return _LagerortSortKey(7, 0, 0, ort);
}

/// Buchstaben-Größen in ihrer logischen (nicht alphabetischen) Reihenfolge,
/// damit z.B. "Größe S" vor "Größe M" vor "Größe L" einsortiert wird statt
/// alphabetisch (L, M, S, XL, XS).
const _groessenReihenfolge = {'xxs': 0, 'xs': 1, 's': 2, 'm': 3, 'l': 4, 'xl': 5, 'xxl': 6};

final _artikelTokenRe = RegExp(r'\d+(?:[.,]\d+)?|[A-Za-zÄÖÜäöüß]+');

/// Vergleicht zwei Artikelnamen "natürlich": gleiche Wörter (der Oberbegriff,
/// z.B. "Flexülen" oder "Guedeltubus") werden gleich behandelt, die
/// unterschiedliche Zahl bzw. Größenangabe (der Unterbegriff, z.B. "G14" vs.
/// "G22" oder "Größe S" vs. "Größe M") aber numerisch bzw. nach Größen-
/// Reihenfolge statt alphabetisch verglichen. So landen z.B. Flexülen G14
/// vor G16 vor G18 statt alphabetisch G14, G16, G18, G20, G22 (zufällig
/// gleich) bzw. Handschuhe XS vor S vor M vor L vor XL statt alphabetisch
/// L, M, S, XL, XS. Der volle Artikelname bleibt für die Anzeige unverändert
/// ausgeschrieben, nur die Sortierung nutzt diese Tokens.
int _artikelVergleich(String a, String b) {
  final ta = _artikelTokenRe.allMatches(a).map((m) => m.group(0)!).toList();
  final tb = _artikelTokenRe.allMatches(b).map((m) => m.group(0)!).toList();
  final len = ta.length < tb.length ? ta.length : tb.length;
  for (var i = 0; i < len; i++) {
    final xa = ta[i], xb = tb[i];
    final na = num.tryParse(xa.replaceAll(',', '.'));
    final nb = num.tryParse(xb.replaceAll(',', '.'));
    if (na != null && nb != null) {
      if (na != nb) return na.compareTo(nb);
      continue;
    }
    final ga = _groessenReihenfolge[xa.toLowerCase()];
    final gb = _groessenReihenfolge[xb.toLowerCase()];
    if (ga != null && gb != null) {
      if (ga != gb) return ga.compareTo(gb);
      continue;
    }
    final c = xa.toLowerCase().compareTo(xb.toLowerCase());
    if (c != 0) return c;
  }
  return ta.length.compareTo(tb.length);
}

/// Ein Artikel an einem Lagerort, aggregiert über alle offenen Bestellungen
/// hinweg: wie viel insgesamt aus dem Fach zu nehmen ist, aufgeschlüsselt
/// danach, wie viel davon an welche Wache geht.
class _AggregatEintrag {
  final String name;
  final String lagerort;
  final List<MapEntry<String, BestellPosition>> proWache;
  _AggregatEintrag(this.name, this.lagerort, this.proWache);
  int get gesamt => proWache.fold(0, (s, e) => s + e.value.menge);
  String get einheit => proWache.first.value.einheit;
  bool get abgehakt => proWache.every((e) => e.value.abgehakt);
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(
    url: 'https://nznyfbojyhbolnwnodzz.supabase.co',
    publishableKey: 'sb_publishable_n5Jp12qCZDNETlr7Z16-RA_uKzehPtd',
  );
  runApp(const LagerorteApp());
}

class LagerorteApp extends StatelessWidget {
  const LagerorteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lagerbuddy',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _red, surface: _card),
      ),
      home: const GateScreen(),
    );
  }
}

/// Sperrt die App bis zur Passworteingabe (einmalig pro Gerät, danach lokal
/// gemerkt) und ab dem Stichtag komplett, unabhängig vom Passwort.
class GateScreen extends StatefulWidget {
  const GateScreen({super.key});
  @override
  State<GateScreen> createState() => _GateScreenState();
}

class _GateScreenState extends State<GateScreen> {
  // Nur im Speicher (nicht persistiert) - Passwort wird bei jedem Öffnen
  // der App erneut verlangt.
  bool _freigeschaltet = false;
  final _passwortCtrl = TextEditingController();
  String? _fehler;

  void _freischalten() {
    if (_passwortCtrl.text.trim() == _zugangsPasswort) {
      setState(() {
        _freigeschaltet = true;
        _fehler = null;
      });
    } else {
      setState(() => _fehler = 'Falsches Passwort');
    }
  }

  @override
  Widget build(BuildContext context) {

    if (DateTime.now().isAfter(_stichtag)) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(32),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Icon(Icons.event_busy, size: 60, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'Diese Version ist abgelaufen.\nBitte bei Uli nach einer aktuellen Version fragen.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            ]),
          ),
        ),
      );
    }

    if (!_freigeschaltet) {
      return Scaffold(
        backgroundColor: _bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.lock_outline, size: 60, color: _red),
              const SizedBox(height: 20),
              const Text('LAGERBUDDY',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20, letterSpacing: 1.5)),
              const SizedBox(height: 24),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _passwortCtrl,
                  obscureText: true,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Passwort',
                    labelStyle: const TextStyle(color: Colors.grey),
                    errorText: _fehler,
                    filled: true,
                    fillColor: _card,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _freischalten(),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 260,
                child: ElevatedButton(
                  onPressed: _freischalten,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _red,
                    minimumSize: const Size.fromHeight(48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('ENTSPERREN', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ),
            ]),
          ),
        ),
      );
    }

    return const RootScreen();
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});
  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _tab = 0;

  // --- Lagerliste ---
  final Map<String, List<ArtikelOrt>> _lager = {};
  String? _aktivesLager;
  final _searchCtrl = TextEditingController();
  bool _isParsingLager = false;
  bool _isSyncingLager = false;
  String? _lagerFehler;

  SupabaseClient get _db => Supabase.instance.client;

  // --- Kommissionieren ---
  final Map<String, Bestellung> _bestellungen = {}; // Key: Wache
  bool _isParsingBestellung = false;
  String? _bestellFehler;
  int _kommAnsicht = 0; // 0 = Sammelliste, 1 = Je Wache
  String? _ausgewaehlteWache;
  int _lagerlisteSortierung = 0; // 0 = nach Artikel, 1 = nach Lagerort

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _laden();
  }

  Future<void> _laden() async {
    final prefs = await SharedPreferences.getInstance();
    // Lokaler Cache zuerst, damit sofort etwas sichtbar ist (auch offline).
    final rawLager = prefs.getString('lager_daten');
    if (rawLager != null) {
      final decoded = jsonDecode(rawLager) as Map<String, dynamic>;
      _lager.clear();
      decoded.forEach((lager, liste) {
        _lager[lager] = (liste as List)
            .map((e) => ArtikelOrt.fromJson(e as Map<String, dynamic>))
            .toList();
      });
    }
    setState(() => _aktivesLager = _lager.keys.isNotEmpty ? _lager.keys.first : null);
    await _lagerVonDbLaden();

    final rawBestellungen = prefs.getString('bestellungen');
    if (rawBestellungen != null) {
      final decoded = jsonDecode(rawBestellungen) as Map<String, dynamic>;
      _bestellungen.clear();
      decoded.forEach((wache, v) {
        final m = v as Map<String, dynamic>;
        final positionen = (m['positionen'] as List)
            .map((e) => BestellPosition.fromJson(e as Map<String, dynamic>))
            .toList();
        _bestellungen[wache] = Bestellung(bestellNr: m['nr'] as String?, wache: wache, positionen: positionen);
      });
      setState(() => _ausgewaehlteWache = _bestellungen.keys.isNotEmpty ? _bestellungen.keys.first : null);
    }
  }

  /// Lädt die Lagerlisten aller Lager aus der geteilten Datenbank (falls
  /// erreichbar) und ersetzt damit den lokalen Stand, damit alle Geräte
  /// denselben Datensatz sehen.
  Future<void> _lagerVonDbLaden() async {
    setState(() => _isSyncingLager = true);
    try {
      final rows = await _db.from('lagerorte').select('lager, name, lagerort');
      final Map<String, List<ArtikelOrt>> geladen = {};
      for (final row in rows as List) {
        final lager = row['lager'] as String;
        geladen.putIfAbsent(lager, () => []).add(ArtikelOrt(row['name'] as String, row['lagerort'] as String));
      }
      if (geladen.isNotEmpty || _lager.isEmpty) {
        setState(() {
          _lager
            ..clear()
            ..addAll(geladen);
          if (_aktivesLager == null || !_lager.containsKey(_aktivesLager)) {
            _aktivesLager = _lager.keys.isNotEmpty ? _lager.keys.first : null;
          }
        });
        await _lagerSpeichern();
      }
    } catch (_) {
      // offline oder DB nicht erreichbar -> lokaler Cache bleibt bestehen
    } finally {
      if (mounted) setState(() => _isSyncingLager = false);
    }
  }

  Future<void> _lagerSpeichern() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_lager.map(
        (lager, liste) => MapEntry(lager, liste.map((e) => e.toJson()).toList())));
    await prefs.setString('lager_daten', encoded);
  }

  Future<void> _bestellungenSpeichern() async {
    final prefs = await SharedPreferences.getInstance();
    if (_bestellungen.isEmpty) {
      await prefs.remove('bestellungen');
      return;
    }
    final encoded = jsonEncode(_bestellungen.map((wache, b) => MapEntry(wache, {
          'nr': b.bestellNr,
          'positionen': b.positionen.map((e) => e.toJson()).toList(),
        })));
    await prefs.setString('bestellungen', encoded);
  }

  // ---------------- Lagerliste-Import ----------------

  Future<void> _lagerPdfImportieren() async {
    setState(() => _lagerFehler = null);
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty) return;
    final picked = result.first;

    setState(() => _isParsingLager = true);
    try {
      final bytes = await picked.readAsBytes();
      final text = extractPdfText(bytes);

      final lagerMatch = RegExp(r'Inventurliste\s+Lager\s+(.+)').firstMatch(text);
      final lagerName = lagerMatch?.group(1)?.trim() ?? picked.name.replaceAll('.pdf', '');

      final items = parseInventurliste(text);
      if (items.isEmpty) {
        setState(() => _lagerFehler = 'Es konnten keine Artikel in dieser PDF erkannt werden.');
        return;
      }

      setState(() {
        _lager[lagerName] = items;
        _aktivesLager = lagerName;
      });
      await _lagerSpeichern();

      String? dbFehler;
      try {
        await _db.from('lagerorte').delete().eq('lager', lagerName);
        await _db.from('lagerorte').insert(
            items.map((a) => {'lager': lagerName, 'name': a.name, 'lagerort': a.lagerort}).toList());
      } catch (e) {
        dbFehler = '$e';
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(dbFehler == null
                ? '$lagerName: ${items.length} Artikel importiert und in der Datenbank gespeichert'
                : '$lagerName: ${items.length} Artikel lokal gespeichert, Datenbank aber nicht erreichbar ($dbFehler)'),
            backgroundColor: dbFehler == null ? Colors.green : Colors.orange,
          ),
        );
      }
    } catch (e) {
      setState(() => _lagerFehler = 'PDF konnte nicht gelesen werden: $e');
    } finally {
      if (mounted) setState(() => _isParsingLager = false);
    }
  }

  Future<void> _lagerLoeschen(String lager) async {
    setState(() {
      _lager.remove(lager);
      if (_aktivesLager == lager) {
        _aktivesLager = _lager.keys.isNotEmpty ? _lager.keys.first : null;
      }
    });
    await _lagerSpeichern();
    try {
      await _db.from('lagerorte').delete().eq('lager', lager);
    } catch (_) {}
  }

  List<ArtikelOrt> get _gefiltert {
    final liste = _lager[_aktivesLager] ?? [];
    final q = _searchCtrl.text.trim().toLowerCase();
    final gefiltert = q.isEmpty
        ? List<ArtikelOrt>.from(liste)
        : liste.where((a) => a.name.toLowerCase().contains(q)).toList();
    if (_lagerlisteSortierung == 1) {
      gefiltert.sort((a, b) {
        final ortVergleich = _lagerortSortKey(a.lagerort).compareTo(_lagerortSortKey(b.lagerort));
        if (ortVergleich != 0) return ortVergleich;
        return _artikelVergleich(a.name, b.name);
      });
    } else {
      gefiltert.sort((a, b) => _artikelVergleich(a.name, b.name));
    }
    return gefiltert;
  }

  // ---------------- Bestellung-Import / Kommissionieren ----------------

  /// Erlaubt die Auswahl mehrerer Bestellungs-PDFs auf einmal (z.B. alle
  /// Außenlager einer Lieferung in einem Rutsch importieren). Jede PDF wird
  /// einzeln geparst; eine fehlerhafte Datei blockiert die anderen nicht.
  Future<void> _bestellungPdfImportieren() async {
    setState(() => _bestellFehler = null);
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty) return;

    setState(() => _isParsingBestellung = true);
    final erfolgreich = <String>[];
    final fehler = <String>[];
    try {
      for (final picked in result) {
        try {
          final bytes = await picked.readAsBytes();
          final text = extractPdfText(bytes);
          final bestellung = parseBestellung(text, _bekannteWachen);

          if (bestellung.positionen.isEmpty) {
            fehler.add('${picked.name}: keine Positionen erkannt');
            continue;
          }
          final wache = bestellung.wache;
          if (wache == null) {
            fehler.add('${picked.name}: Wache nicht erkannt');
            continue;
          }
          _bestellungen[wache] = bestellung;
          erfolgreich.add(wache);
        } catch (e) {
          fehler.add('${picked.name}: $e');
        }
      }

      if (erfolgreich.isNotEmpty) {
        setState(() => _ausgewaehlteWache = erfolgreich.last);
        await _bestellungenSpeichern();
      }
      if (mounted && erfolgreich.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${erfolgreich.length} Bestellung(en) importiert: ${erfolgreich.join(', ')}'),
            backgroundColor: Colors.green,
          ),
        );
      }
      if (fehler.isNotEmpty) {
        setState(() => _bestellFehler = fehler.join('\n'));
      }
    } finally {
      if (mounted) setState(() => _isParsingBestellung = false);
    }
  }

  Future<void> _allesLeerenBestaetigen() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('ALLE BESTELLUNGEN LEEREN?', style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text('Die importierten Bestellungen aller ${_bestellungen.length} Wache(n) werden entfernt.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ABBRECHEN')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('LEEREN', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) {
      setState(() {
        _bestellungen.clear();
        _ausgewaehlteWache = null;
      });
      await _bestellungenSpeichern();
    }
  }

  Future<void> _bestellungEntfernen(String wache) async {
    setState(() {
      _bestellungen.remove(wache);
      if (_ausgewaehlteWache == wache) {
        _ausgewaehlteWache = _bestellungen.keys.isNotEmpty ? _bestellungen.keys.first : null;
      }
    });
    await _bestellungenSpeichern();
  }

  Future<void> _toggleAbgehakt(BestellPosition pos) async {
    setState(() {
      pos.abgehakt = !pos.abgehakt;
      if (pos.abgehakt) pos.nichtVerfuegbar = false;
    });
    await _bestellungenSpeichern();
  }

  /// Hakt eine ganze Sammel-Gruppe (Artikel an einem Lagerort, über alle
  /// Wachen hinweg) auf einmal ab bzw. wieder zurück.
  Future<void> _toggleGruppe(List<BestellPosition> gruppe) async {
    final neuerStatus = !gruppe.every((p) => p.abgehakt);
    setState(() {
      for (final p in gruppe) {
        p.abgehakt = neuerStatus;
        if (neuerStatus) p.nichtVerfuegbar = false;
      }
    });
    await _bestellungenSpeichern();
  }

  /// Markiert eine einzelne Position (für eine Wache) als nicht verfügbar
  /// bzw. hebt diese Markierung wieder auf. Schließt sich mit "erledigt" aus.
  Future<void> _toggleNichtVerfuegbar(BestellPosition pos) async {
    setState(() {
      pos.nichtVerfuegbar = !pos.nichtVerfuegbar;
      if (pos.nichtVerfuegbar) pos.abgehakt = false;
    });
    await _bestellungenSpeichern();
  }

  /// Alle Positionen aller offenen Bestellungen, die als "nicht verfügbar"
  /// markiert wurden, gruppiert nach Wache.
  Map<String, List<BestellPosition>> _nichtVerfuegbarNachWache() {
    final result = <String, List<BestellPosition>>{};
    for (final entry in _bestellungen.entries) {
      final betroffen = entry.value.positionen.where((p) => p.nichtVerfuegbar).toList()
        ..sort((a, b) => _artikelVergleich(a.name, b.name));
      if (betroffen.isNotEmpty) result[entry.key] = betroffen;
    }
    return result;
  }

  void _nichtVerfuegbarAnzeigen() {
    final byWache = _nichtVerfuegbarNachWache();
    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
            child: Row(children: [
              const Icon(Icons.report_gmailerrorred_outlined, color: Colors.orange, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('NICHT BEREITGESTELLTE ARTIKEL',
                    style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.0, color: Colors.white)),
              ),
              IconButton(icon: const Icon(Icons.close, color: Colors.grey), onPressed: () => Navigator.pop(ctx)),
            ]),
          ),
          Expanded(
            child: byWache.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('Bisher wurde nichts als nicht verfügbar markiert.',
                          textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
                    ),
                  )
                : ListView(
                    controller: scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                    children: byWache.entries.map((entry) {
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 6),
                          child: Text('RW ${entry.key}',
                              style: const TextStyle(color: _red, fontWeight: FontWeight.bold, letterSpacing: 0.6)),
                        ),
                        ...entry.value.map((pos) => Container(
                              margin: const EdgeInsets.symmetric(vertical: 3),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: Colors.orange.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
                              ),
                              child: Row(children: [
                                Expanded(
                                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(pos.name,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                                    Text(_lagerortFuer(pos) ?? 'Lagerort unbekannt',
                                        style: const TextStyle(color: Colors.grey, fontSize: 12)),
                                  ]),
                                ),
                                Text('${pos.menge} ${pos.einheit}',
                                    style: const TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
                              ]),
                            )),
                      ]);
                    }).toList(),
                  ),
          ),
        ]),
      ),
    );
  }

  List<_AggregatEintrag> _buildAggregat() {
    final Map<String, _AggregatEintrag> byKey = {};
    for (final entry in _bestellungen.entries) {
      final wache = entry.key;
      for (final pos in entry.value.positionen) {
        final ort = _lagerortFuer(pos) ?? 'Lagerort unbekannt';
        final key = '${pos.name} $ort';
        byKey.putIfAbsent(key, () => _AggregatEintrag(pos.name, ort, [])).proWache.add(MapEntry(wache, pos));
      }
    }
    final list = byKey.values.toList()..sort((a, b) => _artikelVergleich(a.name, b.name));
    return list;
  }

  /// Lagerort je Position im Hauptlager auflösen. Die Bestellung kommt von
  /// einem Außenlager (Wache), kommissioniert wird aber immer im einen
  /// zentralen Hauptlager – die Lagerorte sind unabhängig davon, welche
  /// Wache bestellt hat.
  String? _lagerortFuer(BestellPosition pos) {
    final liste = _lager[_aktivesLager];
    if (liste == null) return null;
    final gesucht = pos.name.trim().toLowerCase();
    for (final a in liste) {
      if (a.name.trim().toLowerCase() == gesucht) return a.lagerort;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _tab == 0 ? _buildKommissionierenTab() : _buildLagerlisteTab(),
      ),
      bottomNavigationBar: NavigationBar(
        backgroundColor: _card,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.playlist_add_check), label: 'Kommissionieren'),
          NavigationDestination(icon: Icon(Icons.warehouse_outlined), label: 'Lagerliste'),
        ],
      ),
    );
  }

  // ---------------- UI: Kommissionieren ----------------

  Widget _buildKommissionierenTab() {
    return Column(children: [
      AppBar(
        backgroundColor: _card,
        automaticallyImplyLeading: false,
        title: const Text('KOMMISSIONIEREN', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        actions: [
          if (_bestellungen.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.report_gmailerrorred_outlined),
              tooltip: 'Nicht bereitgestellte Artikel anzeigen',
              onPressed: _nichtVerfuegbarAnzeigen,
            ),
          if (_bestellungen.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: 'Alle Bestellungen leeren',
              onPressed: _allesLeerenBestaetigen,
            ),
          IconButton(
            icon: _isParsingBestellung
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _red))
                : const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Bestellung (PDF) importieren',
            onPressed: _isParsingBestellung ? null : _bestellungPdfImportieren,
          ),
        ],
      ),
      if (_bestellFehler != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_bestellFehler!, style: const TextStyle(color: Colors.red)),
        ),
      if (_bestellungen.isEmpty)
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.playlist_add_check, size: 60, color: Colors.grey),
                const SizedBox(height: 16),
                const Text(
                  'Noch keine Bestellung importiert.\nOben rechts eine Bestellung (PDF) hochladen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ]),
            ),
          ),
        )
      else ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('SAMMELLISTE'), icon: Icon(Icons.inventory_2_outlined)),
              ButtonSegment(value: 1, label: Text('JE WACHE'), icon: Icon(Icons.local_shipping_outlined)),
            ],
            selected: {_kommAnsicht},
            onSelectionChanged: (s) => setState(() => _kommAnsicht = s.first),
            style: SegmentedButton.styleFrom(
              backgroundColor: _card,
              foregroundColor: Colors.white70,
              selectedBackgroundColor: _red,
              selectedForegroundColor: Colors.white,
            ),
          ),
        ),
        Expanded(child: _kommAnsicht == 0 ? _buildSammelliste() : _buildJeWache()),
      ],
    ]);
  }

  Widget _buildLagerlisteWarnung() {
    if (_lager[_aktivesLager] != null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(children: [
        const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
        const SizedBox(width: 6),
        const Expanded(
          child: Text(
            'Es ist noch keine Lagerliste des Hauptlagers importiert – Lagerorte können nicht zugeordnet werden.',
            style: TextStyle(color: Colors.orange, fontSize: 12),
          ),
        ),
      ]),
    );
  }

  Widget _buildLocationHeader(String ort) {
    final unbekannt = ort == 'Lagerort unbekannt';
    return Container(
      margin: const EdgeInsets.only(top: 12, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: (unbekannt ? Colors.orange : _red).withValues(alpha: 0.4)),
      ),
      child: Row(children: [
        Icon(unbekannt ? Icons.help_outline : Icons.location_on,
            color: unbekannt ? Colors.orange : _red, size: 16),
        const SizedBox(width: 8),
        Text(ort.toUpperCase(),
            style: TextStyle(
                color: unbekannt ? Colors.orange : Colors.white,
                fontWeight: FontWeight.bold, letterSpacing: 1.2)),
      ]),
    );
  }

  // ---- Sammelliste: über alle Wachen aggregiert ----

  Widget _buildSammelliste() {
    final aggregat = _buildAggregat();
    final byOrt = <String, List<_AggregatEintrag>>{};
    for (final a in aggregat) {
      byOrt.putIfAbsent(a.lagerort, () => []).add(a);
    }
    final keys = byOrt.keys.toList()
      ..sort((a, b) => _lagerortSortKey(a).compareTo(_lagerortSortKey(b)));
    final erledigt = aggregat.where((a) => a.abgehakt).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(children: [
          Expanded(
            child: Text('${_bestellungen.length} Wache(n) offen: ${_bestellungen.keys.join(', ')}',
                style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          Text('$erledigt / ${aggregat.length}', style: const TextStyle(color: _red, fontWeight: FontWeight.bold)),
        ]),
      ),
      _buildLagerlisteWarnung(),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          children: keys.map((ort) {
            final items = byOrt[ort]!;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _buildLocationHeader(ort),
              ...items.map(_buildAggregatCard),
            ]);
          }).toList(),
        ),
      ),
    ]);
  }

  Widget _buildAggregatCard(_AggregatEintrag a) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        color: a.abgehakt ? Colors.green.withValues(alpha: 0.08) : _card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: a.abgehakt ? Colors.green.withValues(alpha: 0.4) : Colors.white10),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a.name,
                  style: TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16,
                      color: a.abgehakt ? Colors.white38 : Colors.white,
                      decoration: a.abgehakt ? TextDecoration.lineThrough : null)),
              const SizedBox(height: 8),
              ...a.proWache.map((e) => Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                      Text('${e.value.menge} ${e.value.einheit}',
                          style: TextStyle(
                              color: e.value.nichtVerfuegbar ? Colors.orange : Colors.white60,
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              decoration: e.value.nichtVerfuegbar ? TextDecoration.lineThrough : null)),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text('RW ${e.key}',
                            style: TextStyle(
                                color: e.value.nichtVerfuegbar ? Colors.orange : Colors.grey, fontSize: 13),
                            overflow: TextOverflow.ellipsis),
                      ),
                      SizedBox(
                        width: 26, height: 26,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 15,
                          icon: Icon(
                            e.value.nichtVerfuegbar ? Icons.report : Icons.report_gmailerrorred_outlined,
                            color: e.value.nichtVerfuegbar ? Colors.orange : Colors.white24,
                          ),
                          tooltip: 'Für RW ${e.key} als nicht verfügbar markieren',
                          onPressed: () => _toggleNichtVerfuegbar(e.value),
                        ),
                      ),
                    ]),
                  )),
            ]),
          ),
          const SizedBox(width: 12),
          Column(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _red.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _red.withValues(alpha: 0.4)),
              ),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Text('AUS DEM SCHRANK',
                    style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: Colors.grey, letterSpacing: 0.6)),
                Text('${a.gesamt}',
                    style: const TextStyle(color: _red, fontWeight: FontWeight.bold, fontSize: 18)),
                Text(a.einheit, style: const TextStyle(color: Colors.grey, fontSize: 10)),
              ]),
            ),
            const SizedBox(height: 8),
            GestureDetector(
              onTap: () => _toggleGruppe(a.proWache.map((e) => e.value).toList()),
              child: Container(
                width: 36, height: 36,
                decoration: BoxDecoration(
                  color: (a.abgehakt ? Colors.green : Colors.white).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                  border: Border.all(color: a.abgehakt ? Colors.green : Colors.white24, width: 1.5),
                ),
                child: Icon(Icons.check, color: a.abgehakt ? Colors.green : Colors.white38, size: 18),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  // ---- Je Wache: einzelne Bestellung ----

  Widget _buildJeWache() {
    final wachen = _bestellungen.keys.toList()..sort();
    final ausgewaehlt =
        (_ausgewaehlteWache != null && wachen.contains(_ausgewaehlteWache)) ? _ausgewaehlteWache! : wachen.first;
    final bestellung = _bestellungen[ausgewaehlt]!;
    final erledigt = bestellung.positionen.where((p) => p.abgehakt).length;

    final byOrt = <String, List<BestellPosition>>{};
    final sortiert = List<BestellPosition>.from(bestellung.positionen)
      ..sort((a, b) => _artikelVergleich(a.name, b.name));
    for (final pos in sortiert) {
      final ort = _lagerortFuer(pos) ?? 'Lagerort unbekannt';
      byOrt.putIfAbsent(ort, () => []).add(pos);
    }
    final keys = byOrt.keys.toList()
      ..sort((a, b) => _lagerortSortKey(a).compareTo(_lagerortSortKey(b)));

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 4),
        child: Row(children: [
          DropdownButton<String>(
            value: ausgewaehlt,
            dropdownColor: _card,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            items: wachen.map((w) => DropdownMenuItem(value: w, child: Text(w))).toList(),
            onChanged: (v) => setState(() => _ausgewaehlteWache = v),
          ),
          const Spacer(),
          Text('$erledigt / ${bestellung.positionen.length}',
              style: const TextStyle(color: _red, fontWeight: FontWeight.bold)),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
            tooltip: 'Diese Bestellung entfernen',
            onPressed: () => _bestellungEntfernen(ausgewaehlt),
          ),
        ]),
      ),
      if (bestellung.bestellNr != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text('Bestellung ${bestellung.bestellNr}', style: const TextStyle(color: Colors.grey, fontSize: 12)),
        ),
      _buildLagerlisteWarnung(),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          children: keys.map((ort) {
            final items = byOrt[ort]!;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _buildLocationHeader(ort),
              ...items.map((pos) => Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      color: pos.nichtVerfuegbar
                          ? Colors.orange.withValues(alpha: 0.08)
                          : (pos.abgehakt ? Colors.green.withValues(alpha: 0.08) : _card),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: pos.nichtVerfuegbar
                          ? Colors.orange.withValues(alpha: 0.4)
                          : (pos.abgehakt ? Colors.green.withValues(alpha: 0.4) : Colors.white10)),
                    ),
                    child: CheckboxListTile(
                      value: pos.abgehakt,
                      onChanged: (_) => _toggleAbgehakt(pos),
                      activeColor: Colors.green,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(pos.name,
                          style: TextStyle(
                              color: pos.nichtVerfuegbar
                                  ? Colors.orange
                                  : (pos.abgehakt ? Colors.white38 : Colors.white),
                              decoration: (pos.abgehakt || pos.nichtVerfuegbar) ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600)),
                      subtitle: Text(
                          pos.nichtVerfuegbar
                              ? '${pos.menge} ${pos.einheit} · nicht verfügbar'
                              : '${pos.menge} ${pos.einheit}',
                          style: TextStyle(color: pos.nichtVerfuegbar ? Colors.orange : Colors.grey, fontSize: 12)),
                      secondary: IconButton(
                        icon: Icon(
                          pos.nichtVerfuegbar ? Icons.report : Icons.report_gmailerrorred_outlined,
                          color: pos.nichtVerfuegbar ? Colors.orange : Colors.white24,
                        ),
                        tooltip: 'Als nicht verfügbar markieren',
                        onPressed: () => _toggleNichtVerfuegbar(pos),
                      ),
                    ),
                  )),
            ]);
          }).toList(),
        ),
      ),
    ]);
  }

  // ---------------- UI: Lagerliste ----------------

  Widget _buildLagerlisteTab() {
    final ergebnisse = _gefiltert;
    return Column(children: [
      AppBar(
        backgroundColor: _card,
        automaticallyImplyLeading: false,
        title: const Text('LAGERLISTE', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        actions: [
          IconButton(
            icon: _isSyncingLager
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _red))
                : const Icon(Icons.sync),
            tooltip: 'Von der Datenbank aktualisieren',
            onPressed: _isSyncingLager ? null : _lagerVonDbLaden,
          ),
          IconButton(
            icon: _isParsingLager
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _red))
                : const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Inventurliste (PDF) importieren',
            onPressed: _isParsingLager ? null : _lagerPdfImportieren,
          ),
        ],
      ),
      if (_lagerFehler != null)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(_lagerFehler!, style: const TextStyle(color: Colors.red)),
        ),
      if (_lager.isEmpty)
        Expanded(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Icon(Icons.location_off_outlined, size: 60, color: Colors.grey),
                const SizedBox(height: 16),
                const Text(
                  'Noch keine Lagerliste importiert.\nOben rechts eine Inventurliste (PDF) hochladen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
              ]),
            ),
          ),
        )
      else ...[
        if (_lager.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(children: [
              const Icon(Icons.warehouse_outlined, color: _red, size: 18),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _aktivesLager,
                dropdownColor: _card,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                items: _lager.keys.map((k) => DropdownMenuItem(value: k, child: Text(k))).toList(),
                onChanged: (v) => setState(() => _aktivesLager = v),
              ),
              const Spacer(),
              if (_aktivesLager != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                  tooltip: 'Diese Lagerliste entfernen',
                  onPressed: () => _lagerLoeschen(_aktivesLager!),
                ),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _searchCtrl,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
            decoration: InputDecoration(
              filled: true,
              fillColor: _card,
              hintText: 'ARTIKEL SUCHEN',
              hintStyle: const TextStyle(color: Colors.white54, fontWeight: FontWeight.bold),
              prefixIcon: const Icon(Icons.search, color: _red),
              suffixIcon: _searchCtrl.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear, color: Colors.white54), onPressed: _searchCtrl.clear)
                  : null,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(value: 0, label: Text('NACH ARTIKEL'), icon: Icon(Icons.sort_by_alpha)),
              ButtonSegment(value: 1, label: Text('NACH LAGERORT'), icon: Icon(Icons.location_on_outlined)),
            ],
            selected: {_lagerlisteSortierung},
            onSelectionChanged: (s) => setState(() => _lagerlisteSortierung = s.first),
            style: SegmentedButton.styleFrom(
              backgroundColor: _card,
              foregroundColor: Colors.white70,
              selectedBackgroundColor: _red,
              selectedForegroundColor: Colors.white,
            ),
          ),
        ),
        Expanded(
          child: ergebnisse.isEmpty
              ? const Center(child: Text('Kein Artikel gefunden', style: TextStyle(color: Colors.grey)))
              : _lagerlisteSortierung == 1
                  ? _buildLagerlisteNachOrt(ergebnisse)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                      itemCount: ergebnisse.length,
                      itemBuilder: (_, i) => _buildArtikelKarte(ergebnisse[i]),
                    ),
        ),
      ],
    ]);
  }

  Widget _buildArtikelKarte(ArtikelOrt item) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: ListTile(
        title: Text(item.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: _red.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _red.withValues(alpha: 0.5)),
          ),
          child: Text(item.lagerort, style: const TextStyle(color: _red, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  /// Artikel gruppiert nach Lagerort (mit Location-Header), Lagerorte in
  /// derselben Reihenfolge wie beim Kommissionieren, Artikel je Lagerort
  /// natürlich sortiert.
  Widget _buildLagerlisteNachOrt(List<ArtikelOrt> ergebnisse) {
    final byOrt = <String, List<ArtikelOrt>>{};
    for (final a in ergebnisse) {
      byOrt.putIfAbsent(a.lagerort, () => []).add(a);
    }
    final keys = byOrt.keys.toList()
      ..sort((a, b) => _lagerortSortKey(a).compareTo(_lagerortSortKey(b)));

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
      children: keys.map((ort) {
        final items = byOrt[ort]!;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _buildLocationHeader(ort),
          ...items.map(_buildArtikelKarte),
        ]);
      }).toList(),
    );
  }
}
