import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const ScanPiecesApp());

const Color kEncre = Color(0xFF3438A8);

class ScanPiecesApp extends StatelessWidget {
  const ScanPiecesApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ScanPièces',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: kEncre, useMaterial3: true),
      darkTheme: ThemeData(
          colorSchemeSeed: kEncre,
          brightness: Brightness.dark,
          useMaterial3: true),
      home: const HomeScreen(),
    );
  }
}

/* ===================== Modèle ===================== */

enum Mode { carte, passeport, document }

class Scan {
  final Uint8List bytes;
  final int w;
  final int h;
  const Scan(this.bytes, this.w, this.h);
}

/// Prépare une image : orientation EXIF, rotation, paysage forcé, taille max.
Future<Scan> preparer(Uint8List brut,
    {bool paysage = false, int tailleMax = 2200, int rotation = 0}) {
  return Isolate.run(() {
    var im = img.decodeImage(brut);
    if (im == null) throw Exception('Image illisible');
    im = img.bakeOrientation(im);
    if (rotation != 0) im = img.copyRotate(im, angle: rotation);
    if (paysage && im.height > im.width) im = img.copyRotate(im, angle: -90);
    final long = im.width > im.height ? im.width : im.height;
    if (long > tailleMax) {
      im = im.width >= im.height
          ? img.copyResize(im,
              width: tailleMax, interpolation: img.Interpolation.average)
          : img.copyResize(im,
              height: tailleMax, interpolation: img.Interpolation.average);
    }
    return Scan(Uint8List.fromList(img.encodeJpg(im, quality: 90)), im.width,
        im.height);
  });
}

/// Lance le scanner Google ML Kit (détection des bords, recadrage, filtres).
Future<List<Uint8List>> lancerScanner(BuildContext context, int pages) async {
  final scanner = DocumentScanner(
    options: DocumentScannerOptions(
      mode: ScannerMode.full,
      pageLimit: pages,
      isGalleryImport: true,
    ),
  );
  try {
    final res = await scanner.scanDocument();
    final paths = (res.images as List?)?.cast<String>() ?? <String>[];
    final out = <Uint8List>[];
    for (final p in paths) {
      out.add(await File(p).readAsBytes());
    }
    return out;
  } catch (e) {
    final msg = e.toString().toLowerCase();
    if (!msg.contains('cancel') && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Le scanner n\'a pas pu démarrer. Vérifiez que les services Google Play sont à jour. ($e)')));
    }
    return [];
  } finally {
    scanner.close();
  }
}

/* ===================== Mise en page A4 (en mm) ===================== */

class Bloc {
  final Scan? scan;
  final String label;
  final Rect rect; // en mm
  final double rayon; // en mm
  const Bloc(this.scan, this.label, this.rect, this.rayon);
}

class PageA4 {
  final bool paysage;
  final List<Bloc> blocs;
  const PageA4(this.paysage, this.blocs);
  double get largeur => paysage ? 297 : 210;
  double get hauteur => paysage ? 210 : 297;
}

PageA4 pageCarte(Scan? recto, Scan? verso, bool reel) {
  if (reel) {
    const cw = 85.6, ch = 54.0, gap = 8.0, y = 20.0;
    const x0 = (210 - 2 * cw - gap) / 2;
    return PageA4(false, [
      Bloc(recto, 'Recto', const Rect.fromLTWH(x0, y, cw, ch), 3.18),
      Bloc(verso, 'Verso', const Rect.fromLTWH(x0 + cw + gap, y, cw, ch), 3.18),
    ]);
  }
  const gap = 10.0, x0 = 12.0;
  const cw = (297 - 24 - gap) / 2;
  const ch = cw * 54 / 85.6;
  const y = (210 - ch) / 2;
  const r = 3.18 * cw / 85.6;
  return PageA4(true, [
    Bloc(recto, 'Recto', const Rect.fromLTWH(x0, y, cw, ch), r),
    Bloc(verso, 'Verso', const Rect.fromLTWH(x0 + cw + gap, y, cw, ch), r),
  ]);
}

PageA4 pagePasseport(Scan? haut, Scan? id, bool reel) {
  final w = reel ? 125.0 : 180.0;
  final h = w * 88 / 125;
  final x0 = (210 - w) / 2;
  final y0 = reel ? 20.0 : (297 - 2 * h) / 2;
  return PageA4(false, [
    Bloc(haut, 'Page du haut', Rect.fromLTWH(x0, y0, w, h), 0),
    Bloc(id, 'Page d\'identité', Rect.fromLTWH(x0, y0 + h, w, h), 0),
  ]);
}

