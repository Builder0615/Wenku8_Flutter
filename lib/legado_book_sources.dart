import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as html;
import 'package:path_provider/path_provider.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'book_documents.dart';
import 'feature_pages.dart';
import 'local_platform.dart';

const _maxLegadoSourceBytes = 32 * 1024 * 1024;
const _maxLegadoSourceCount = 12000;
const _aoaostarBookSourceCatalog =
    'https://raw.githubusercontent.com/aoaostar/legado/release/index.html';

class LegadoCatalogSource {
  const LegadoCatalogSource({required this.name, required this.url});

  final String name;
  final String url;
}

class LegadoBookSource {
  const LegadoBookSource(this.record);

  final Map<String, Object?> record;

  String get name => record['bookSourceName'] as String;
  String get url => record['bookSourceUrl'] as String;
  bool get enabled => record['enabled'] != false;
  String get group => record['bookSourceGroup'] is String
      ? record['bookSourceGroup'] as String
      : '';
}

class LegadoSourceImportReport {
  const LegadoSourceImportReport({required this.added, required this.updated});

  final int added;
  final int updated;
  int get total => added + updated;
}

List<LegadoBookSource> parseLegadoBookSources(String text) {
  if (utf8.encode(text).length > _maxLegadoSourceBytes) {
    throw const FormatException('书源文件超过 32 MiB 导入上限');
  }
  final decoded = jsonDecode(text);
  final records = switch (decoded) {
    List value => value,
    Map value => [value],
    _ => throw const FormatException('阅读书源 JSON 应为对象或数组'),
  };
  if (records.isEmpty) throw const FormatException('没有可导入的书源');
  if (records.length > _maxLegadoSourceCount) {
    throw const FormatException('单次最多导入 12000 个书源');
  }

  final unique = <String, LegadoBookSource>{};
  for (var index = 0; index < records.length; index++) {
    final value = records[index];
    if (value is! Map) {
      throw FormatException('第 ${index + 1} 条书源不是 JSON 对象');
    }
    final record = Map<String, Object?>.from(value);
    final name = record['bookSourceName'];
    final url = record['bookSourceUrl'];
    if (name is! String || name.trim().isEmpty) {
      throw FormatException('第 ${index + 1} 条书源缺少 bookSourceName');
    }
    if (url is! String || url.trim().isEmpty) {
      throw FormatException('第 ${index + 1} 条书源缺少 bookSourceUrl');
    }
    record['bookSourceName'] = name.trim();
    record['bookSourceUrl'] = url.trim();
    final source = LegadoBookSource(Map.unmodifiable(record));
    unique[source.url] = source;
  }
  return List.unmodifiable(unique.values);
}

List<LegadoCatalogSource> parseLegadoCatalog(String source) {
  final document = html.parse(source);
  final unique = <String, LegadoCatalogSource>{};
  for (final anchor in document.querySelectorAll(
    'a[href^="legado://import/bookSource"]',
  )) {
    final uri = Uri.tryParse(anchor.attributes['href'] ?? '');
    final url = uri?.queryParameters['src'];
    if (url == null || !_isHttpUrl(url)) continue;

    var element = anchor.parent;
    while (element != null &&
        !(element.localName == 'li' && element.querySelector('p') != null)) {
      element = element.parent;
    }
    final name = element?.querySelector('p')?.text.trim();
    unique[url] = LegadoCatalogSource(
      name: name == null || name.isEmpty ? '书源集 ${unique.length + 1}' : name,
      url: url,
    );
  }
  if (unique.isEmpty) throw const FormatException('AOAOSTAR 仓库中没有可导入的书源');
  return List.unmodifiable(unique.values);
}

class LegadoBookSourceStore extends ChangeNotifier {
  List<LegadoBookSource> _sources = const [];
  bool _loaded = false;
  String? loadError;
  Future<File>? _fileFuture;
  Future<void>? _loadFuture;

  List<LegadoBookSource> get sources => _sources;
  bool get loaded => _loaded;

