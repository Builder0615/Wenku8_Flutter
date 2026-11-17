import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:charset/charset.dart' show Charset, gbk;
import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:url_launcher/url_launcher.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_search.dart';
import 'legado_book_sources.dart';

const _sourceSearchBatchSize = 32;
const _sourceSearchConcurrency = 8;
const _sourceSearchTimeout = Duration(seconds: 8);
const _sourceSearchMaxResponseBytes = 4 * 1024 * 1024;
const _sourceSearchResultsPerSource = 3;

class LegadoBookSearchResult {
  const LegadoBookSearchResult({
    required this.sourceName,
    required this.title,
    required this.author,
    required this.url,
    this.coverUrl,
    this.summary,
    this.lastChapter,
  });

  final String sourceName;
  final String title;
  final String author;
  final Uri? url;
  final Uri? coverUrl;
  final String? summary;
  final String? lastChapter;
}

class LegadoBookSourceSearchController extends ChangeNotifier {
  LegadoBookSourceSearchController(this.store) {
    store.addListener(_sourcesChanged);
  }

  final LegadoBookSourceStore store;
  List<LegadoBookSearchResult> results = const [];
  String query = '';
  BookSearchField field = BookSearchField.title;
  bool loading = false;
  bool hasMore = false;
  int sourceCount = 0;
  int checkedSources = 0;
  int batchProgress = 0;
  int batchTotal = 0;
  int failedSources = 0;
  int unsupportedSources = 0;
  String? notice;

  List<LegadoBookSource> _eligible = const [];
  int _sourceCursor = 0;
  int _generation = 0;
  HttpClient? _client;
  bool _disposed = false;

  Future<void> searchFor(
    String value, {
    required BookSearchField field,
    bool force = false,
  }) async {
    final term = value.trim();
    if (!force && query == term && this.field == field) return;

    _cancelRequest(notify: false);
    final generation = _generation;
    query = term;
    this.field = field;
    results = const [];
    hasMore = false;
    sourceCount = 0;
    checkedSources = 0;
    batchProgress = 0;
    batchTotal = 0;
    failedSources = 0;
    unsupportedSources = 0;
    notice = null;

    if (term.isEmpty) {
      loading = false;
      _eligible = const [];
      notifyListeners();
      return;
    }
    if (field == BookSearchField.tags || field == BookSearchField.id) {
      loading = false;
      _eligible = const [];
      notice = '当前搜索范围无法转换为阅读书源关键词';
      notifyListeners();
      return;
    }

    loading = true;
    notice = '正在读取已导入的阅读书源';
    notifyListeners();
    try {
      await store.load();
      if (!_isCurrent(generation)) return;
      _eligible = [
        for (final source in store.sources)
          if (source.enabled &&
              (source.record['bookSourceType'] is! num ||
                  source.record['bookSourceType'] == 0) &&
              source.record['searchUrl'] is String &&
              (source.record['searchUrl'] as String).trim().isNotEmpty &&
              source.record['ruleSearch'] is Map &&
              (source.record['ruleSearch'] as Map)['bookList'] is String &&
              (source.record['ruleSearch'] as Map)['name'] is String)
            source,
      ];
      sourceCount = _eligible.length;
      _sourceCursor = 0;
      hasMore = _eligible.isNotEmpty;
      notice = _eligible.isEmpty ? '没有已启用且包含搜索规则的阅读书源' : null;
      loading = false;
      notifyListeners();
      if (_eligible.isNotEmpty) await _loadNextBatch(generation);
    } catch (_) {
      if (!_isCurrent(generation)) return;
      loading = false;
      hasMore = false;
      notice = '阅读书源列表读取失败，请重新打开书源管理页后重试';
      notifyListeners();
    }
  }

  void refresh() {
    unawaited(searchFor(query, field: field, force: true));
  }

  void searchNextBatch() {
    if (_disposed || loading || !hasMore) return;
    unawaited(_loadNextBatch(_generation));
  }

  void cancel() => _cancelRequest();

  Future<void> _loadNextBatch(int generation) async {
    if (!_isCurrent(generation) ||
        loading ||
        _sourceCursor >= _eligible.length) {
      return;
    }
    final batch = _eligible
        .skip(_sourceCursor)
        .take(_sourceSearchBatchSize)
        .toList(growable: false);
    _sourceCursor += batch.length;
    loading = true;
    batchProgress = 0;
    batchTotal = batch.length;
    notice = null;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10)
      ..userAgent =
          'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';
    _client = client;
    notifyListeners();

