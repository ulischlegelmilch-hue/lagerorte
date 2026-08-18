import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

const _red = Color(0xFFE30613);
const _bg = Color(0xFF121212);
const _card = Color(0xFF1E1E22);

void main() {
  runApp(const LagerorteApp());
}

class LagerorteApp extends StatelessWidget {
  const LagerorteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lagerorte',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: _bg,
        colorScheme: const ColorScheme.dark(primary: _red, surface: _card),
      ),
      home: const LagerorteScreen(),
    );
  }
}

class ArtikelOrt {
  final String name;
  final String lagerort;
  ArtikelOrt(this.name, this.lagerort);
  Map<String, String> toJson() => {'n': name, 'l': lagerort};
  factory ArtikelOrt.fromJson(Map<String, dynamic> m) =>
      ArtikelOrt(m['n'] as String, m['l'] as String);
}

class LagerorteScreen extends StatefulWidget {
  const LagerorteScreen({super.key});
  @override
  State<LagerorteScreen> createState() => _LagerorteScreenState();
}

class _LagerorteScreenState extends State<LagerorteScreen> {
  final Map<String, List<ArtikelOrt>> _lager = {};
  String? _aktivesLager;
  final _searchCtrl = TextEditingController();
  bool _isParsing = false;
  String? _fehler;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() => setState(() {}));
    _laden();
  }

  Future<void> _laden() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('lager_daten');
    if (raw == null) return;
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    setState(() {
      _lager.clear();
      decoded.forEach((lager, liste) {
        _lager[lager] = (liste as List)
            .map((e) => ArtikelOrt.fromJson(e as Map<String, dynamic>))
            .toList();
      });
      _aktivesLager = _lager.keys.isNotEmpty ? _lager.keys.first : null;
    });
  }

  Future<void> _speichern() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_lager.map(
        (lager, liste) => MapEntry(lager, liste.map((e) => e.toJson()).toList())));
    await prefs.setString('lager_daten', encoded);
  }

  Future<void> _pdfImportieren() async {
    setState(() => _fehler = null);
    final result = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
    if (result.isEmpty) return;
    final picked = result.first;

    setState(() => _isParsing = true);
    try {
      final bytes = await picked.readAsBytes();
      final document = PdfDocument(inputBytes: bytes);
      final buffer = StringBuffer();
      for (var i = 0; i < document.pages.count; i++) {
        buffer.writeln(PdfTextExtractor(document).extractText(startPageIndex: i));
      }
      document.dispose();
      final text = buffer.toString();

      final lagerMatch = RegExp(r'Inventurliste\s+Lager\s+(.+)').firstMatch(text);
      final lagerName = lagerMatch?.group(1)?.trim() ?? picked.name.replaceAll('.pdf', '');

      final items = _parseInventurliste(text);
      if (items.isEmpty) {
        setState(() => _fehler = 'Es konnten keine Artikel in dieser PDF erkannt werden.');
        return;
      }

      setState(() {
        _lager[lagerName] = items;
        _aktivesLager = lagerName;
      });
      await _speichern();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$lagerName: ${items.length} Artikel importiert'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      setState(() => _fehler = 'PDF konnte nicht gelesen werden: $e');
    } finally {
      if (mounted) setState(() => _isParsing = false);
    }
  }

  /// Baut aus dem "Inventurliste"-PDF (Spalten: Artikelnummer, Lagerort,
  /// Stückpreis, Einheit, Ist-Bestand, Artikelbeschreibung, Preis-Zeile 2)
  /// eine reine Name->Lagerort-Zuordnung. Der PDF-Textextraktor legt jede
  /// Tabellenzelle als eigene Zeile ab, getrennt durch Leerzeilen; das
  /// Einheit-Feld fehlt bei manchen Zeilen ganz.
  List<ArtikelOrt> _parseInventurliste(String text) {
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
        items.add(ArtikelOrt(_bereinigeName(name, einheit), lagerort));
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

  static const _einheitFamilien = <String, List<String>>{
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
  /// dieser Zeile passt (z.B. "(Stück)" bei Einheit "Stück"). Klammern mit
  /// Artikelmerkmalen (Farbe, Größe, ...) bleiben erhalten.
  String _bereinigeName(String name, String einheit) {
    if (einheit.isEmpty) return name;
    final m = RegExp(r'^(.*)\(([^()]*)\)\s*$').firstMatch(name);
    if (m == null) return name;
    final klammerInhalt = m.group(2)!;
    if (_familien(klammerInhalt).intersection(_familien(einheit)).isNotEmpty) {
      return m.group(1)!.trim();
    }
    return name;
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

  Future<void> _lagerLoeschen(String lager) async {
    setState(() {
      _lager.remove(lager);
      if (_aktivesLager == lager) {
        _aktivesLager = _lager.keys.isNotEmpty ? _lager.keys.first : null;
      }
    });
    await _speichern();
  }

  @override
  Widget build(BuildContext context) {
    final ergebnisse = _gefiltert;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: _card,
        title: const Text('LAGERORTE', style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        actions: [
          IconButton(
            icon: _isParsing
                ? const SizedBox(width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: _red))
                : const Icon(Icons.picture_as_pdf_outlined),
            tooltip: 'Inventurliste (PDF) importieren',
            onPressed: _isParsing ? null : _pdfImportieren,
          ),
        ],
      ),
      body: Column(children: [
        if (_fehler != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_fehler!, style: const TextStyle(color: Colors.red)),
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
                  items: _lager.keys
                      .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                      .toList(),
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
              autofocus: true,
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
                            child: Text(item.lagerort,
                                style: const TextStyle(color: _red, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ]),
    );
  }
}