  Future<File> _file() => _fileFuture ??= () async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}/legado_book_sources.json');
  }();

  Future<void> load() {
    if (_loaded) return Future<void>.value();
    return _loadFuture ??= _load();
  }

  Future<void> _load() async {
    try {
      final file = await _file();
      if (await file.exists()) {
        if (await file.length() > _maxLegadoSourceBytes) {
          throw const FormatException('本地书源文件超过读取上限');
        }
        _sources = parseLegadoBookSources(await file.readAsString());
      }
    } catch (_) {
      loadError = '书源列表读取失败；重新导入不会影响本地书籍和阅读记录';
    } finally {
      _loaded = true;
      _loadFuture = null;
      notifyListeners();
    }
  }

  Future<LegadoSourceImportReport> importText(String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) throw const FormatException('请粘贴书源 JSON 或直链');
    final sourceUrl = _sourceInputUrl(trimmed);
    final text = sourceUrl == null ? trimmed : await _download(sourceUrl);
    final imported = parseLegadoBookSources(text);
    if (!_loaded) await load();

    final merged = <String, LegadoBookSource>{
      for (final source in _sources) source.url: source,
    };
    var added = 0;
    var updated = 0;
    for (final source in imported) {
      if (merged.containsKey(source.url)) {
        updated++;
      } else {
        added++;
      }
      merged[source.url] = source;
    }
    await _save(List.unmodifiable(merged.values));
    return LegadoSourceImportReport(added: added, updated: updated);
  }

  Future<void> remove(String url) async {
    final next = _sources.where((source) => source.url != url).toList();
    if (next.length == _sources.length) return;
    await _save(List.unmodifiable(next));
  }

  Future<void> _save(List<LegadoBookSource> next) async {
    final file = await _file();
    final text = jsonEncode([for (final source in next) source.record]);
    if (utf8.encode(text).length > _maxLegadoSourceBytes) {
      throw const FormatException('保存后的书源列表超过 32 MiB 上限');
    }
    final temporary = File('${file.path}.tmp');
    try {
      await temporary.writeAsString(text, flush: true);
      if (await file.exists()) await file.delete();
      await temporary.rename(file.path);
      _sources = next;
      _loaded = true;
      loadError = null;
      notifyListeners();
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }
}

bool _isHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  return uri != null &&
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      uri.host.isNotEmpty;
}

String? _sourceInputUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (_isHttpUrl(value)) return value;
  if (uri.scheme == 'legado' &&
      uri.host == 'import' &&
      uri.path == '/bookSource') {
    final source = uri.queryParameters['src'];
    if (source != null && _isHttpUrl(source)) return source;
  }
  return null;
}

Uri _sourceUri(String value) {
  var uri = Uri.parse(value);
  final parts = uri.pathSegments;
  if (uri.host.toLowerCase() == 'github.com' &&
      parts.length >= 5 &&
      parts[2] == 'blob') {
    uri = Uri.https(
      'raw.githubusercontent.com',
      '/${parts[0]}/${parts[1]}/${parts.skip(3).join('/')}',
    );
  }
  return uri;
}

Future<String> _download(String value) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client
        .getUrl(_sourceUri(value))
        .timeout(const Duration(seconds: 20));
    request.headers.set(
      HttpHeaders.userAgentHeader,
      'Wenku8Flutter-LegadoImport',
    );
    final response = await request.close().timeout(const Duration(seconds: 25));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException('书源链接返回 HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 30))) {
      if (bytes.length + chunk.length > _maxLegadoSourceBytes) {
        throw const FormatException('书源链接内容超过 32 MiB 导入上限');
      }
      bytes.addAll(chunk);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw const FormatException('书源文件不是有效的 UTF-8 JSON');
    }
  } on TimeoutException {
    throw const FormatException('书源链接读取超时，请检查网络后重试');
  } on SocketException {
    throw const FormatException('书源链接无法访问，请检查网络和链接');
  } finally {
    client.close(force: true);
  }
}

class LegadoBookSourcesPage extends StatefulWidget {
  const LegadoBookSourcesPage({
    super.key,
    required this.store,
    this.showHeader = true,
  });

