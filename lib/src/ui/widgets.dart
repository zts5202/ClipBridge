import 'package:flutter/material.dart';

import '../core/models.dart';

class SoftCard extends StatelessWidget {
  const SoftCard({super.key, required this.child, this.padding = const EdgeInsets.all(18)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.45)),
        boxShadow: [
          BoxShadow(
            color: scheme.shadow.withValues(alpha: 0.05),
            blurRadius: 24,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class StatusBanner extends StatelessWidget {
  const StatusBanner({
    super.key,
    required this.label,
    required this.phase,
    this.peerName,
    this.detail,
  });

  final String label;
  final LinkPhase phase;
  final String? peerName;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (phase) {
      LinkPhase.ready => const Color(0xFF0F766E),
      LinkPhase.error => scheme.error,
      LinkPhase.pairing || LinkPhase.connecting => const Color(0xFFB45309),
      _ => scheme.primary,
    };
    return SoftCard(
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Icon(Icons.swap_horiz_rounded, color: color, size: 28),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleLarge),
                if (peerName != null)
                  Text('对端：$peerName', style: Theme.of(context).textTheme.bodyMedium),
                if (detail != null && detail!.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(detail!, style: Theme.of(context).textTheme.bodySmall),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return SoftCard(
      child: Column(
        children: [
          Icon(icon, size: 36, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 10),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          if (action != null) ...[const SizedBox(height: 12), action!],
        ],
      ),
    );
  }
}

class TransferTile extends StatelessWidget {
  const TransferTile({super.key, required this.record, this.onRetry, this.onOpen});

  final TransferRecord record;
  final VoidCallback? onRetry;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final icon = switch (record.kind) {
      PayloadKind.text => Icons.notes_rounded,
      PayloadKind.image => Icons.image_outlined,
      PayloadKind.file => Icons.insert_drive_file_outlined,
    };
    final direction = record.direction == TransferDirection.outgoing ? '发出' : '收到';
    final status = switch (record.status) {
      TransferStatus.active => '传输中',
      TransferStatus.success => '成功',
      TransferStatus.failed => '失败',
    };
    final scheme = Theme.of(context).colorScheme;
    final openPath = record.publishedUri ?? record.savedPath;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SoftCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(record.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      Text(
                        '$direction · ${record.kind == PayloadKind.text ? '文字' : record.kind == PayloadKind.image ? '图片' : '文件'} · $status · ${formatTime(record.createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (record.canRetry && onRetry != null)
                  TextButton(onPressed: onRetry, child: const Text('重试')),
                if (openPath != null && onOpen != null)
                  TextButton(onPressed: onOpen, child: const Text('打开')),
              ],
            ),
            if (record.status == TransferStatus.active) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: record.progress == 0 ? null : record.progress),
            ],
            if (record.error != null && record.error!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  record.error!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: record.status == TransferStatus.failed ? scheme.error : scheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