PageA4 pageDocument(Scan s) {
  final paysage = s.w > s.h * 1.05;
  final pw_ = paysage ? 297.0 : 210.0, ph = paysage ? 210.0 : 297.0;
  const marge = 8.0;
  final k = [(pw_ - 2 * marge) / s.w, (ph - 2 * marge) / s.h]
      .reduce((a, b) => a < b ? a : b);
  final w = s.w * k, h = s.h * k;
  return PageA4(paysage, [
    Bloc(s, 'Page', Rect.fromLTWH((pw_ - w) / 2, (ph - h) / 2, w, h), 0),
  ]);
}

Future<Uint8List> construirePdf(List<PageA4> pages, String titre) async {
  final doc = pw.Document(title: titre, author: 'ScanPièces');
  const mm = PdfPageFormat.mm;
  for (final p in pages) {
    final fmt = p.paysage ? PdfPageFormat.a4.landscape : PdfPageFormat.a4;
    final enfants = <pw.Widget>[];
    for (final b in p.blocs) {
      final s = b.scan;
      if (s == null) continue;
      final image = pw.Image(pw.MemoryImage(s.bytes),
          width: b.rect.width * mm,
          height: b.rect.height * mm,
          fit: pw.BoxFit.fill);
      enfants.add(pw.Positioned(
        left: b.rect.left * mm,
        top: b.rect.top * mm,
        child: b.rayon > 0
            ? pw.ClipRRect(
                horizontalRadius: b.rayon * mm,
                verticalRadius: b.rayon * mm,
                child: image)
            : image,
      ));
    }
    doc.addPage(pw.Page(
      pageFormat: fmt,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Container(
          width: fmt.width,
          height: fmt.height,
          color: PdfColors.white,
          child: pw.Stack(children: enfants)),
    ));
  }
  return doc.save();
}

/* ===================== Menu ===================== */

void quitterAppli() => SystemNavigator.pop();

const kLienPlayStore =
    'https://play.google.com/store/apps/details?id=com.nigbou.scanpieces';
const kWhatsApp = 'https://wa.me/22671349749';
const kTelegram = 'https://t.me/Leuk18';
const kFacebook = 'https://www.facebook.com/nigbouaischool';

Future<void> ouvrirLien(String url) async {
  try {
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {}
}

void partagerAppli() => SharePlus.instance.share(ShareParams(
    text: 'ScanPièces : scanne ta CNIB, ton permis ou ton passeport, '
        'recto et verso sur une seule page, en PDF prêt à envoyer. '
        'Gratuit et sans filigrane.\n$kLienPlayStore'));

void aPropos(BuildContext context) {
  final cs = Theme.of(context).colorScheme;
  Widget lien(IconData ic, String t, String url) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(ic, color: cs.primary),
        title: Text(t),
        onTap: () => ouvrirLien(url),
      );
  showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('ScanPièces'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Version 1.2 · une appli NIGBOU AI',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            const Text('Scanner de cartes, permis, passeports et documents. '
                'Recto et verso côte à côte, passeport superposé, export PDF. '
                'Vos documents restent sur votre téléphone.'),
            const SizedBox(height: 16),
            const Text('Apprenez à créer des applis comme celle-ci',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const Text('NIGBOU AI SCHOOL : formations IA, développement web '
                'et analyse sportive. « Transforme l\'IA en revenus ».'),
            const SizedBox(height: 6),
            lien(Icons.facebook, 'NIGBOU AI SCHOOL sur Facebook', kFacebook),
            lien(Icons.chat_outlined, 'WhatsApp : +226 71 34 97 49', kWhatsApp),
            lien(Icons.send_outlined, 'Telegram : t.me/Leuk18', kTelegram),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => showLicensePage(
                context: c,
                applicationName: 'ScanPièces',
                applicationVersion: '1.2'),
            child: const Text('Licences')),
        FilledButton(
            onPressed: () => Navigator.pop(c), child: const Text('Fermer')),
      ],
    ),
  );
}

class MenuLateral extends StatelessWidget {
  final Mode? actuel;
  const MenuLateral({super.key, this.actuel});