  final LegadoBookSourceStore store;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: ArchiveMasthead(title: '阅读书源', code: 'READING / BOOK SOURCES'),
  );

  @override
  State<LegadoBookSourcesPage> createState() => _LegadoBookSourcesPageState();
}

class _LegadoBookSourcesPageState extends State<LegadoBookSourcesPage> {
  final _documents = BookDocuments();
  bool _busy = false;
  String? _error;

  Future<void> _pasteOrLink() async {
    final controller = TextEditingController();
    final text = await showJellySheet<String>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      heightFactor: .9,
      builder: (sheet) => ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          MediaQuery.viewInsetsOf(sheet).bottom + 24,
        ),
        children: [
          const ArchiveSection(title: '导入阅读书源', code: 'JSON / URL'),
          const SizedBox(height: 12),
          const AppText('粘贴 JSON、书源直链或 Legado 一键导入链接。'),
          const SizedBox(height: 14),
          CupertinoTextField(
            key: const ValueKey('legado-source-input'),
            controller: controller,
            minLines: 7,
            maxLines: 14,
            keyboardType: TextInputType.multiline,
            placeholder: 'JSON 内容、https://…/source.json 或 legado://…',
            padding: const EdgeInsets.all(14),
            style: TextStyle(
              color: Theme.of(sheet).colorScheme.onSurface,
              fontSize: 13,
              height: 1.5,
            ),
            decoration: BoxDecoration(
              color: Theme.of(
                sheet,
              ).colorScheme.onSurface.withValues(alpha: .045),
              borderRadius: BorderRadius.circular(ArchiveDesign.panelRadius),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 8,
            children: [
              GlassTextButton(
                onPressed: () async {
                  final clipboard = await Clipboard.getData(
                    Clipboard.kTextPlain,
                  );
                  if (clipboard?.text case final value?) {
                    controller.text = value;
                  }
                },
                child: const AppText('粘贴剪贴板'),
              ),
              GlassTextButton(
                onPressed: () => Navigator.pop(sheet),
                child: const AppText('取消'),
              ),
              GlassTextButton(
                key: const ValueKey('legado-source-import-submit'),
                onPressed: () => Navigator.pop(sheet, controller.text),
                child: const AppText('导入'),
              ),
            ],
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || text == null) return;
    await _import(text);
  }

  Future<void> _pickJson() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    BookDocumentSelection? selected;
    try {
      selected = await _documents.pickJson();
      if (selected == null || selected.path == null) return;
      await _import(
        await File(selected.path!).readAsString(),
        busyAlready: true,
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = _message(error));
      }
    } finally {
      if (selected != null) {
        await _documents.releaseBooks([selected]);
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _browseAoAostar() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    List<LegadoCatalogSource> catalog;
    try {
      catalog = parseLegadoCatalog(await _download(_aoaostarBookSourceCatalog));
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    final selected = await showJellySheet<LegadoCatalogSource>(
      context: context,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      heightFactor: .9,
      builder: (sheet) => ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          12,
          24,
          MediaQuery.paddingOf(sheet).bottom + 24,
        ),
        children: [
          const ArchiveSection(title: 'AOAOSTAR 书源库', code: 'BOOK SOURCE SETS'),
          const SizedBox(height: 12),
          const AppText('选择一个书源集导入。重复书源会按地址更新。'),
          const SizedBox(height: 12),
          for (final source in catalog) ...[
            ContentPanel(
              key: ValueKey('legado-catalog-${source.url}'),
              onTap: () => Navigator.pop(sheet, source),
              child: Row(
                children: [
                  const Icon(CupertinoIcons.book, size: 19),
                  const SizedBox(width: 12),
                  Expanded(child: AppText(source.name)),
                  const SizedBox(width: 8),
                  const Icon(CupertinoIcons.chevron_right, size: 14),
                ],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
    if (selected != null && mounted) await _import(selected.url);
  }

  Future<void> _import(String text, {bool busyAlready = false}) async {
    if (_busy && !busyAlready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final report = await widget.store.importText(text);
      if (mounted) {
        showNovelFeedback(
          context,
          '已导入 ${report.added} 个、更新 ${report.updated} 个书源',
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = _message(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _message(Object error) =>
      error is FormatException ? error.message : '书源导入失败，请检查文件或链接后重试';

  Future<void> _remove(LegadoBookSource source) async {
    if (!await confirmNovelAction(
      context,
      title: '移除这个书源？',
      message: '“${source.name}”的书源配置将从本机删除。',
      confirmLabel: '移除书源',
      reduceMotion: MediaQuery.disableAnimationsOf(context),
    )) {
      return;
    }
    try {
      await widget.store.remove(source.url);
    } catch (_) {
      if (mounted) showNovelFeedback(context, '书源移除失败，请重试');
    }
  }

  Widget _sourceCard(LegadoBookSource source, int index) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: ContentPanel(
      key: ValueKey('legado-source-$index'),
      child: Row(
        children: [
          const Icon(CupertinoIcons.book, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppText(
                  source.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (source.group.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  AppText(
                    source.group,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 5),
                AppText(
                  source.url,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '移除 ${source.name}',
            onPressed: _busy ? null : () => _remove(source),
            icon: const Icon(CupertinoIcons.trash, size: 19),
          ),
        ],
      ),
    ),
  );

  Widget _content(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final sources = widget.store.sources;
      return ListView.builder(
        key: const PageStorageKey('legado-book-sources'),
        padding: EdgeInsets.fromLTRB(
          24,
          MediaQuery.paddingOf(context).top + FrostedHeader.toolbarHeight + 20,
          24,
          MediaQuery.paddingOf(context).bottom + 36,
        ),
        itemCount: sources.isEmpty ? 1 : sources.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ContentPanel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      sectionHeader(context, '阅读书源', '${sources.length} 个'),
                      const SizedBox(height: 10),
                      const AppText(
                        '支持 Legado 格式 JSON、文件、直链与 AOAOSTAR 目录。已启用书源会参与发现页搜索；支持常见 GET/POST、网页选择器和基础 JSONPath，结果可打开来源网页。书源配置保存在本机。',
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        children: [
                          GlassTextButton(
                            key: const ValueKey('legado-source-import-text'),
                            onPressed: _busy ? null : _pasteOrLink,
                            child: const AppText('粘贴 JSON 或直链'),
                          ),
                          GlassTextButton(
                            key: const ValueKey(
                              'legado-source-import-aoaostar',
                            ),
                            onPressed: _busy ? null : _browseAoAostar,
                            child: const AppText('从 AOAOSTAR 书库选择'),
                          ),
                          if (LocalPlatform.android)
                            GlassTextButton(
                              key: const ValueKey('legado-source-import-file'),
                              onPressed: _busy ? null : _pickJson,
                              child: const AppText('选择 JSON 文件'),
                            ),
                        ],
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 8),
                        const LoadingSkeleton(
                          layout: SkeletonLayout.actions,
                          label: '正在导入书源',
                        ),
                      ],
                      FeatureError(_error ?? widget.store.loadError),
                    ],
                  ),
                ),
                if (sources.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  sectionHeader(context, '已保存', '${sources.length} 个'),
                  const SizedBox(height: 12),
                ],
              ],
            );
          }
          return _sourceCard(sources[index - 1], index - 1);
        },
      );
    },
  );

  Widget _header(BuildContext context) => Row(
    children: [
      if (widget.showHeader)
        const Expanded(
          child: ArchiveMasthead(title: '阅读书源', code: 'READING / BOOK SOURCES'),
        )
      else
        const Expanded(child: SizedBox.shrink()),
      if (widget.showHeader) ...[
        GlassIconButton(
          icon: CupertinoIcons.add,
          label: '导入书源',
          onPressed: _busy ? null : _pasteOrLink,
        ),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) => GlassHeaderLayout(
    showHeader: widget.showHeader,
    header: _header(context),
    body: _content(context),
  );
}