    var cursor = 0;
    var completed = 0;
    var failed = 0;
    var unsupported = 0;
    final found = <LegadoBookSearchResult>[];
    final resultKeys = <String>{};

    Future<void> worker() async {
      while (_isCurrent(generation)) {
        final index = cursor++;
        if (index >= batch.length) return;
        final source = batch[index];
        try {
          final matches = await _searchOne(client, source, query);
          if (!_isCurrent(generation)) return;
          for (final result in matches) {
            final key =
                result.sourceName +
                '\u0000' +
                result.title +
                '\u0000' +
                result.author +
                '\u0000' +
                (result.url?.toString() ?? '');
            if (resultKeys.add(key)) found.add(result);
          }
        } on _UnsupportedBookSourceRule {
          unsupported++;
        } catch (_) {
          failed++;
        } finally {
          if (_isCurrent(generation)) {
            completed++;
            batchProgress = completed;
            notifyListeners();
          }
        }
      }
    }

    try {
      await Future.wait([
        for (
          var i = 0;
          i < math.min(_sourceSearchConcurrency, batch.length);
          i++
        )
          worker(),
      ]);
    } finally {
      if (identical(_client, client)) {
        client.close(force: true);
        _client = null;
      }
    }
    if (!_isCurrent(generation)) return;

    final merged = [...results];
    final existing = {
      for (final item in merged)
        item.sourceName +
            '\u0000' +
            item.title +
            '\u0000' +
            item.author +
            '\u0000' +
            (item.url?.toString() ?? ''),
    };
    for (final item in found) {
      final key =
          item.sourceName +
          '\u0000' +
          item.title +
          '\u0000' +
          item.author +
          '\u0000' +
          (item.url?.toString() ?? '');
      if (existing.add(key)) merged.add(item);
    }
    results = List.unmodifiable(merged);
    checkedSources += batch.length;
    failedSources += failed;
    unsupportedSources += unsupported;
    loading = false;
    hasMore = _sourceCursor < _eligible.length;
    notice = null;
    notifyListeners();
  }

  Future<List<LegadoBookSearchResult>> _searchOne(
    HttpClient client,
    LegadoBookSource source,
    String term,
  ) async {
    final sourceUrl = _baseSourceUrl(source.url);
    final request = _parseSearchRequest(
      source.record['searchUrl'] as String,
      term,
    );
    final uri = sourceUrl.resolve(request.url);
    final headers = _sourceHeaders(source.record['header']);
    for (final entry in request.headers.entries) {
      headers[entry.key] = entry.value;
    }

    final HttpClientRequest httpRequest;
    if (request.method == 'POST') {
      httpRequest = await client.postUrl(uri).timeout(_sourceSearchTimeout);
    } else if (request.method == 'GET') {
      httpRequest = await client.getUrl(uri).timeout(_sourceSearchTimeout);
    } else {
      throw const _UnsupportedBookSourceRule();
    }
    for (final entry in headers.entries) {
      httpRequest.headers.set(entry.key, entry.value);
    }
    if (request.body != null) {
      if (!headers.keys.any((key) => key.toLowerCase() == 'content-type')) {
        httpRequest.headers.contentType = ContentType(
          'application',
          'x-www-form-urlencoded',
          charset: request.charset ?? 'utf-8',
        );
      }
      httpRequest.add(
        _requestEncoding(request.bodyCharset).encode(request.body!),
      );
    }

    final response = await httpRequest.close().timeout(_sourceSearchTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const FormatException('书源搜索请求失败');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(_sourceSearchTimeout)) {
      if (bytes.length + chunk.length > _sourceSearchMaxResponseBytes) {
        throw const FormatException('书源搜索响应超过 4 MiB');
      }
      bytes.addAll(chunk);
    }
    final body = _decodeSearchResponse(
      bytes,
      request.charset ?? response.headers.contentType?.charset,
    );
    final document = _SearchDocument.parse(body);
    final rules = source.record['ruleSearch'];
    if (rules is! Map) throw const _UnsupportedBookSourceRule();
    final listRule = rules['bookList'];
    if (listRule is! String || listRule.trim().isEmpty) {
      throw const _UnsupportedBookSourceRule();
    }
    final books = document.bookList(listRule);
    final results = <LegadoBookSearchResult>[];
    for (final item in books.take(_sourceSearchResultsPerSource)) {
      final name = _stringValue(document.ruleValue(rules['name'], item));
      if (name.trim().isEmpty) continue;
      final author = _stringValue(document.ruleValue(rules['author'], item));
      final rawBookUrl = _stringValue(
        document.ruleValue(rules['bookUrl'], item),
      ).trim();
      final rawCover = _stringValue(
        document.ruleValue(rules['coverUrl'], item),
      ).trim();
      final rawSummary = _stringValue(
        document.ruleValue(rules['intro'], item),
      ).trim();
      final rawLastChapter = _stringValue(
        document.ruleValue(rules['lastChapter'], item),
      ).trim();
      results.add(
        LegadoBookSearchResult(
          sourceName: source.name,
          title: _plainText(name),
          author: _plainText(author),
          url: _resolveResultUrl(rawBookUrl, sourceUrl),
          coverUrl: _resolveResultUrl(rawCover, sourceUrl),
          summary: rawSummary.isEmpty ? null : _plainText(rawSummary),
          lastChapter: rawLastChapter.isEmpty
              ? null
              : _plainText(rawLastChapter),
        ),
      );
    }
    return results;
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;

  void _cancelRequest({bool notify = true}) {
    _generation++;
    _client?.close(force: true);
    _client = null;
    loading = false;
    if (notify && !_disposed) notifyListeners();
  }

  void _sourcesChanged() {
    if (_disposed || query.isEmpty) return;
    unawaited(searchFor(query, field: field, force: true));
  }

  @override
  void dispose() {
    _disposed = true;
    store.removeListener(_sourcesChanged);
    _cancelRequest(notify: false);
    super.dispose();
  }
}

