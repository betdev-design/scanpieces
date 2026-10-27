import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const ScanPiecesApp());

/// Convertit une page rendue en JPG sur fond blanc (fonction autonome,
/// exécutable en arrière-plan sans emporter l'écran de l'appli).
Uint8List rasterEnJpg((int, int, Uint8List) d) {
  final (w, h, px) = d;
  final src = img.Image.fromBytes(
      width: w, height: h, bytes: px.buffer, numChannels: 4);
  final fond = img.Image(width: w, height: h);
  img.fill(fond, color: img.ColorRgb8(255, 255, 255));
  img.compositeImage(fond, src);
  return Uint8List.fromList(img.encodeJpg(fond, quality: 90));
}

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
const kConfidentialite =
    'https://betdev-design.github.io/scanpieces/confidentialite.html';

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
            Text('Version 1.3 · une appli NIGBOU AI',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 12),
            const Text('Scanner de cartes, permis, passeports et documents. '
                'Recto et verso côte à côte, passeport superposé. Export PDF, '
                'image, Word, PowerPoint et Excel. '
                'Vos documents restent sur votre téléphone.'),
            const SizedBox(height: 16),
            const Text('Apprenez à créer des applis comme celle-ci',
                style: TextStyle(fontWeight: FontWeight.w700)),
            const Text('NIGBOU AI SCHOOL : formations en intelligence '
                'artificielle, création de solutions digitales et analyse '
                'sportive.'),
            const SizedBox(height: 6),
            lien(Icons.facebook, 'NIGBOU AI SCHOOL sur Facebook', kFacebook),
            lien(Icons.chat_outlined, 'WhatsApp : +226 71 34 97 49', kWhatsApp),
            lien(Icons.send_outlined, 'Telegram : t.me/Leuk18', kTelegram),
            lien(Icons.privacy_tip_outlined, 'Politique de confidentialité',
                kConfidentialite),
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => showLicensePage(
                context: c,
                applicationName: 'ScanPièces',
                applicationVersion: '1.3'),
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
            item(Icons.privacy_tip_outlined, 'Confidentialité', () {
              Navigator.pop(context);
              ouvrirLien(kConfidentialite);
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

/* ===================== Modèles Office ===================== */

const kHdr =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
''';

const kRelNs =
    r'''http://schemas.openxmlformats.org/officeDocument/2006/relationships''';

const kPkgNs =
    r'''http://schemas.openxmlformats.org/package/2006/relationships''';

const kDocxCt =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="jpeg" ContentType="image/jpeg"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>''';

const kDocxRootRels =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>''';

const kDocxHead =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>''';

const kDocxTail =
    r'''<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr></w:body></w:document>''';

const kPptRootRels =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>''';

const kPptPresRelsHead =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>''';

const kPptMaster =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>''';

const kPptMasterRels =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>''';

const kPptLayout =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank" preserve="1"><p:cSld name="Vide"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>''';

const kPptLayoutRels =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>''';

const kPptTheme =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="ScanPieces"><a:themeElements><a:clrScheme name="ScanPieces"><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:dk2><a:srgbClr val="1F2937"/></a:dk2><a:lt2><a:srgbClr val="F3F4F6"/></a:lt2><a:accent1><a:srgbClr val="3438A8"/></a:accent1><a:accent2><a:srgbClr val="ED7D31"/></a:accent2><a:accent3><a:srgbClr val="A5A5A5"/></a:accent3><a:accent4><a:srgbClr val="FFC000"/></a:accent4><a:accent5><a:srgbClr val="5B9BD5"/></a:accent5><a:accent6><a:srgbClr val="70AD47"/></a:accent6><a:hlink><a:srgbClr val="0563C1"/></a:hlink><a:folHlink><a:srgbClr val="954F72"/></a:folHlink></a:clrScheme><a:fontScheme name="ScanPieces"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="ScanPieces"><a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst><a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme></a:themeElements><a:objectDefaults/><a:extraClrSchemeLst/></a:theme>''';

const kPptSlideHead =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>''';

const kPptSlideTail =
    r'''</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>''';

const kXlsxCt =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>''';

const kXlsxRootRels =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>''';

const kXlsxWb =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Texte" sheetId="1" r:id="rId1"/></sheets></workbook>''';

const kXlsxWbRels =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>''';

const kXlsxStyles =
    r'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0" applyAlignment="1"><alignment wrapText="1" vertical="top"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>''';


/* ===================== Lecture du texte (OCR, sur l'appareil) ===================== */

class PageTexte {
  final String titre;
  final Scan scan;
  final List<List<String>> paragraphes; // blocs -> lignes (Word)
  final List<List<String>> rangees; // lignes du document -> cellules (Excel)
  final String texte;
  const PageTexte(
      this.titre, this.scan, this.paragraphes, this.rangees, this.texte);
}

List<String> decouperLigne(TextLine l) {
  final els = [...l.elements]
    ..sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
  if (els.isEmpty) return [l.text];
  final h = l.boundingBox.height;
  final out = <String>[];
  var cur = StringBuffer(els.first.text);
  for (var i = 1; i < els.length; i++) {
    final ecart = els[i].boundingBox.left - els[i - 1].boundingBox.right;
    if (ecart > 1.8 * h) {
      out.add(cur.toString());
      cur = StringBuffer(els[i].text);
    } else {
      cur.write(' ');
      cur.write(els[i].text);
    }
  }
  out.add(cur.toString());
  return out;
}

List<List<String>> calculerRangees(RecognizedText r) {
  final lignes = <TextLine>[for (final b in r.blocks) ...b.lines];
  lignes.sort((a, b) =>
      a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));
  final groupes = <List<TextLine>>[];
  for (final l in lignes) {
    final cy = l.boundingBox.center.dy, h = l.boundingBox.height;
    if (groupes.isNotEmpty) {
      final ref = groupes.last.first.boundingBox;
      if ((ref.center.dy - cy).abs() < 0.5 * math.max(h, ref.height)) {
        groupes.last.add(l);
        continue;
      }
    }
    groupes.add([l]);
  }
  return groupes.map((g) {
    g.sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left));
    return <String>[for (final l in g) ...decouperLigne(l)];
  }).toList();
}

