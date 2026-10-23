/// A tiny, dependency-free reader for the sanitised HTML a policy document is
/// served as (`content_html`). It turns the markup into a list of [PolicyBlock]s
/// (paragraphs, headings, list items, quotes, rules) made of styled
/// [PolicySpan]s, which the policy widgets draw as `TextSpan`s. Pure Dart, so it
/// is unit-tested without a device.
///
/// It is deliberately forgiving: tags it does not know are transparent (their
/// text is kept), `<script>` / `<style>` content is dropped, and only `http(s)`
/// and `mailto:` links survive. It never builds a widget tree from the markup, so
/// nothing in a document can run or load anything.
library;

/// A run of text with one style.
class PolicySpan {
  const PolicySpan(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.code = false,
    this.href,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool code;

  /// The link target, only for safe schemes (`http`, `https`, `mailto`).
  final String? href;

  @override
  bool operator ==(Object other) =>
      other is PolicySpan &&
      other.text == text &&
      other.bold == bold &&
      other.italic == italic &&
      other.code == code &&
      other.href == href;

  @override
  int get hashCode => Object.hash(text, bold, italic, code, href);

  @override
  String toString() => 'PolicySpan($text)';
}

enum PolicyBlockKind { paragraph, heading, listItem, quote, rule }

class PolicyBlock {
  const PolicyBlock(
    this.kind,
    this.spans, {
    this.level = 0,
    this.marker,
    this.depth = 0,
  });

  final PolicyBlockKind kind;
  final List<PolicySpan> spans;

  /// 1 to 6 for a heading; otherwise 0.
  final int level;

  /// The list marker (`•` or `1.`) for a list item.
  final String? marker;

  /// List nesting depth, 0 for a top-level item.
  final int depth;

