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
      title: 'Kommissionieren',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _red, surface: _card),
      ),
      home: const RootScreen(),
    );
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
  String? _bestellNr;
  String? _bestellWache;
  List<BestellPosition> _positionen = [];
  bool _isParsingBestellung = false;
  String? _bestellFehler;

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

    final rawBestellung = prefs.getString('aktuelle_bestellung');
    if (rawBestellung != null) {
      final decoded = jsonDecode(rawBestellung) as Map<String, dynamic>;
      _bestellNr = decoded['nr'] as String?;
      _bestellWache = decoded['wache'] as String?;
      _positionen = (decoded['positionen'] as List)
          .map((e) => BestellPosition.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {});
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

  Future<void> _bestellungSpeichern() async {
    final prefs = await SharedPreferences.getInstance();
    if (_positionen.isEmpty) {
      await prefs.remove('aktuelle_bestellung');
      return;
    }
    final encoded = jsonEncode({
      'nr': _bestellNr,
      'wache': _bestellWache,
      'positionen': _positionen.map((e) => e.toJson()).toList(),
    });
    await prefs.setString('aktuelle_bestellung', encoded);
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
    gefiltert.sort((a, b) => a.name.compareTo(b.name));
    return gefiltert;
  }

  // ---------------- Bestellung-Import / Kommissionieren ----------------

  Future<void> _bestellungPdfImportieren() async {
    setState(() => _bestellFehler = null);
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty) return;
    final picked = result.first;

    setState(() => _isParsingBestellung = true);
    try {
      final bytes = await picked.readAsBytes();
      final text = extractPdfText(bytes);
      final bestellung = parseBestellung(text, _bekannteWachen);

      if (bestellung.positionen.isEmpty) {
        setState(() => _bestellFehler = 'Es konnten keine Positionen in dieser PDF erkannt werden.');
        return;
      }

      setState(() {
        _bestellNr = bestellung.bestellNr;
        _bestellWache = bestellung.wache;
        _positionen = bestellung.positionen;
      });
      await _bestellungSpeichern();
    } catch (e) {
      setState(() => _bestellFehler = 'PDF konnte nicht gelesen werden: $e');
    } finally {
      if (mounted) setState(() => _isParsingBestellung = false);
    }
  }

  Future<void> _bestellungZuruecksetzen() async {
    setState(() {
      _bestellNr = null;
      _bestellWache = null;
      _positionen = [];
    });
    await _bestellungSpeichern();
  }

  Future<void> _toggleAbgehakt(BestellPosition pos) async {
    setState(() => pos.abgehakt = !pos.abgehakt);
    await _bestellungSpeichern();
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
          if (_positionen.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Neue Bestellung importieren',
              onPressed: _bestellungZuruecksetzen,
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
      Expanded(
        child: _positionen.isEmpty
            ? Center(
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
              )
            : _buildKommissionierListe(),
      ),
    ]);
  }

  Widget _buildKommissionierListe() {
    final erledigt = _positionen.where((p) => p.abgehakt).length;
    final byLagerort = <String, List<BestellPosition>>{};
    final sortiert = List<BestellPosition>.from(_positionen)
      ..sort((a, b) => a.name.compareTo(b.name));
    for (final pos in sortiert) {
      final ort = _lagerortFuer(pos) ?? 'Lagerort unbekannt';
      byLagerort.putIfAbsent(ort, () => []).add(pos);
    }
    final keys = byLagerort.keys.toList()
      ..sort((a, b) {
        if (a == 'Lagerort unbekannt') return -1;
        if (b == 'Lagerort unbekannt') return 1;
        return a.compareTo(b);
      });

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          Expanded(
            child: Text(
              [
                if (_bestellWache != null) _bestellWache! else 'Wache unbekannt',
                if (_bestellNr != null) 'Bestellung $_bestellNr',
              ].join(' · '),
              style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.bold),
            ),
          ),
          Text('$erledigt / ${_positionen.length}',
              style: const TextStyle(color: _red, fontWeight: FontWeight.bold)),
        ]),
      ),
      if (_lager[_aktivesLager] == null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Row(children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.orange, size: 16),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Es ist noch keine Lagerliste des Hauptlagers importiert – Lagerorte können nicht zugeordnet werden.',
                style: const TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
          ]),
        ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
          children: keys.map((ort) {
            final items = byLagerort[ort]!;
            final unbekannt = ort == 'Lagerort unbekannt';
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
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
              ),
              ...items.map((pos) => Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      color: pos.abgehakt ? Colors.green.withValues(alpha: 0.08) : _card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: pos.abgehakt ? Colors.green.withValues(alpha: 0.4) : Colors.white10),
                    ),
                    child: CheckboxListTile(
                      value: pos.abgehakt,
                      onChanged: (_) => _toggleAbgehakt(pos),
                      activeColor: Colors.green,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: Text(pos.name,
                          style: TextStyle(
                              color: pos.abgehakt ? Colors.white38 : Colors.white,
                              decoration: pos.abgehakt ? TextDecoration.lineThrough : null,
                              fontWeight: FontWeight.w600)),
                      subtitle: Text('${pos.menge} ${pos.einheit}',
                          style: const TextStyle(color: Colors.grey, fontSize: 12)),
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
        Expanded(
          child: ergebnisse.isEmpty
              ? const Center(child: Text('Kein Artikel gefunden', style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 20),
                  itemCount: ergebnisse.length,
                  itemBuilder: (_, i) {
                    final item = ergebnisse[i];
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
                  },
                ),
        ),
      ],
    ]);
  }
}
