import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:smart_navigator_spb/core/constants/app_colors.dart';
import 'package:smart_navigator_spb/data/models/assistant_model.dart';
import 'package:smart_navigator_spb/providers/assistant_provider.dart';
import 'package:smart_navigator_spb/services/assistant/assistant_model_roles.dart';
import 'package:smart_navigator_spb/ui/widgets/assistant_markdown.dart';

/// Built-in assistant conversation. It never speaks, reads GPS or builds a
/// route; place cards and Smart Walk are explicit user actions. The first
/// opening asks only for consent, never for a code or an account.
class AssistantSheet extends StatefulWidget {
  const AssistantSheet({
    super.key,
    this.onOpenPlace,
    this.onOpenSmartWalk,
    this.initialQuestion,
    this.initialPlaceId,
  });

  final Future<void> Function(AssistantPlaceReference place)? onOpenPlace;
  final VoidCallback? onOpenSmartWalk;

  /// One question sent automatically after the sheet opens and consent is
  /// already present. It is never sent from [build] and never repeated.
  final String? initialQuestion;

  /// Expected place context for [initialQuestion]. If the provider switches
  /// to another place before dispatch, the pending question is dropped.
  final int? initialPlaceId;

  @override
  State<AssistantSheet> createState() => _AssistantSheetState();
}