Future<List<PageTexte>> lireTextes(List<(String, Scan)> sources) async {
  final rec = TextRecognizer(script: TextRecognitionScript.latin);
  final dir = await getTemporaryDirectory();
  final res = <PageTexte>[];
  try {
    for (var i = 0; i < sources.length; i++) {
      final (titre, scan) = sources[i];
      final f = File('${dir.path}/ocr_$i.jpg');
      await f.writeAsBytes(scan.bytes);
      final r = await rec.processImage(InputImage.fromFilePath(f.path));
      final paras = r.blocks
          .map((b) => b.lines.map((l) => l.text).toList())
          .where((p) => p.isNotEmpty)
          .toList();
      res.add(PageTexte(titre, scan, paras, calculerRangees(r), r.text));
    }
  } finally {
    rec.close();
  }
  return res;
}

/* ===================== Fichiers Office (.docx, .pptx, .xlsx) ===================== */

String esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

final Uint32List _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    t[n] = c;
  }
  return t;
}();

int crc32(Uint8List d) {
  var c = 0xFFFFFFFF;
  for (final b in d) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// Petit créateur de fichier ZIP (sans compression), suffisant pour Office.
Uint8List zipper(List<(String, Uint8List)> fichiers) {
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  Uint8List u16(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  Uint8List u32(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
  var offset = 0;
  for (final (nom, data) in fichiers) {
    final n = Uint8List.fromList(utf8.encode(nom));
    final crc = crc32(data);
    final local = BytesBuilder()
      ..add(u32(0x04034b50))
      ..add(u16(20))
      ..add(u16(0x0800))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(crc))
      ..add(u32(data.length))
      ..add(u32(data.length))
      ..add(u16(n.length))
      ..add(u16(0))
      ..add(n)
      ..add(data);
    final bytesLocal = local.takeBytes();
    out.add(bytesLocal);
    central
      ..add(u32(0x02014b50))
      ..add(u16(20))
      ..add(u16(20))
      ..add(u16(0x0800))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(crc))
      ..add(u32(data.length))
      ..add(u32(data.length))
      ..add(u16(n.length))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u32(0))
      ..add(u32(offset))
      ..add(n);
    offset += bytesLocal.length;
  }
  final cd = central.takeBytes();
  out
    ..add(cd)
    ..add(u32(0x06054b50))
    ..add(u16(0))
    ..add(u16(0))
    ..add(u16(fichiers.length))
    ..add(u16(fichiers.length))
    ..add(u32(cd.length))
    ..add(u32(offset))
    ..add(u16(0));
  return out.takeBytes();
}