  /// The block's text with no styling.
  String get text => spans.map((s) => s.text).join();
}

const _blockTags = {
  'p', 'div', 'section', 'article', 'header', 'footer', 'ul', 'ol', 'li',
  'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'tr', 'table', 'pre',
  'hr', 'br',
};
const _dropTags = {'script', 'style', 'head', 'template', 'iframe', 'object', 'embed'};

/// Parse sanitised policy HTML into blocks.
List<PolicyBlock> parsePolicyHtml(String html) {
  final blocks = <PolicyBlock>[];
  var spans = <PolicySpan>[];
  var kind = PolicyBlockKind.paragraph;
  var level = 0;
  String? marker;
  var depth = 0;
  var bold = 0, italic = 0, code = 0, quote = 0;
  String? dropUntil;
  final hrefs = <String?>[];
  final lists = <List<int>>[]; // [ordered (1/0), counter]

  void flush() {
    final cleaned = spans.where((s) => s.text.isNotEmpty).toList();
    if (cleaned.isNotEmpty) {
      cleaned[0] = _with(cleaned[0], cleaned[0].text.trimLeft());
      final last = cleaned.length - 1;
      cleaned[last] = _with(cleaned[last], cleaned[last].text.trimRight());
    }
    final kept = cleaned.where((s) => s.text.isNotEmpty).toList();
    if (kept.isNotEmpty) {
      final k = kind == PolicyBlockKind.paragraph && quote > 0 ? PolicyBlockKind.quote : kind;
      blocks.add(PolicyBlock(k, kept, level: level, marker: marker, depth: depth));
    }
    spans = <PolicySpan>[];
    kind = PolicyBlockKind.paragraph;
    level = 0;
    marker = null;
    depth = 0;
  }

  void addText(String raw) {
    if (raw.isEmpty) return;
    var text = _decodeEntities(raw).replaceAll(RegExp(r'[ \t\r\n\f]+'), ' ');
    if (text.isEmpty) return;
    final prev = spans.isEmpty ? null : spans.last;
    if (prev != null && prev.text.endsWith(' ') && text.startsWith(' ')) text = text.substring(1);
    if (prev == null && text.trim().isEmpty) return;
    if (text.isEmpty) return;
    String? href;
    for (final h in hrefs.reversed) {
      if (h != null) {
        href = h;
        break;
      }
    }
    spans.add(PolicySpan(text, bold: bold > 0, italic: italic > 0, code: code > 0, href: href));
  }

  var i = 0;
  final n = html.length;
  while (i < n) {
    final lt = html.indexOf('<', i);
    if (lt < 0) {
      if (dropUntil == null) addText(html.substring(i));
      break;
    }
    if (lt > i && dropUntil == null) addText(html.substring(i, lt));
    if (html.startsWith('<!--', lt)) {
      final end = html.indexOf('-->', lt + 4);
      i = end < 0 ? n : end + 3;
      continue;
    }
    final gt = html.indexOf('>', lt + 1);
    if (gt < 0) {
      // A stray "<": treat the rest as text.
      if (dropUntil == null) addText(html.substring(lt));
      break;
    }
    final inner = html.substring(lt + 1, gt).trim();
    i = gt + 1;
    if (inner.isEmpty || inner[0] == '!' || inner[0] == '?') continue;
    final closing = inner[0] == '/';
    final body = closing ? inner.substring(1).trim() : inner;
    final nameMatch = RegExp(r'^[^\s/]+').firstMatch(body);
    final name = nameMatch == null ? '' : nameMatch.group(0)!.toLowerCase();
    if (name.isEmpty) continue;
    if (dropUntil != null) {
      if (closing && name == dropUntil) dropUntil = null;
      continue;
    }
    if (!closing && _dropTags.contains(name) && !body.endsWith('/')) {
      dropUntil = name;
      continue;
    }
    if (closing) {
      switch (name) {
        case 'strong':
        case 'b':
          if (bold > 0) bold--;
        case 'em':
        case 'i':
          if (italic > 0) italic--;
        case 'code':
        case 'kbd':
        case 'samp':
        case 'tt':
          if (code > 0) code--;
        case 'a':
          if (hrefs.isNotEmpty) hrefs.removeLast();
        case 'ul':
        case 'ol':
          flush();
          if (lists.isNotEmpty) lists.removeLast();
        case 'blockquote':
          flush();
          if (quote > 0) quote--;
        default:
          if (_blockTags.contains(name)) flush();
      }
      continue;
    }
    switch (name) {
      case 'strong':
      case 'b':
        bold++;
      case 'em':
      case 'i':
        italic++;
      case 'code':
      case 'kbd':
      case 'samp':
      case 'tt':
        code++;
      case 'a':
        hrefs.add(_safeHref(_attribute(body, 'href')));
      case 'br':
        spans.add(PolicySpan('\n', bold: bold > 0, italic: italic > 0, code: code > 0));
      case 'hr':
        flush();
        blocks.add(const PolicyBlock(PolicyBlockKind.rule, []));
      case 'ul':
      case 'ol':
        flush();
        lists.add([name == 'ol' ? 1 : 0, 0]);
      case 'li':
        flush();
        kind = PolicyBlockKind.listItem;
        depth = lists.isEmpty ? 0 : lists.length - 1;
        if (lists.isNotEmpty && lists.last[0] == 1) {
          lists.last[1] = lists.last[1] + 1;
          marker = '${lists.last[1]}.';
        } else {
          marker = '\u2022';
        }
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        flush();
        kind = PolicyBlockKind.heading;
        level = int.parse(name.substring(1));
      case 'blockquote':
        flush();
        quote++;
      default:
        if (_blockTags.contains(name)) flush();
    }
  }
  flush();
  return blocks;
}

PolicySpan _with(PolicySpan s, String text) =>
    PolicySpan(text, bold: s.bold, italic: s.italic, code: s.code, href: s.href);

/// Plain text of a document, one block per line (used for accessibility and tests).
String policyPlainText(String html) => parsePolicyHtml(html)
    .map((b) => (b.marker != null ? '${b.marker} ' : '') + b.text)
    .join('\n');

String? _attribute(String tag, String name) {
  final m = RegExp('\\b$name\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s"\'>]+))', caseSensitive: false)
      .firstMatch(tag);
  if (m == null) return null;
  return _decodeEntities(m.group(2) ?? m.group(3) ?? m.group(4) ?? '');
}

String? _safeHref(String? href) {
  final h = href?.trim();
  if (h == null) return null;
  final lower = h.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://') || lower.startsWith('mailto:') ? h : null;
}

String _decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(RegExp(r'&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);'), (m) {
    final e = m.group(1)!;
    if (e.startsWith('#x') || e.startsWith('#X')) {
      final cp = int.tryParse(e.substring(2), radix: 16);
      return cp == null ? m.group(0)! : _codePoint(cp);
    }
    if (e.startsWith('#')) {
      final cp = int.tryParse(e.substring(1));
      return cp == null ? m.group(0)! : _codePoint(cp);
    }
    switch (e.toLowerCase()) {
      case 'amp':
        return '&';
      case 'lt':
        return '<';
      case 'gt':
        return '>';
      case 'quot':
        return '"';
      case 'apos':
        return "'";
      case 'nbsp':
        return '\u00a0';
      case 'ndash':
        return '\u2013';
      case 'mdash':
        return '\u2014';
      case 'hellip':
        return '\u2026';
      case 'rsquo':
        return '\u2019';
      case 'lsquo':
        return '\u2018';
      case 'rdquo':
        return '\u201d';
      case 'ldquo':
        return '\u201c';
      case 'copy':
        return '\u00a9';
      default:
        return m.group(0)!;
    }
  });
}