class LegadoSearchResultsPanel extends StatelessWidget {
  const LegadoSearchResultsPanel({
    super.key,
    required this.controller,
    required this.query,
  });

  final LegadoBookSourceSearchController controller;
  final String query;

  @override
  Widget build(BuildContext context) {
    if (query.trim().isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final colorScheme = Theme.of(context).colorScheme;
        final currentQuery = controller.query == query.trim();
        final visibleResults = currentQuery
            ? controller.results
            : const <LegadoBookSearchResult>[];
        final total = currentQuery ? controller.sourceCount : 0;
        final detail = !currentQuery
            ? '正在准备搜索已启用的阅读书源'
            : controller.loading
            ? '本批已完成 ${controller.batchProgress} / ${controller.batchTotal} 个书源'
            : '已搜索 ${controller.checkedSources} / $total 个书源';
        return Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: AppText(
                      '阅读书源',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  if (visibleResults.isNotEmpty)
                    AppText(
                      '${visibleResults.length} 条',
                      style: TextStyle(
                        color: colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              AppText(
                currentQuery ? controller.notice ?? detail : detail,
                style: TextStyle(
                  color: colorScheme.onSurfaceVariant,
                  fontSize: 12,
                  height: 1.45,
                ),
              ),
              if (currentQuery &&
                  (controller.failedSources > 0 ||
                      controller.unsupportedSources > 0)) ...[
                const SizedBox(height: 4),
                AppText(
                  '请求失败 ${controller.failedSources} 个 · 暂不支持的规则 ${controller.unsupportedSources} 个',
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 11,
                  ),
                ),
              ],
              if (currentQuery &&
                  visibleResults.isEmpty &&
                  !controller.loading &&
                  controller.notice == null) ...[
                const SizedBox(height: 10),
                AppText(
                  controller.hasMore ? '本批没有找到结果，可继续搜索下一批书源。' : '没有找到匹配的书籍。',
                  style: TextStyle(color: colorScheme.onSurfaceVariant),
                ),
              ],
              if (visibleResults.isNotEmpty) ...[
                const SizedBox(height: 12),
                for (final result in visibleResults)
                  _LegadoResultCard(result: result),
              ],
              if ((!currentQuery || controller.loading) &&
                  visibleResults.isEmpty) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(),
              ],
              if (currentQuery &&
                  !controller.loading &&
                  controller.hasMore) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassTextButton(
                    key: const ValueKey('legado-search-next-batch'),
                    onPressed: controller.searchNextBatch,
                    child: const AppText('继续搜索下一批书源（最多 32 个）'),
                  ),
                ),
              ],
              if (currentQuery &&
                  !controller.loading &&
                  !controller.hasMore &&
                  controller.checkedSources > 0) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: GlassTextButton(
                    key: const ValueKey('legado-search-refresh'),
                    onPressed: controller.refresh,
                    child: const AppText('重新搜索阅读书源'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _LegadoResultCard extends StatelessWidget {
  const _LegadoResultCard({required this.result});

  final LegadoBookSearchResult result;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(ArchiveDesign.panelRadius);
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Material(
        color: scheme.surfaceContainerLow.withValues(alpha: .76),
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: result.url == null
              ? null
              : () async {
                  final launched = await launchUrl(
                    result.url!,
                    mode: LaunchMode.externalApplication,
                  );
                  if (!launched && context.mounted) {
                    showNovelFeedback(context, '无法打开该书源的书籍页面');
                  }
                },
          child: Container(
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(
                color: scheme.outlineVariant.withValues(alpha: .55),
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: AppText(
                        result.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (result.url != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.open_in_new,
                        size: 15,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 5),
                AppText(
                  [
                    if (result.author.isNotEmpty) result.author,
                    result.sourceName,
                  ].join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                if (result.summary?.isNotEmpty == true) ...[
                  const SizedBox(height: 6),
                  AppText(
                    result.summary!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: scheme.onSurfaceVariant,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchRequest {
  const _SearchRequest({
    required this.url,
    required this.method,
    this.body,
    this.charset,
    this.bodyCharset,
    this.headers = const {},
  });

  final String url;
  final String method;
  final String? body;
  final String? charset;
  final String? bodyCharset;
  final Map<String, String> headers;
}

_SearchRequest _parseSearchRequest(String value, String query) {
  var urlTemplate = value.trim();
  if (urlTemplate.startsWith('@js:') || urlTemplate.startsWith('<js>')) {
    throw const _UnsupportedBookSourceRule();
  }
  Map<String, Object?> options = const {};
  final delimiter = RegExp(r',\s*\{').firstMatch(urlTemplate);
  if (delimiter != null) {
    final start = delimiter.start;
    final jsonStart = urlTemplate.indexOf('{', delimiter.start);
    try {
      final decoded = _decodeRequestOptions(urlTemplate.substring(jsonStart));
      if (decoded is! Map) throw const _UnsupportedBookSourceRule();
      options = Map<String, Object?>.from(decoded);
      urlTemplate = urlTemplate.substring(0, start).trim();
    } on FormatException {
      throw const _UnsupportedBookSourceRule();
    }
  }

  final charset = options['charset']?.toString().trim();
  final url = _interpolateSearchTemplate(urlTemplate, query, charset: charset);
  final method = (options['method'] ?? 'GET').toString().toUpperCase();
  final rawBody = options['body'];
  String? body;
  var contentType = _optionHeader(options, 'Content-Type');
  if (rawBody is String) {
    body = _interpolateBody(
      rawBody,
      query,
      json: contentType?.contains('json') == true,
      charset: charset,
    );
  } else if (rawBody is Map || rawBody is List) {
    body = jsonEncode(_interpolateJsonValue(rawBody, query));
    contentType ??= 'application/json; charset=utf-8';
  }
  final bodyCharset = body == null
      ? null
      : _contentTypeCharset(contentType) ??
            (contentType?.toLowerCase().contains('json') == true
                ? 'utf-8'
                : charset);
  final headers = <String, String>{
    for (final entry in _headerMap(options['headers']).entries)
      entry.key: entry.value,
  };
  if (contentType != null) headers['Content-Type'] = contentType;
  return _SearchRequest(
    url: url,
    method: method,
    body: body,
    charset: charset,
    bodyCharset: bodyCharset,
    headers: headers,
  );
}

Object? _decodeRequestOptions(String value) {
  try {
    return jsonDecode(value);
  } on FormatException {
    final converted = StringBuffer();
    var index = 0;
    while (index < value.length) {
      final char = value[index];
      if (char == '"') {
        final start = index++;
        var escaped = false;
        while (index < value.length) {
          final next = value[index++];
          if (escaped) {
            escaped = false;
          } else if (next == r'\') {
            escaped = true;
          } else if (next == '"') {
            break;
          }
        }
        converted.write(value.substring(start, index));
      } else if (char == "'") {
        final decoded = StringBuffer();
        index++;
        var closed = false;
        while (index < value.length) {
          final next = value[index++];
          if (next == "'") {
            closed = true;
            break;
          }
          if (next == r'\' && index < value.length) {
            final escaped = value[index++];
            decoded.write(switch (escaped) {
              'n' => '\n',
              'r' => '\r',
              't' => '\t',
              'b' => '\b',
              'f' => '\f',
              'u' when index + 4 <= value.length => String.fromCharCode(
                int.tryParse(value.substring(index, index + 4), radix: 16) ??
                    0xfffd,
              ),
              'u' => '\uFFFD',
              _ => escaped,
            });
            if (escaped == 'u' && index + 4 <= value.length) index += 4;
          } else {
            decoded.write(next);
          }
        }
        if (!closed) throw const FormatException('未闭合的书源请求选项字符串');
        converted.write(jsonEncode(decoded.toString()));
      } else {
        converted.write(char);
        index++;
      }
    }
    final normalized = converted.toString().replaceAll(
      RegExp(r',\s*([}\]])'),
      r'$1',
    );
    return jsonDecode(normalized);
  }
}

String _interpolateSearchTemplate(
  String template,
  String query, {
  String? charset,
}) => template.replaceAllMapped(RegExp(r'\{\{\s*(.*?)\s*\}\}'), (match) {
  final expression = match.group(1)!.trim();
  if (expression == 'key' || expression == 'keyEncode') {
    return _encodeUrlComponent(query, charset: charset);
  }
  if (expression == 'page') return '1';
  final pageValue = _pageExpression(expression);
  if (pageValue != null) return '$pageValue';
  throw const _UnsupportedBookSourceRule();
});

String _interpolateBody(
  String template,
  String query, {
  required bool json,
  String? charset,
}) => template.replaceAllMapped(RegExp(r'\{\{\s*(.*?)\s*\}\}'), (match) {
  final expression = match.group(1)!.trim();
  if (expression == 'key' || expression == 'keyEncode') {
    if (!json) {
      return _percentEncode(
        _requestEncoding(charset).encode(query),
        form: true,
      );
    }
    final encoded = jsonEncode(query);
    return encoded.substring(1, encoded.length - 1);
  }
  if (expression == 'page') return '1';
  final pageValue = _pageExpression(expression);
  if (pageValue != null) return '$pageValue';
  throw const _UnsupportedBookSourceRule();
});

Encoding _requestEncoding(String? charset) {
  if (charset == null || charset.trim().isEmpty) return utf8;
  return Charset.getByName(charset.trim()) ?? utf8;
}

String _encodeUrlComponent(String value, {String? charset}) =>
    _percentEncode(_requestEncoding(charset).encode(value));

String _percentEncode(List<int> bytes, {bool form = false}) {
  const hex = '0123456789ABCDEF';
  final output = StringBuffer();
  for (final byte in bytes) {
    final unreserved =
        (byte >= 0x41 && byte <= 0x5a) ||
        (byte >= 0x61 && byte <= 0x7a) ||
        (byte >= 0x30 && byte <= 0x39) ||
        byte == 0x2d ||
        byte == 0x2e ||
        byte == 0x5f ||
        byte == 0x7e;
    if (unreserved) {
      output.writeCharCode(byte);
    } else if (form && byte == 0x20) {
      output.write('+');
    } else {
      output
        ..write('%')
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0x0f]);
    }
  }
  return output.toString();
}

String _decodeSearchResponse(List<int> bytes, String? requestedCharset) {
  final declared = requestedCharset ?? _htmlDeclaredCharset(bytes);
  final encoding = declared == null ? null : Charset.getByName(declared);
  if (encoding != null) {
    try {
      return encoding.decode(bytes);
    } on FormatException {
      if (encoding.name.toLowerCase() == 'gbk') {
        return gbk.decode(bytes, allowMalformed: true);
      }
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbk.decode(bytes, allowMalformed: true);
  }
}

String? _htmlDeclaredCharset(List<int> bytes) {
  final prefix = latin1.decode(bytes.take(4096).toList());
  return RegExp(
    r'''<meta\b[^>]*\bcharset\s*=\s*["']?([^\s"'/>;]+)''',
    caseSensitive: false,
  ).firstMatch(prefix)?.group(1);
}

String? _contentTypeCharset(String? contentType) => contentType == null
    ? null
    : RegExp(
        r'''charset\s*=\s*["']?([^;"'\s]+)''',
        caseSensitive: false,
      ).firstMatch(contentType)?.group(1);

Object? _interpolateJsonValue(Object? value, String query) {
  if (value is String) {
    return value.replaceAllMapped(RegExp(r'\{\{\s*(.*?)\s*\}\}'), (match) {
      final expression = match.group(1)!.trim();
      if (expression == 'key' || expression == 'keyEncode') return query;
      if (expression == 'page') return '1';
      final pageValue = _pageExpression(expression);
      if (pageValue != null) return '$pageValue';
      throw const _UnsupportedBookSourceRule();
    });
  }
  if (value is List) {
    return [for (final item in value) _interpolateJsonValue(item, query)];
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        entry.key.toString(): _interpolateJsonValue(entry.value, query),
    };
  }
  return value;
}

int? _pageExpression(String expression) {
  final normalized = expression.replaceAll(RegExp(r'\s+'), '');
  if (normalized == 'page-1' || normalized == '(page-1)') return 0;
  final pattern = RegExp(r'^\(?page([+-]\d+)?\)?(?:\*([+-]?\d+))?$');
  final match = pattern.firstMatch(normalized);
  if (match == null) return null;
  final offset = int.tryParse(match.group(1) ?? '') ?? 0;
  final multiplier = int.tryParse(match.group(2) ?? '') ?? 1;
  return (1 + offset) * multiplier;
}

String? _optionHeader(Map<String, Object?> options, String key) {
  final headers = _headerMap(options['headers']);
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == key.toLowerCase()) return entry.value;
  }
  final direct = options[key];
  return direct is String ? direct : null;
}

Map<String, String> _sourceHeaders(Object? value) {
  final headers = _headerMap(value);
  return {
    'Accept': 'text/html,application/json;q=0.9,*/*;q=0.8',
    for (final entry in headers.entries) entry.key: entry.value,
  };
}

Map<String, String> _headerMap(Object? value) {
  Object? decoded = value;
  if (decoded is String && decoded.trim().isNotEmpty) {
    try {
      decoded = jsonDecode(decoded);
    } on FormatException {
      return const {};
    }
  }
  if (decoded is! Map) return const {};
  return {
    for (final entry in decoded.entries)
      if (entry.value != null) entry.key.toString(): entry.value.toString(),
  };
}

Uri _baseSourceUrl(String value) {
  final clean = value.split('##').first.trim();
  final parsed = Uri.tryParse(clean);
  if (parsed == null || parsed.host.isEmpty) {
    throw const FormatException('书源地址无效');
  }
  return parsed;
}

Uri? _resolveResultUrl(String value, Uri base) {
  final clean = value.trim();
  if (clean.isEmpty || clean.contains('{{') || clean.contains('}}'))
    return null;
  final uri = Uri.tryParse(clean);
  if (uri == null) return null;
  if ((uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty) {
    return uri;
  }
  if (clean.startsWith('//')) return Uri.parse(base.scheme + ':' + clean);
  try {
    final resolved = base.resolveUri(uri);
    return (resolved.scheme == 'http' || resolved.scheme == 'https') &&
            resolved.host.isNotEmpty
        ? resolved
        : null;
  } on FormatException {
    return null;
  }
}

class _SearchDocument {
  _SearchDocument(this.body, {this.jsonRoot, this.document});

  final String body;
  final Object? jsonRoot;
  final dom.Document? document;

  factory _SearchDocument.parse(String body) {
    final trimmed = body.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return _SearchDocument(body, jsonRoot: jsonDecode(body));
      } on FormatException {
        // Some web servers prefix JSON with anti-XSSI text; parse as HTML below.
      }
    }
    return _SearchDocument(body, document: html.parse(body));
  }

  List<Object?> bookList(String rawRule) {
    final rule = rawRule.trim();
    if (_containsScript(rule)) throw const _UnsupportedBookSourceRule();
    if (jsonRoot != null) {
      final selected = _jsonRule(jsonRoot, rule);
      if (selected == null) return const [];
      if (selected is List) return selected.cast<Object?>();
      return [selected];
    }
    final root = document?.documentElement;
    if (root == null) return const [];
    final selected = _selectHtml(root, rule, extractValue: false);
    if (selected is List) return selected.cast<Object?>();
    return selected == null ? const [] : [selected];
  }

  Object? ruleValue(Object? rawRule, Object? item) {
    if (rawRule is! String || rawRule.trim().isEmpty) return null;
    var rule = rawRule.trim();
    if (_containsScript(rule)) {
      final jsAt = rule.lastIndexOf('@js:');
      if (jsAt < 0) throw const _UnsupportedBookSourceRule();
      final expression = rule.substring(jsAt + 4).trim();
      final baseRule = rule.substring(0, jsAt);
      final value = ruleValue(baseRule, item);
      return _simpleJs(expression, value);
    }
    final parts = _splitRegex(rule);
    rule = parts.rule;
    Object? value;
    if (jsonRoot != null || item is Map || item is List) {
      final template = _jsonTemplate(rule, item);
      value = template ?? _jsonRule(item ?? jsonRoot, rule);
    } else if (item is dom.Element) {
      value = _selectHtml(item, rule, extractValue: true);
    } else {
      value = rule;
    }
    return _applyRegex(value, parts.pattern, parts.replacement);
  }
}

bool _containsScript(String rule) =>
    rule.startsWith('<js>') ||
    rule.startsWith('@js:') ||
    rule.contains('@js:') ||
    rule.contains('<js>\n') ||
    rule.contains('{{@js:');

Object? _selectHtml(
  dom.Element root,
  String rule, {
  required bool extractValue,
}) {
  if (rule.startsWith('@xpath:') || rule.startsWith('xpath:')) {
    throw const _UnsupportedBookSourceRule();
  }

  if (rule.startsWith('@css:')) {
    var selector = rule.substring(5).trim();
    var output = 'text';
    final suffix = RegExp(r'\s+@(text|html|href|src|value|content)$');
    final match = suffix.firstMatch(selector);
    if (match != null) {
      output = match.group(1)!;
      selector = selector.substring(0, match.start).trim();
    } else if (selector.contains('@')) {
      final parts = selector.split('@');
      selector = parts.first.trim();
      output = parts.last.trim();
    }
    final elements = _cssElements(root, selector);
    if (!extractValue) return elements;
    return _extractElements(elements, output);
  }

  final parts = rule.split('@');
  var current = <dom.Element>[root];
  for (final partValue in parts) {
    final part = partValue.trim();
    if (part.isEmpty) continue;
    if (_isHtmlExtractor(part)) {
      if (!extractValue) return current;
      return _extractElements(current, part);
    }
    current = _selectHtmlSegment(current, part);
  }
  if (!extractValue) return current;
  return current.isEmpty ? null : current.first.text.trim();
}

List<dom.Element> _selectHtmlSegment(List<dom.Element> roots, String segment) {
  final bits = segment.split('.');
  var index = -1;
  if (bits.isNotEmpty && int.tryParse(bits.last) != null) {
    index = int.parse(bits.removeLast());
  }
  final first = bits.isEmpty ? '' : bits.first;
  final selector = switch (first) {
    'tag' when bits.length >= 2 => bits.skip(1).join(''),
    'class' when bits.length >= 2 => '.' + bits.skip(1).join('.'),
    'id' when bits.length >= 2 => '#' + bits.skip(1).join('.'),
    _ => segment,
  };
  final found = <dom.Element>[];
  for (final root in roots) {
    found.addAll(_cssElements(root, selector));
  }
  if (index >= 0) {
    return index < found.length ? [found[index]] : const [];
  }
  return found;
}

List<dom.Element> _cssElements(dom.Element root, String selector) {
  try {
    return root.querySelectorAll(selector);
  } on FormatException {
    throw const _UnsupportedBookSourceRule();
  }
}

bool _isHtmlExtractor(String value) =>
    const {
      'text',
      'html',
      'textNodes',
      'ownText',
      'href',
      'src',
      'value',
      'content',
      'tag',
    }.contains(value) ||
    value.startsWith('attr:') ||
    RegExp(r'^[A-Za-z_:][A-Za-z0-9_:.-]*$').hasMatch(value);

Object? _extractElements(List<dom.Element> elements, String extractor) {
  final values = [
    for (final element in elements)
      switch (extractor) {
        'text' => element.text.trim(),
        'textNodes' || 'ownText' =>
          element.nodes
              .whereType<dom.Text>()
              .map((node) => node.text)
              .join()
              .trim(),
        'html' => element.innerHtml,
        'tag' => element.localName,
        'href' ||
        'src' ||
        'value' ||
        'content' => element.attributes[extractor],
        _ when extractor.startsWith('attr:') =>
          element.attributes[extractor.substring(5)],
        _ => element.attributes[extractor] ?? element.text.trim(),
      },
  ];
  final present = values.where((value) => value != null).toList();
  if (present.isEmpty) return null;
  return present.length == 1 ? present.single : present;
}

class _RuleParts {
  const _RuleParts(this.rule, this.pattern, this.replacement);

  final String rule;
  final String? pattern;
  final String replacement;
}

_RuleParts _splitRegex(String rule) {
  final parts = rule.split('##');
  if (parts.length >= 2) {
    return _RuleParts(parts.first, parts[1], parts.length >= 3 ? parts[2] : '');
  }
  return _RuleParts(rule, null, '');
}

Object? _applyRegex(Object? value, String? pattern, String replacement) {
  if (value is List) {
    return [for (final item in value) _applyRegex(item, pattern, replacement)];
  }
  if (value == null || pattern == null) return value;
  try {
    final expression = RegExp(pattern, dotAll: true);
    return value.toString().replaceAllMapped(expression, (match) {
      if (replacement.isEmpty) return '';
      return replacement.replaceAllMapped(RegExp(r'\$(\d+)'), (group) {
        final index = int.tryParse(group.group(1)!);
        return index == null ? group.group(0)! : (match.group(index) ?? '');
      });
    });
  } on FormatException {
    return value;
  }
}

Object? _jsonTemplate(String rule, Object? item) {
  final matches = RegExp(r'\{\{\s*(.*?)\s*\}\}').allMatches(rule);
  if (matches.isEmpty) return null;
  return rule.replaceAllMapped(RegExp(r'\{\{\s*(.*?)\s*\}\}'), (match) {
    final expression = match.group(1)!.trim();
    if (expression == 'key') return '';
    return _stringValue(_jsonRule(item, expression));
  });
}

Object? _jsonRule(Object? root, String rule) {
  final path = rule.trim();
  if (path.isEmpty) return root;
  if (path.startsWith('<js>') ||
      path.contains('&&') ||
      path.startsWith('@js:') ||
      path.startsWith('@xpath:') ||
      path.startsWith('xpath:')) {
    throw const _UnsupportedBookSourceRule();
  }
  if (path.startsWith(r'$') || path.startsWith('@')) {
    return _jsonPath(root, path);
  }
  if (root is Map && root.containsKey(path)) return root[path];
  if (RegExp(r'^[A-Za-z_][A-Za-z0-9_.\[\]-]*$').hasMatch(path)) {
    return _jsonPath(root, r'$.' + path);
  }
  return null;
}

Object? _jsonPath(Object? root, String path) {
  var normalized = path.trim();
  if (normalized.startsWith('@')) normalized = r'$' + normalized.substring(1);
  if (!normalized.startsWith(r'$')) return null;
  final tokens = <String>[];
  var i = 1;
  while (i < normalized.length) {
    if (normalized.startsWith('..', i)) {
      tokens.add('..');
      i += 2;
      continue;
    }
    final char = normalized[i];
    if (char == '.') {
      i++;
      continue;
    }
    if (char == '[') {
      final end = normalized.indexOf(']', i + 1);
      if (end < 0) return null;
      var token = normalized.substring(i + 1, end).trim();
      if ((token.startsWith('"') && token.endsWith('"')) ||
          (token.startsWith("'") && token.endsWith("'"))) {
        token = token.substring(1, token.length - 1);
      }
      tokens.add(token);
      i = end + 1;
      continue;
    }
    final start = i;
    while (i < normalized.length &&
        normalized[i] != '.' &&
        normalized[i] != '[') {
      i++;
    }
    tokens.add(normalized.substring(start, i));
  }

  var current = <Object?>[root];
  for (var tokenIndex = 0; tokenIndex < tokens.length; tokenIndex++) {
    final token = tokens[tokenIndex];
    if (token == '..') {
      if (tokenIndex + 1 >= tokens.length) return null;
      final key = tokens[++tokenIndex];
      current = [for (final node in current) ..._recursiveJsonKey(node, key)];
      continue;
    }
    final next = <Object?>[];
    for (final value in current) {
      if (token == '*' || token.isEmpty) {
        if (value is List) next.addAll(value);
        if (value is Map) next.addAll(value.values);
      } else {
        final index = int.tryParse(token);
        if (index != null) {
          if (value is List && index >= 0 && index < value.length) {
            next.add(value[index]);
          }
        } else if (value is Map && value.containsKey(token)) {
          next.add(value[token]);
        } else if (value is List) {
          for (final entry in value) {
            if (entry is Map && entry.containsKey(token))
              next.add(entry[token]);
          }
        }
      }
    }
    current = next;
    if (current.isEmpty) return null;
  }
  if (current.length == 1) return current.single;
  return current;
}

List<Object?> _recursiveJsonKey(Object? value, String key) {
  final matches = <Object?>[];
  void visit(Object? node) {
    if (node is Map) {
      if (node.containsKey(key)) matches.add(node[key]);
      for (final child in node.values) {
        visit(child);
      }
    } else if (node is List) {
      for (final child in node) {
        visit(child);
      }
    }
  }

  visit(value);
  return matches;
}

Object? _simpleJs(String expression, Object? result) {
  final parts = expression.split('+').map((value) => value.trim()).toList();
  final output = StringBuffer();
  for (final part in parts) {
    if (part == 'result' || part == 'String(result)') {
      output.write(_stringValue(result));
    } else if ((part.startsWith("'") && part.endsWith("'")) ||
        (part.startsWith('"') && part.endsWith('"'))) {
      output.write(part.substring(1, part.length - 1));
    } else {
      throw const _UnsupportedBookSourceRule();
    }
  }
  return output.toString();
}

String _stringValue(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  if (value is List) return value.map(_stringValue).join(' ');
  if (value is Map) return jsonEncode(value);
  if (value is dom.Element) return value.text.trim();
  return value.toString();
}

String _plainText(String value) =>
    html.parse(value).documentElement?.text.trim() ?? value.trim();

class _UnsupportedBookSourceRule implements Exception {
  const _UnsupportedBookSourceRule();
}