  void ouvrir(BuildContext context, Mode m) {
    Navigator.pop(context); // ferme le menu
    if (m == actuel) return;
    final route = MaterialPageRoute(builder: (_) => ScanScreen(mode: m));
    if (actuel == null) {
      Navigator.push(context, route);
    } else {
      Navigator.pushReplacement(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget item(IconData ic, String t, VoidCallback f, {bool actif = false}) =>
        ListTile(
          leading: Icon(ic),
          title: Text(t),
          selected: actif,
          onTap: f,
        );
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
              color: cs.primary,
              child: Row(children: [
                Icon(Icons.document_scanner, color: cs.onPrimary, size: 34),
                const SizedBox(width: 12),
                Text('ScanPièces',
                    style: TextStyle(
                        color: cs.onPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800)),
              ]),
            ),
            const SizedBox(height: 8),
            item(Icons.home_outlined, 'Accueil', () {
              Navigator.pop(context);
              Navigator.popUntil(context, (r) => r.isFirst);
            }, actif: actuel == null),
            const Divider(),
            item(Icons.badge_outlined, 'Carte / Permis',
                () => ouvrir(context, Mode.carte),
                actif: actuel == Mode.carte),
            item(Icons.menu_book_outlined, 'Passeport',
                () => ouvrir(context, Mode.passeport),
                actif: actuel == Mode.passeport),
            item(Icons.description_outlined, 'Document',
                () => ouvrir(context, Mode.document),
                actif: actuel == Mode.document),
            const Divider(),
            item(Icons.info_outline, 'À propos', () {
              Navigator.pop(context);
              aPropos(context);
            }),
            item(Icons.share_outlined, 'Partager l\'appli', () {
              Navigator.pop(context);
              partagerAppli();
            }),
            const Spacer(),
            item(Icons.logout, 'Quitter l\'application', quitterAppli),
            const Divider(height: 1),
            InkWell(
              onTap: () {
                Navigator.pop(context);
                aPropos(context);
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                child: Text('Une appli NIGBOU AI',
                    style: TextStyle(
                        color: cs.onSurfaceVariant,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/* ===================== Accueil ===================== */

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget tuile(Mode m, IconData ic, String titre, String sous) => Card(
          elevation: 0,
          color: cs.surfaceContainerHighest,
          child: ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            leading: CircleAvatar(
                radius: 26,
                backgroundColor: cs.primary,
                child: Icon(ic, color: cs.onPrimary, size: 28)),
            title: Text(titre,
                style:
                    const TextStyle(fontWeight: FontWeight.w700, fontSize: 18)),
            subtitle: Text(sous),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => ScanScreen(mode: m))),
          ),
        );
    return Scaffold(
      drawer: const MenuLateral(),
      appBar: AppBar(
        title: const Text('ScanPièces',
            style: TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          IconButton(
              tooltip: 'Quitter',
              onPressed: quitterAppli,
              icon: const Icon(Icons.logout)),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          tuile(Mode.carte, Icons.badge_outlined, 'Carte / Permis',
              'CNIB, permis, carte consulaire… Recto et verso côte à côte sur une page.'),
          const SizedBox(height: 10),
          tuile(Mode.passeport, Icons.menu_book_outlined, 'Passeport',
              'Les deux pages superposées sur la même feuille.'),
          const SizedBox(height: 10),
          tuile(Mode.document, Icons.description_outlined, 'Document',
              'Bulletin, attestation, contrat… une ou plusieurs pages A4.'),
          const SizedBox(height: 18),
          Text(
            'Le scanner détecte les bords automatiquement et redresse la photo. '
            'Vous pouvez aussi importer depuis la galerie.',
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: partagerAppli,
            icon: const Icon(Icons.share_outlined),
            label: const Text('Partager ScanPièces avec un ami'),
          ),
          const SizedBox(height: 24),
          Center(
            child: TextButton(
              onPressed: () => aPropos(context),
              child: Text('Une appli NIGBOU AI',
                  style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4)),
            ),
          ),
        ],
      ),
    );
  }
}

/* ===================== Écran de scan ===================== */

class ScanScreen extends StatefulWidget {
  final Mode mode;
  const ScanScreen({super.key, required this.mode});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  static const types = [
    'CNIB',
    'Permis',
    'Carte consulaire',
    'Carte d\'électeur',
    'Carte pro',
    'Carte étudiant',
    'Autre carte'
  ];
  String type = 'CNIB';
  bool reel = true;
  bool occupe = false;
  // carte : 0 = recto, 1 = verso / passeport : 0 = haut, 1 = identité
  final List<Scan?> slots = [null, null];
  final List<Scan> pages = [];
  int pageVue = 0;

