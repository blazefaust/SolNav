import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../providers/app_providers.dart';
import '../responsive.dart';
import '../theme.dart';
import '../widgets/mc_common.dart';

/// SolNav v7 (Three.js Mars globe) is served by the FastAPI backend at /solnav/.
/// The controller is kept at file level so switching tabs does not reload the
/// 8K texture / normal map every time; the globe keeps its state.
WebViewController? _controller;
String? _loadedUrl;

bool get _webViewSupported =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS);

class SolNavScreen extends ConsumerStatefulWidget {
  const SolNavScreen({super.key});

  @override
  ConsumerState<SolNavScreen> createState() => _SolNavScreenState();
}

class _SolNavScreenState extends ConsumerState<SolNavScreen> {
  bool _loading = true;
  String? _error;
  late final String _url;

  @override
  void initState() {
    super.initState();
    _url = ref.read(backendProvider).fullUrl('/solnav/');
    if (_webViewSupported) _ensureController();
  }

  void _ensureController() {
    if (_controller != null && _loadedUrl == _url) {
      _loading = false;
      return;
    }
    final origin = Uri.parse(_url).origin;
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() { _loading = true; _error = null; });
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = 'Could not load SolNav (${e.description}). '
                    'Is the backend running, and is python_backend/solnav_web present?';
              });
            }
          }
        },
        onNavigationRequest: (req) {
          if (req.url.startsWith(origin) ||
              req.url.startsWith('about:') ||
              req.url.startsWith('data:') ||
              req.url.startsWith('blob:')) {
            return NavigationDecision.navigate;
          }
          launchUrl(Uri.parse(req.url), mode: LaunchMode.externalApplication);
          return NavigationDecision.prevent;
        },
      ))
      ..loadRequest(Uri.parse(_url));
    _loadedUrl = _url;
  }

  void _reload() {
    setState(() { _loading = true; _error = null; });
    _controller?.loadRequest(Uri.parse(_url));
  }

  Future<void> _openInBrowser() =>
      launchUrl(Uri.parse(_url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final compact = c.maxWidth < kCompactContent;
      return Padding(
        padding: EdgeInsets.all(compact ? 8 : pagePad(c.maxWidth)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(compact),
            SizedBox(height: compact ? 8 : 12),
            Expanded(
              child: Container(
                clipBehavior: Clip.hardEdge,
                decoration: BoxDecoration(
                  color: Colors.black,
                  border: Border.all(color: MC.border),
                ),
                child: _body(),
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _toolbar(bool compact) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 16, vertical: 4),
      decoration: BoxDecoration(
        color: MC.panel,
        border: Border.all(color: MC.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        children: [
          const Icon(Icons.public, size: 16, color: MC.accent),
          const SizedBox(width: 10),
          Text(compact ? 'LIVE MARS GLOBE' : 'SOLNAV • LIVE MARS GLOBE',
              style: const TextStyle(
                  fontSize: 11, letterSpacing: 1.5, fontWeight: FontWeight.bold)),
          const SizedBox(width: 12),
          Expanded(
            child: compact
                ? const SizedBox.shrink()
                : Text(_url,
                    style: const TextStyle(color: MC.textDim, fontSize: 10),
                    overflow: TextOverflow.ellipsis),
          ),
          if (compact) const Spacer(),
          if (_loading && _webViewSupported)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: MC.accent)),
            ),
          if (_webViewSupported)
            IconButton(
              tooltip: 'Reload',
              visualDensity: VisualDensity.compact,
              onPressed: _reload,
              icon: const Icon(Icons.refresh, size: 18, color: MC.textDim),
            ),
          IconButton(
            tooltip: 'Open in browser',
            visualDensity: VisualDensity.compact,
            onPressed: _openInBrowser,
            icon: const Icon(Icons.open_in_new, size: 18, color: MC.textDim),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (!_webViewSupported) return _fallback();
    if (_error != null) return _errorView(_error!);
    return WebViewWidget(controller: _controller!);
  }

  Widget _errorView(String msg) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: MC.bad, size: 40),
              const SizedBox(height: 12),
              Text(msg,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: MC.bad, fontSize: 12)),
              const SizedBox(height: 16),
              McButton(
                  label: 'RETRY',
                  icon: Icons.refresh,
                  outlined: true,
                  onPressed: _reload),
            ],
          ),
        ),
      );

  Widget _fallback() => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.public, color: MC.textDim, size: 48),
              const SizedBox(height: 12),
              const Text('SolNav opens in your browser on this platform.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: MC.text, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('An embedded view is not available here.',
                  style: TextStyle(color: MC.textDim, fontSize: 11)),
              const SizedBox(height: 16),
              McButton(
                label: 'LAUNCH SOLNAV',
                icon: Icons.open_in_new,
                onPressed: _openInBrowser,
              ),
            ],
          ),
        ),
      );
}