Uint8List _t(String s) => Uint8List.fromList(utf8.encode(s));

Uint8List construireDocx(List<PageTexte> pages, bool sautsDePage) {
  final body = StringBuffer();
  final rels = StringBuffer();
  for (var i = 0; i < pages.length; i++) {
    final p = pages[i];
    final n = i + 1;
    if (i > 0 && sautsDePage) {
      body.write('<w:p><w:r><w:br w:type="page"/></w:r></w:p>');
    }
    body.write('<w:p><w:pPr><w:spacing w:before="240" w:after="120"/></w:pPr>'
        '<w:r><w:rPr><w:b/><w:sz w:val="28"/></w:rPr>'
        '<w:t xml:space="preserve">${esc(p.titre)}</w:t></w:r></w:p>');
    if (p.paragraphes.isEmpty) {
      body.write('<w:p><w:r><w:rPr><w:i/></w:rPr>'
          '<w:t xml:space="preserve">(Aucun texte détecté)</w:t></w:r></w:p>');
    }
    for (final para in p.paragraphes) {
      final runs = para
          .map((l) => '<w:r><w:t xml:space="preserve">${esc(l)}</w:t></w:r>')
          .join('<w:r><w:br/></w:r>');
      body.write('<w:p>$runs</w:p>');
    }
    var cx = 5760000;
    var cy = (cx * p.scan.h / p.scan.w).round();
    if (cy > 7920000) {
      cy = 7920000;
      cx = (cy * p.scan.w / p.scan.h).round();
    }
    body.write('<w:p><w:pPr><w:spacing w:before="200"/><w:jc w:val="center"/></w:pPr>'
        '<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/><wp:docPr id="$n" name="Scan $n"/>'
        '<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic><pic:nvPicPr><pic:cNvPr id="$n" name="scan$n.jpeg"/><pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="rIdImg$n"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic>'
        '</a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>');
    rels.write('<Relationship Id="rIdImg$n" Type="$kRelNs/image" '
        'Target="media/image$n.jpeg"/>');
  }
  final doc = '$kDocxHead$body$kDocxTail';
  final drels = '$kHdr<Relationships xmlns="$kPkgNs">$rels</Relationships>';
  return zipper([
    ('[Content_Types].xml', _t(kDocxCt)),
    ('_rels/.rels', _t(kDocxRootRels)),
    ('word/document.xml', _t(doc)),
    ('word/_rels/document.xml.rels', _t(drels)),
    for (var i = 0; i < pages.length; i++)
      ('word/media/image${i + 1}.jpeg', pages[i].scan.bytes),
  ]);
}