  Mode get mode => widget.mode;
  bool get fixe => mode != Mode.document;

  List<PageA4> get miseEnPage {
    switch (mode) {
      case Mode.carte:
        return [pageCarte(slots[0], slots[1], reel)];
      case Mode.passeport:
        return [pagePasseport(slots[0], slots[1], reel)];
      case Mode.document:
        return pages.map(pageDocument).toList();
    }
  }

  bool get pret =>
      fixe ? (slots[0] != null || slots[1] != null) : pages.isNotEmpty;

  String get nomFichier {
    final d = DateTime.now();
    final date =
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final base = mode == Mode.carte
        ? type
        : mode == Mode.passeport
            ? 'Passeport'
            : 'Document';
    final propre = base
        .replaceAll(RegExp('[éèê]'), 'e')
        .replaceAll(RegExp(r"[^A-Za-z0-9]+"), '-');
    return '${propre}_$date';
  }

  Future<void> occuper(Future<void> Function() f) async {
    setState(() => occupe = true);
    try {
      await f();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    } finally {
      if (mounted) setState(() => occupe = false);
    }
  }

  Future<void> scannerSlot(int i) async {
    final r = await lancerScanner(context, 1);
    if (r.isEmpty) return;
    await occuper(() async {
      final s = await preparer(r.first, paysage: true, tailleMax: 1800);
      setState(() => slots[i] = s);
    });
  }

  Future<void> scannerLesDeux() async {
    final r = await lancerScanner(context, 2);
    if (r.isEmpty) return;
    await occuper(() async {
      for (var i = 0; i < r.length && i < 2; i++) {
        final s = await preparer(r[i], paysage: true, tailleMax: 1800);
        setState(() => slots[i] = s);
      }
    });
  }

  Future<void> ajouterPages() async {
    final r = await lancerScanner(context, 20);
    if (r.isEmpty) return;
    await occuper(() async {
      for (final b in r) {
        final s = await preparer(b);
        setState(() => pages.add(s));
      }
      setState(() => pageVue = pages.length - 1);
    });
  }

  Future<void> pivoterSlot(int i) => occuper(() async {
        final s = await preparer(slots[i]!.bytes,
            paysage: true, tailleMax: 1800, rotation: 180);
        setState(() => slots[i] = s);
      });

  Future<void> pivoterPage(int i) => occuper(() async {
        final s = await preparer(pages[i].bytes, rotation: 90);
        setState(() => pages[i] = s);
      });

  Future<void> partagerPdf() => occuper(() async {
        final bytes = await construirePdf(miseEnPage, nomFichier);
        await Printing.sharePdf(bytes: bytes, filename: '$nomFichier.pdf');
      });

  Future<void> imprimer() => occuper(() async {
        final bytes = await construirePdf(miseEnPage, nomFichier);
        await Printing.layoutPdf(onLayout: (_) async => bytes, name: nomFichier);
      });

  Future<void> partagerImages() => occuper(() async {
        final bytes = await construirePdf(miseEnPage, nomFichier);
        final dir = await getTemporaryDirectory();
        final fichiers = <XFile>[];
        var n = 1;
        await for (final page in Printing.raster(bytes, dpi: 200)) {
          final w = page.width, h = page.height, px = page.pixels;
          // Fond blanc garanti + JPG (léger, bien affiché sur WhatsApp)
          final jpg = await Isolate.run(() {
            final src = img.Image.fromBytes(
                width: w, height: h, bytes: px.buffer, numChannels: 4);
            final fond = img.Image(width: w, height: h);
            img.fill(fond, color: img.ColorRgb8(255, 255, 255));
            img.compositeImage(fond, src);
            return Uint8List.fromList(img.encodeJpg(fond, quality: 90));
          });
          final suffixe = pages.length > 1 ? '_p$n' : '';
          final f = File('${dir.path}/$nomFichier$suffixe.jpg');
          await f.writeAsBytes(jpg);
          fichiers.add(XFile(f.path));
          n++;
        }
        await SharePlus.instance.share(ShareParams(files: fichiers));
      });

  /* ---------- interface ---------- */