String _codePoint(int cp) =>
    cp >= 1 && cp <= 0x10FFFF && !(cp >= 0xD800 && cp <= 0xDFFF) ? String.fromCharCode(cp) : '\uFFFD';

/// A small, safe markdown renderer (headings, paragraphs, lists, bold, italics,
/// code, http(s) links) for a policy delivered as markdown only. Every character
/// of input is HTML-escaped first, so it can never inject markup.
String policyMarkdownToSafeHtml(String markdown) {
  final lines = markdown.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  final html = <String>[];
  final para = <String>[];
  String? list;
  void flushPara() {
    if (para.isNotEmpty) html.add('<p>${_mdInline(para.join(' '))}</p>');
    para.clear();
  }

  void closeList() {
    if (list != null) html.add('</$list>');
    list = null;
  }

  final heading = RegExp(r'^(#{1,6})\s+(.*)$');
  final bullet = RegExp(r'^\s*[-*+]\s+(.*)$');
  final numbered = RegExp(r'^\s*\d+[.)]\s+(.*)$');
  for (final line in lines) {
    final h = heading.firstMatch(line);
    final b = bullet.firstMatch(line);
    final num = numbered.firstMatch(line);
    if (h != null) {
      flushPara();
      closeList();
      final lv = h.group(1)!.length;
      html.add('<h$lv>${_mdInline(h.group(2)!)}</h$lv>');
    } else if (b != null || num != null) {
      flushPara();
      final kind = b != null ? 'ul' : 'ol';
      if (list != kind) {
        closeList();
        html.add('<$kind>');
        list = kind;
      }
      html.add('<li>${_mdInline((b ?? num)!.group(1)!)}</li>');
    } else if (line.trim().isEmpty) {
      flushPara();
      closeList();
    } else {
      closeList();
      para.add(line.trim());
    }
  }
  flushPara();
  closeList();
  return html.join('\n');
}

String _mdEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _mdInline(String text) {
  var out = _mdEscape(text);
  out = out.replaceAllMapped(RegExp(r'`([^`]+)`'), (m) => '<code>${m.group(1)}</code>');
  out = out.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => '<strong>${m.group(1)}</strong>');
  out = out.replaceAllMapped(
      RegExp(r'(^|[^*])\*([^*\s][^*]*)\*'), (m) => '${m.group(1)}<em>${m.group(2)}</em>');
  out = out.replaceAllMapped(RegExp(r'\[([^\]]+)\]\((https?://[^\s)]+)\)'),
      (m) => '<a href="${m.group(2)}">${m.group(1)}</a>');
  return out;
}