Uint8List construirePptx(List<Scan> scans) {
  const sw = 12192000, sh = 6858000, marge = 228600;
  final ct = StringBuffer('$kHdr<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="jpeg" ContentType="image/jpeg"/>'
      '<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>'
      '<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>'
      '<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>'
      '<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>');
  final ids = StringBuffer();
  final prels = StringBuffer(kPptPresRelsHead);
  final fichiers = <(String, Uint8List)>[];
  for (var i = 0; i < scans.length; i++) {
    final s = scans[i];
    final n = i + 1;
    ct.write('<Override PartName="/ppt/slides/slide$n.xml" '
        'ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>');
    ids.write('<p:sldId id="${255 + n}" r:id="rId${n + 2}"/>');
    prels.write('<Relationship Id="rId${n + 2}" Type="$kRelNs/slide" '
        'Target="slides/slide$n.xml"/>');
    final k = math.min((sw - 2 * marge) / s.w, (sh - 2 * marge) / s.h);
    final cx = (s.w * k).floor(), cy = (s.h * k).floor();
    final x = (sw - cx) ~/ 2, y = (sh - cy) ~/ 2;
    final sld = '$kPptSlideHead<p:pic><p:nvPicPr><p:cNvPr id="2" name="Scan $n"/>'
        '<p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>'
        '<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>'
        '<p:spPr><a:xfrm><a:off x="$x" y="$y"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>$kPptSlideTail';
    final srels = '$kHdr<Relationships xmlns="$kPkgNs">'
        '<Relationship Id="rId1" Type="$kRelNs/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>'
        '<Relationship Id="rId2" Type="$kRelNs/image" Target="../media/image$n.jpeg"/>'
        '</Relationships>';
    fichiers
      ..add(('ppt/slides/slide$n.xml', _t(sld)))
      ..add(('ppt/slides/_rels/slide$n.xml.rels', _t(srels)))
      ..add(('ppt/media/image$n.jpeg', s.bytes));
  }
  ct.write('</Types>');
  prels.write('</Relationships>');
  final pres = '$kHdr<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">'
      '<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>'
      '<p:sldIdLst>$ids</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/>'
      '<p:notesSz cx="6858000" cy="9144000"/></p:presentation>';
  return zipper([
    ('[Content_Types].xml', _t(ct.toString())),
    ('_rels/.rels', _t(kPptRootRels)),
    ('ppt/presentation.xml', _t(pres)),
    ('ppt/_rels/presentation.xml.rels', _t(prels.toString())),
    ('ppt/slideMasters/slideMaster1.xml', _t(kPptMaster)),
    ('ppt/slideMasters/_rels/slideMaster1.xml.rels', _t(kPptMasterRels)),
    ('ppt/slideLayouts/slideLayout1.xml', _t(kPptLayout)),
    ('ppt/slideLayouts/_rels/slideLayout1.xml.rels', _t(kPptLayoutRels)),
    ('ppt/theme/theme1.xml', _t(kPptTheme)),
    ...fichiers,
  ]);
}