  Widget slot(int i, String label, double ratio, String dims) {
    final cs = Theme.of(context).colorScheme;
    final s = slots[i];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: ratio,
          child: Material(
            color: cs.surfaceContainerHighest,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(
                  color: s == null ? cs.outline : Colors.transparent,
                  width: 1.2),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: occupe ? null : () => scannerSlot(i),
              child: s != null
                  ? Image.memory(s.bytes, fit: BoxFit.fill)
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.document_scanner_outlined,
                              color: cs.primary, size: 28),
                          const SizedBox(height: 4),
                          Text(label,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700, fontSize: 15)),
                          Text(dims,
                              style: TextStyle(
                                  fontSize: 11, color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
            ),
          ),
        ),
        if (s != null)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                  tooltip: 'Retourner',
                  onPressed: occupe ? null : () => pivoterSlot(i),
                  icon: const Icon(Icons.rotate_right)),
              IconButton(
                  tooltip: 'Rescanner',
                  onPressed: occupe ? null : () => scannerSlot(i),
                  icon: const Icon(Icons.refresh)),
              IconButton(
                  tooltip: 'Retirer',
                  onPressed: occupe ? null : () => setState(() => slots[i] = null),
                  icon: Icon(Icons.delete_outline, color: cs.error)),
            ],
          ),
      ],
    );
  }

  Widget panneauCarte() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: types
              .map((t) => ChoiceChip(
                    label: Text(t),
                    selected: type == t,
                    onSelected: (_) => setState(() => type = t),
                  ))
              .toList(),
        ),
        const SizedBox(height: 12),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: slot(0, 'Recto', 85.6 / 54, '85,6 × 54 mm')),
            const SizedBox(width: 12),
            Expanded(child: slot(1, 'Verso', 85.6 / 54, '85,6 × 54 mm')),
          ],
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: occupe ? null : scannerLesDeux,
          icon: const Icon(Icons.flip),
          label: const Text('Scanner recto puis verso d\'un coup'),
        ),
      ],
    );
  }

  Widget panneauPasseport() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        slot(0, 'Page du haut', 125 / 88, '125 × 88 mm'),
        const SizedBox(height: 10),
        slot(1, 'Page d\'identité (photo)', 125 / 88, '125 × 88 mm'),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: occupe ? null : scannerLesDeux,
          icon: const Icon(Icons.menu_book_outlined),
          label: const Text('Scanner les 2 pages d\'un coup'),
        ),
      ],
    );
  }

  Widget panneauDocument() {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: occupe ? null : ajouterPages,
          icon: const Icon(Icons.add_a_photo_outlined),
          label: Text(pages.isEmpty ? 'Scanner des pages' : 'Ajouter des pages'),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < pages.length; i++)
          Card(
            elevation: 0,
            color: i == pageVue
                ? cs.primaryContainer
                : cs.surfaceContainerHighest,
            child: ListTile(
              onTap: () => setState(() => pageVue = i),
              leading: SizedBox(
                  width: 40,
                  height: 52,
                  child: Image.memory(pages[i].bytes, fit: BoxFit.contain)),
              title: Text('Page ${i + 1}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    tooltip: 'Monter',
                    onPressed: i == 0 || occupe
                        ? null
                        : () => setState(() {
                              final p = pages.removeAt(i);
                              pages.insert(i - 1, p);
                              pageVue = i - 1;
                            }),
                    icon: const Icon(Icons.arrow_upward)),
                IconButton(
                    tooltip: 'Pivoter',
                    onPressed: occupe ? null : () => pivoterPage(i),
                    icon: const Icon(Icons.rotate_right)),
                IconButton(
                    tooltip: 'Supprimer',
                    onPressed: occupe
                        ? null
                        : () => setState(() {
                              pages.removeAt(i);
                              if (pageVue >= pages.length) {
                                pageVue = pages.isEmpty ? 0 : pages.length - 1;
                              }
                            }),
                    icon: Icon(Icons.delete_outline, color: cs.error)),
              ]),
            ),
          ),
      ],
    );
  }

  Widget apercu() {
    final cs = Theme.of(context).colorScheme;
    final toutes = miseEnPage;
    final p = toutes.isEmpty
        ? const PageA4(false, [])
        : toutes[pageVue.clamp(0, toutes.length - 1)];
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: p.paysage ? 520 : 340),
        child: AspectRatio(
          aspectRatio: p.largeur / p.hauteur,
          child: Container(
            decoration: BoxDecoration(color: Colors.white, boxShadow: [
              BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 14,
                  offset: const Offset(0, 6)),
            ]),
            child: LayoutBuilder(builder: (context, c) {
              final k = c.maxWidth / p.largeur;
              return Stack(children: [
                for (final b in p.blocs)
                  Positioned(
                    left: b.rect.left * k,
                    top: b.rect.top * k,
                    width: b.rect.width * k,
                    height: b.rect.height * k,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(b.rayon * k),
                      child: b.scan != null
                          ? Image.memory(b.scan!.bytes, fit: BoxFit.fill)
                          : Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                    color: const Color(0xFFB9BDCF), width: 1),
                                borderRadius:
                                    BorderRadius.circular(b.rayon * k),
                              ),
                              alignment: Alignment.center,
                              child: Text(b.label,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Color(0xFF9A9FB6),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600)),
                            ),
                    ),
                  ),
                if (p.blocs.isEmpty)
                  Center(
                      child: Text('Aucune page',
                          style: TextStyle(color: cs.outline))),
              ]);
            }),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final titre = switch (mode) {
      Mode.carte => 'Carte / Permis',
      Mode.passeport => 'Passeport',
      Mode.document => 'Document',
    };
    final p = miseEnPage;
    final paysage = p.isNotEmpty && p[pageVue.clamp(0, p.length - 1)].paysage;
    return PopScope(
      canPop: !pret,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await confirmer('Quitter ce scan ?',
            'Les pages scannées non exportées seront perdues.')) {
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
      drawer: MenuLateral(actuel: mode),
      appBar: AppBar(
        title: Text(titre),
        actions: [
          IconButton(
            tooltip: 'Accueil',
            icon: const Icon(Icons.home_outlined),
            onPressed: () => Navigator.maybePop(context),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              if (v == 'reset') {
                if (!pret ||
                    await confirmer('Tout effacer ?',
                        'Les scans de cet écran seront supprimés.')) {
                  setState(() {
                    slots[0] = null;
                    slots[1] = null;
                    pages.clear();
                    pageVue = 0;
                  });
                }
              } else if (v == 'apropos') {
                if (context.mounted) aPropos(context);
              } else if (v == 'quitter') {
                if (!pret ||
                    await confirmer('Quitter ScanPièces ?',
                        'Les pages scannées non exportées seront perdues.')) {
                  quitterAppli();
                }
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(
                  value: 'reset',
                  child: ListTile(
                      leading: Icon(Icons.restart_alt),
                      title: Text('Recommencer'))),
              PopupMenuItem(
                  value: 'apropos',
                  child: ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('À propos'))),
              PopupMenuItem(
                  value: 'quitter',
                  child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text('Quitter l\'application'))),
            ],
          ),
        ],
      ),
      body: Stack(children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            switch (mode) {
              Mode.carte => panneauCarte(),
              Mode.passeport => panneauPasseport(),
              Mode.document => panneauDocument(),
            },
            const SizedBox(height: 22),
            Row(
              children: [
                const Expanded(
                  child: Text('Aperçu de la feuille',
                      style:
                          TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
                ),
                Text(paysage ? 'A4 paysage' : 'A4 portrait',
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ],
            ),
            if (fixe) ...[
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Taille réelle')),
                  ButtonSegment(value: false, label: Text('Agrandie')),
                ],
                selected: {reel},
                onSelectionChanged: (s) => setState(() => reel = s.first),
              ),
            ],
            const SizedBox(height: 14),
            apercu(),
          ],
        ),
        if (occupe)
          const Positioned.fill(
              child: ColoredBox(
                  color: Color(0x55000000),
                  child: Center(child: CircularProgressIndicator()))),
      ]),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: FilledButton.icon(
                onPressed: pret && !occupe ? partagerPdf : null,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('PDF'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: OutlinedButton.icon(
                onPressed: pret && !occupe ? partagerImages : null,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Image'),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.outlined(
              tooltip: 'Imprimer',
              onPressed: pret && !occupe ? imprimer : null,
              icon: const Icon(Icons.print_outlined),
            ),
          ]),
        ),
      ),
      ),
    );
  }

  Future<bool> confirmer(String titre, String texte) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(titre),
        content: Text(texte),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annuler')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Oui')),
        ],
      ),
    );
    return r ?? false;
  }
}
