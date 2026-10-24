import 'package:flutter/material.dart';
import 'package:smart_navigator_spb/core/config/app_version.dart';
import 'package:smart_navigator_spb/core/constants/app_strings.dart';
import 'package:url_launcher/url_launcher.dart' as url_launcher;

typedef AppVersionLoader = Future<String?> Function();
typedef ExternalUrlLauncher = Future<bool> Function(Uri url);

/// Single authorship/version block. The version comes from the installed
/// package metadata; when it is unavailable the line is omitted rather than
/// hard-coded or invented.
///
/// P3: the block also links to the official website and the public GitHub
/// repository. The links open ONLY on an explicit tap, in the external
/// browser, as bare URLs without tokens, identifiers or any user data. A
/// failed/missing handler is reported by a SnackBar, never an exception, and
/// a launch already in flight swallows rapid re-taps.
class AboutAppSection extends StatefulWidget {
  const AboutAppSection({
    super.key,
    this.loadVersion = readInstalledAppVersion,
    this.launchUrl = launchExternalUrl,
  });

  final AppVersionLoader loadVersion;

  /// Injection point for tests and hosts without a browser.
  final ExternalUrlLauncher launchUrl;

  static Future<bool> launchExternalUrl(Uri url) {
    return url_launcher.launchUrl(url, mode: url_launcher.LaunchMode.externalApplication);
  }

  @override
  State<AboutAppSection> createState() => _AboutAppSectionState();
}

class _AboutAppSectionState extends State<AboutAppSection> {
  late final Future<String?> _version = widget.loadVersion();
  bool _opening = false;

  Future<void> _open(String url) async {
    if (_opening) return;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.isScheme('https')) {
      _showError();
      return;
    }
    _opening = true;
    var opened = false;
    try {
      opened = await widget.launchUrl(uri);
    } catch (_) {
      opened = false;
    } finally {
      _opening = false;
    }
    if (!opened && mounted) _showError();
  }

  void _showError() {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text(
          'Не удалось открыть ссылку. Проверьте браузер и повторите попытку',
        ),
      ),
    );
  }

  Widget _linkRow({
    required String title,
    required String subtitle,
    required IconData icon,
    required String semanticsLabel,
    required String url,
  }) {
    final theme = Theme.of(context);
    return Semantics(
      link: true,
      button: true,
      label: semanticsLabel,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => _open(url),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.open_in_new,
                size: 16,
                color: theme.textTheme.bodySmall?.color,
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('О приложении', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppStrings.appTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                const Text(AppStrings.appCreator),
                const SizedBox(height: 4),
                const Text(AppStrings.appTagline),
                FutureBuilder<String?>(
                  future: _version,
                  builder: (context, snapshot) {
                    final version = snapshot.data;
                    if (version == null || version.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'Версия $version',
                        style: theme.textTheme.bodySmall,
                      ),
                    );
                  },
                ),
                const Divider(height: 24),
                _linkRow(
                  title: 'Официальный сайт',
                  subtitle: 'spb-in-details.vercel.app',
                  icon: Icons.language,
                  semanticsLabel:
                      'Официальный сайт «Петербург в деталях», открывается '
                      'во внешнем браузере',
                  url: AppStrings.officialWebsiteUrl,
                ),
                _linkRow(
                  title: 'GitHub проекта',
                  subtitle: 'Исходный код и публичные выпуски',
                  icon: Icons.code,
                  semanticsLabel:
                      'GitHub проекта «Петербург в деталях», открывается во '
                      'внешнем браузере',
                  url: AppStrings.projectGithubUrl,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