String nomColonne(int i) {
  var s = '';
  var n = i + 1;
  while (n > 0) {
    final r = (n - 1) % 26;
    s = String.fromCharCode(65 + r) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

Uint8List construireXlsx(List<PageTexte> pages) {
  final lignes = <(int, List<String>)>[
    (1, ['Source', 'Texte détecté (une colonne par zone de texte)']),
  ];
  for (final p in pages) {
    if (p.rangees.isEmpty) {
      lignes.add((0, [p.titre, '(Aucun texte détecté)']));
    }
    for (var j = 0; j < p.rangees.length; j++) {
      lignes.add((0, [j == 0 ? p.titre : '', ...p.rangees[j]]));
    }
    lignes.add((0, <String>[]));
  }
  final xs = StringBuffer();
  for (var r = 0; r < lignes.length; r++) {
    final (style, cells) = lignes[r];
    xs.write('<row r="${r + 1}">');
    for (var c = 0; c < cells.length; c++) {
      if (cells[c].isEmpty) continue;
      xs.write('<c r="${nomColonne(c)}${r + 1}" t="inlineStr" s="$style">'
          '<is><t xml:space="preserve">${esc(cells[c])}</t></is></c>');
    }
    xs.write('</row>');
  }
  final sheet = '$kHdr<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '<cols><col min="1" max="1" width="14" customWidth="1"/>'
      '<col min="2" max="12" width="28" customWidth="1"/></cols>'
      '<sheetData>$xs</sheetData></worksheet>';
  return zipper([
    ('[Content_Types].xml', _t(kXlsxCt)),
    ('_rels/.rels', _t(kXlsxRootRels)),
    ('xl/workbook.xml', _t(kXlsxWb)),
    ('xl/_rels/workbook.xml.rels', _t(kXlsxWbRels)),
    ('xl/styles.xml', _t(kXlsxStyles)),
    ('xl/worksheets/sheet1.xml', _t(sheet)),
  ]);
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

  List<(String, Scan)> get sources {
    final out = <(String, Scan)>[];
    switch (mode) {
      case Mode.carte:
        if (slots[0] != null) out.add(('Recto', slots[0]!));
        if (slots[1] != null) out.add(('Verso', slots[1]!));
      case Mode.passeport:
        if (slots[0] != null) out.add(('Page du haut', slots[0]!));
        if (slots[1] != null) out.add(('Page d\'identité', slots[1]!));
      case Mode.document:
        for (var i = 0; i < pages.length; i++) {
          out.add(('Page ${i + 1}', pages[i]));
        }
    }
    return out;
  }

  Future<void> partagerFichier(
          String ext, String mime, Future<Uint8List> Function() creer) =>
      occuper(() async {
        final bytes = await creer();
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/$nomFichier.$ext');
        await f.writeAsBytes(bytes);
        await SharePlus.instance
            .share(ShareParams(files: [XFile(f.path, mimeType: mime)]));
      });

  Future<void> exporterWord() => partagerFichier(
      'docx',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      () async =>
          construireDocx(await lireTextes(sources), mode == Mode.document));

  Future<void> exporterPowerPoint() => partagerFichier(
      'pptx',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      () async => construirePptx(sources.map((s) => s.$2).toList()));

  Future<void> exporterExcel() => partagerFichier(
      'xlsx',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      () async => construireXlsx(await lireTextes(sources)));

  Future<void> voirTexte() async {
    String? resultat;
    await occuper(() async {
      final pagesTexte = await lireTextes(sources);
      resultat = pagesTexte.map((p) {
        final t = p.texte.trim();
        return '— ${p.titre} —\n${t.isEmpty ? '(Aucun texte détecté)' : t}';
      }).join('\n\n');
    });
    final texte = resultat;
    if (texte == null || !mounted) return;
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Texte du scan'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(texte)),
        ),
        actions: [
          TextButton(
            onPressed: () => SharePlus.instance.share(ShareParams(text: texte)),
            child: const Text('Partager'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: texte));
              if (c.mounted) Navigator.pop(c);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Texte copié')));
              }
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copier'),
          ),
        ],
      ),
    );
  }

  void autresFormats() {
    Widget choix(IconData ic, String titre, String sous, VoidCallback f) =>
        ListTile(
          leading: Icon(ic),
          title: Text(titre),
          subtitle: Text(sous),
          onTap: () {
            Navigator.pop(context);
            f();
          },
        );
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              choix(Icons.description_outlined, 'Word (.docx)',
                  'Texte modifiable + image du scan', exporterWord),
              choix(Icons.slideshow_outlined, 'PowerPoint (.pptx)',
                  'Une page scannée par diapositive', exporterPowerPoint),
              choix(Icons.table_chart_outlined, 'Excel (.xlsx)',
                  'Texte rangé en lignes et colonnes', exporterExcel),
              choix(Icons.copy_all_outlined, 'Copier le texte',
                  'Lire le texte du scan pour le coller ailleurs', voirTexte),
              choix(Icons.print_outlined, 'Imprimer',
                  'Envoyer la feuille A4 à une imprimante', imprimer),
            ],
          ),
        ),
      ),
    );
  }

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
          final jpg = await compute(
              rasterEnJpg, (page.width, page.height, page.pixels));
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
            Expanded(
              flex: 3,
              child: OutlinedButton.icon(
                onPressed: pret && !occupe ? autresFormats : null,
                icon: const Icon(Icons.more_horiz),
                label: const Text('Plus'),
              ),
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