class _AssistantSheetState extends State<AssistantSheet> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  bool _consent = false;
  String _lastConversationKey = '';
  bool _initialQuestionHandled = false;
  bool _initialQuestionCheckScheduled = false;
  bool _autoRequestActive = false;
  AssistantProvider? _autoRequestProvider;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onInputChanged);
    _scheduleInitialQuestionCheck();
  }

  void _onInputChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _initialQuestionHandled = true;
    if (_autoRequestActive) {
      // Closing the sheet must not leave an automatic request spending quota
      // in the background. Manual requests keep their existing behaviour.
      _autoRequestProvider?.cancel();
      _autoRequestActive = false;
      _autoRequestProvider = null;
    }
    _input.removeListener(_onInputChanged);
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _scheduleScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _acceptConsent(AssistantProvider provider) async {
    await provider.acceptConsent();
    if (!mounted) return;
    setState(() {});
    _scheduleInitialQuestionCheck();
  }

  void _scheduleInitialQuestionCheck() {
    if (_initialQuestionHandled || _initialQuestionCheckScheduled || !mounted) {
      return;
    }
    final question = widget.initialQuestion?.trim();
    if (question == null || question.isEmpty) {
      _initialQuestionHandled = true;
      return;
    }
    _initialQuestionCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialQuestionCheckScheduled = false;
      if (mounted) _maybeSendInitialQuestion();
    });
  }

  void _maybeSendInitialQuestion() {
    if (!mounted || _initialQuestionHandled) return;
    final question = widget.initialQuestion?.trim();
    if (question == null || question.isEmpty) {
      _initialQuestionHandled = true;
      return;
    }
    final provider = context.read<AssistantProvider>();
    final expectedPlaceId = widget.initialPlaceId;
    if (expectedPlaceId != null && provider.placeId != expectedPlaceId) {
      // The context moved to another place before dispatch. Never attach the
      // prepared question to a different conversation.
      _initialQuestionHandled = true;
      return;
    }
    if (provider.consentLoading) return;
    if (!provider.consented) return; // the consent gate is visible
    if (provider.messages.isNotEmpty || provider.isSending) {
      // Reopening an existing conversation must not repeat the start question.
      _initialQuestionHandled = true;
      return;
    }
    if (!provider.canSend(question)) return;
    _initialQuestionHandled = true;
    _autoRequestActive = true;
    _autoRequestProvider = provider;
    unawaited(
      provider.send(question).whenComplete(() {
        _autoRequestActive = false;
        _autoRequestProvider = null;
      }),
    );
  }

  Future<void> _send(AssistantProvider provider) async {
    final text = _input.text.trim();
    if (!provider.canSend(text)) return;
    _input.clear();
    await provider.send(text);
  }

  Future<void> _confirmClear(AssistantProvider provider) async {
    final palette = AppPalette.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Очистить беседу?'),
        content: const Text(
          'История хранится только в памяти этой сессии и будет удалена.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Очистить'),
          ),
        ],
        backgroundColor: palette.surface,
      ),
    );
    if (confirmed == true) provider.clear();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AssistantProvider>();
    final palette = AppPalette.of(context);
    final media = MediaQuery.of(context);
    final insets = media.viewInsets.bottom;
    final height = (media.size.height * 0.94 - insets)
        .clamp(180.0, 900.0)
        .toDouble();
    if (widget.initialQuestion != null &&
        !_initialQuestionHandled &&
        !provider.consentLoading) {
      _scheduleInitialQuestionCheck();
    }
    if (!provider.needsConsent && !provider.consentLoading) {
      final key =
          '${provider.messages.length}:${provider.isSending}:'
          '${provider.provisionalText.length ~/ 120}';
      if (key != _lastConversationKey) {
        _lastConversationKey = key;
        _scheduleScroll();
      }
    }
    return PopScope(
      // Back dismisses the keyboard first; the sheet closes on the next Back.
      canPop: insets == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Padding(
        padding: EdgeInsets.only(bottom: insets),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: height,
            child: Material(
              color: palette.surface,
              clipBehavior: Clip.antiAlias,
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                children: [
                  _grabber(palette),
                  _header(provider, palette),
                  const Divider(height: 1),
                  Expanded(
                    child: provider.consentLoading
                        ? _consentLoading(palette)
                        : provider.needsConsent
                        ? _consentGate(provider, palette)
                        : _conversation(provider, palette),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _grabber(AppPalette palette) => Center(
    child: Container(
      width: 36,
      height: 4,
      margin: const EdgeInsets.only(top: 8, bottom: 8),
      decoration: BoxDecoration(
        color: palette.divider,
        borderRadius: BorderRadius.circular(2),
      ),
    ),
  );

  Widget _header(AssistantProvider provider, AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, color: palette.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'ИИ-помощник',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Спросите о городе и возможностях приложения',
                  style: TextStyle(fontSize: 11, color: palette.textSecondary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (provider.isSending)
            IconButton(
              tooltip: 'Отменить ответ',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
              onPressed: provider.cancel,
              icon: const Icon(Icons.stop_circle_outlined),
            ),
          IconButton(
            tooltip: 'Очистить беседу',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
            onPressed: provider.hasMessages
                ? () => _confirmClear(provider)
                : null,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Закрыть ИИ-помощника',
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 40, minHeight: 48),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _consentLoading(AppPalette palette) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: palette.primary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Проверяем согласие…',
            style: TextStyle(fontSize: 13, color: palette.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _consentGate(AssistantProvider provider, AppPalette palette) {
    final willAsk =
        widget.initialQuestion != null &&
        !_initialQuestionHandled &&
        provider.messages.isEmpty &&
        !provider.isSending &&
        (widget.initialPlaceId == null ||
            provider.placeId == widget.initialPlaceId);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Icon(Icons.privacy_tip_outlined, size: 36, color: palette.primary),
          const SizedBox(height: 8),
          Text(
            'Перед началом',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'ИИ-помощник использует бесплатную модель через OpenRouter. '
            'Ваш вопрос будет отправлен через OpenRouter выбранному поставщику '
            'ИИ-модели.',
            style: TextStyle(
              fontSize: 14,
              height: 1.4,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Бесплатная модель может сохранять запросы и ответы для улучшения '
            'своей работы. Не указывайте личные данные, которые не хотите '
            'передавать стороннему сервису.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          CheckboxListTile(
            value: _consent,
            onChanged: (value) => setState(() => _consent = value ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(
              'Я понимаю и согласен отправить вопрос через OpenRouter.',
              style: TextStyle(fontSize: 13, color: palette.textPrimary),
            ),
          ),
          if (provider.consentPersistenceFailed) ...[
            const SizedBox(height: 4),
            Text(
              'Не удалось сохранить выбор на устройстве. Он действует до '
              'перезапуска приложения.',
              style: TextStyle(fontSize: 12, color: palette.error),
            ),
          ],
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _consent ? () => _acceptConsent(provider) : null,
            icon: const Icon(Icons.check),
            label: Text(
              willAsk
                  ? 'Согласиться и спросить ИИ'
                  : 'Согласиться и продолжить',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Аккаунт, регистрация и код доступа не нужны. Согласие можно '
            'отозвать в настройках; после отзыва новые вопросы не отправляются. '
            'Карта, поиск и навигация работают без ИИ.',
            style: TextStyle(
              fontSize: 11,
              color: palette.textMuted,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }

  Widget _conversation(AssistantProvider provider, AppPalette palette) {
    return Column(
      children: [
        if (provider.placeTitle != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: palette.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Контекст: ${provider.placeTitle}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: palette.textSecondary),
            ),
          ),
        Expanded(
          child: provider.messages.isEmpty && !provider.isSending
              ? _emptyState(provider, palette)
              : _messageList(provider, palette),
        ),
        _inputBar(provider, palette),
      ],
    );
  }

  Widget _emptyState(AssistantProvider provider, AppPalette palette) {
    final examples = [
      'Что посмотреть в Петербурге?',
      if (provider.placeTitle != null) 'Расскажи об этом месте',
      'Помоги выбрать прогулку',
      'Как работает навигатор тишины?',
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.smart_toy_outlined, size: 36, color: palette.primary),
          const SizedBox(height: 8),
          Text(
            'Спросите о Петербурге',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: palette.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Помощник опирается на каталог приложения и проверенные '
            'исторические карточки. Он не знает актуальные часы работы, цены, '
            'погоду или транспорт.',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: palette.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final example in examples)
                ActionChip(
                  label: Text(example),
                  onPressed: () {
                    _input.text = example;
                    _input.selection = TextSelection.collapsed(
                      offset: _input.text.length,
                    );
                    _inputFocus.requestFocus();
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _messageList(AssistantProvider provider, AppPalette palette) {
    final count = provider.messages.length + (provider.isSending ? 1 : 0);
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      itemCount: count,
      itemBuilder: (context, index) {
        if (index >= provider.messages.length) {
          return provider.hasProvisionalText
              ? _streamingBubble(provider, palette)
              : _loadingBubble(palette);
        }
        return _messageBubble(provider.messages[index], palette);
      },
    );
  }

  Widget _streamingBubble(AssistantProvider provider, AppPalette palette) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        liveRegion: true,
        label: 'ИИ отвечает',
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.86,
          ),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: palette.surfaceVariant,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Real SSE fragments, rendered as partial Markdown. Incomplete
              // syntax is tolerated; the confirmed answer replaces it.
              AssistantMarkdown(data: provider.provisionalText),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: palette.primary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'ИИ печатает…',
                    style: TextStyle(fontSize: 11, color: palette.textMuted),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _messageBubble(AssistantMessage message, AppPalette palette) {
    if (message.isCancelled) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Center(
          child: Text(
            message.text,
            style: TextStyle(fontSize: 12, color: palette.textMuted),
          ),
        ),
      );
    }
    final isUser = message.isUser;
    final isError = message.isError;
    final reply = message.reply;
    final background = isUser
        ? palette.primary
        : isError
        ? palette.error.withValues(alpha: 0.10)
        : palette.surfaceVariant;
    final foreground = isUser ? palette.onSolid : palette.textPrimary;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.86,
        ),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(16),
          border: isError
              ? Border.all(color: palette.error.withValues(alpha: 0.35))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.isAssistant)
              AssistantMarkdown(data: message.text)
            else
              Text(
                message.text,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.42,
                  color: isError ? palette.textPrimary : foreground,
                ),
              ),
            if (isError)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      context.read<AssistantProvider>().retryLast(),
                  child: const Text('Повторить'),
                ),
              ),
            if (reply != null) ...[
              // Attached only to the server-confirmed answer of the recognised
              // backup model; provisional text and failures never reach here.
              if (AssistantModelRoles.isBackup(reply.model)) ...[
                const SizedBox(height: 8),
                _backupNotice(palette),
              ],
              if (reply.warnings.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final warning in reply.warnings.take(3))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '• $warning',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.35,
                        color: palette.textMuted,
                      ),
                    ),
                  ),
              ],
              for (final place in reply.places) _placeCard(place, palette),
              if (reply.openSmartWalk) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: widget.onOpenSmartWalk == null
                        ? null
                        : () {
                            Navigator.of(context).pop();
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              widget.onOpenSmartWalk?.call();
                            });
                          },
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.auto_awesome, size: 18),
                        SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Открыть умную прогулку',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// Informational callout under a completed answer of the backup model.
  /// Palette-driven colours keep it readable in both themes; the expanded
  /// text wraps on narrow screens and scales with the system font setting.
  Widget _backupNotice(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: palette.accent.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.accent.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 16, color: palette.accent),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Ответ подготовлен резервной моделью. Некоторые сведения могут '
              'быть менее точными — рекомендуем проверять важные факты.',
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _placeCard(AssistantPlaceReference place, AppPalette palette) {
    final open = widget.onOpenPlace == null
        ? null
        : () {
            Navigator.of(context).pop();
            widget.onOpenPlace?.call(place);
          };
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(place.category.icon, size: 16, color: place.category.color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  place.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          Text(
            place.category.displayName,
            style: TextStyle(fontSize: 10.5, color: palette.textSecondary),
          ),
          if (place.shortDescription.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              place.shortDescription,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: palette.textSecondary,
              ),
            ),
          ],
          if (open != null)
            Semantics(
              button: true,
              label: 'Открыть место: ${place.title}',
              onTap: open,
              excludeSemantics: true,
              child: TextButton.icon(
                onPressed: open,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Открыть место'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _loadingBubble(AppPalette palette) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Semantics(
        liveRegion: true,
        label: 'ИИ отвечает',
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: palette.surfaceVariant,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: palette.primary,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                'ИИ отвечает…',
                style: TextStyle(fontSize: 13, color: palette.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputBar(AssistantProvider provider, AppPalette palette) {
    final canSend = provider.canSend(_input.text);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: palette.surface,
        border: Border(top: BorderSide(color: palette.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _inputFocus,
              minLines: 1,
              maxLines: 3,
              maxLength: 800,
              buildCounter: (
                _, {
                required currentLength,
                required isFocused,
                maxLength,
              }) => null,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(provider),
              decoration: const InputDecoration(
                hintText: 'Ваш вопрос',
                isDense: true,
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            tooltip: 'Отправить вопрос',
            onPressed: canSend ? () => _send(provider) : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}
