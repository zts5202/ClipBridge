import 'package:flutter/material.dart';

import '../../bridge_controller.dart';
import '../../core/models.dart';
import 'dock_theme.dart';

class DockStrip extends StatelessWidget {
  const DockStrip({
    super.key,
    required this.connected,
    required this.transferring,
    required this.hint,
    required this.onTap,
    this.onDragUpdate,
  });

  final bool connected;
  final bool transferring;
  final String? hint;
  final VoidCallback onTap;
  final GestureDragUpdateCallback? onDragUpdate;

  @override
  Widget build(BuildContext context) {
    final color = transferring ? dockBlue : (connected ? dockGreen : dockGray);
    return GestureDetector(
      onTap: onTap,
      onVerticalDragUpdate: onDragUpdate,
      child: SizedBox(
        width: 22,
        height: hint == null ? 88 : 120,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: dockSurface(Theme.of(context).brightness),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                key: const Key('dock-dot'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              if (hint != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Text(
                    hint!,
                    key: const Key('dock-hint'),
                    maxLines: 4,
                    textAlign: TextAlign.center,
                    style: dockFace(
                      fontSize: 9,
                      height: 1.15,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class DockHome extends StatelessWidget {
  const DockHome({
    super.key,
    required this.controller,
    required this.onOpenSettings,
    required this.onDragUpdate,
    this.onTyping,
  });

  final BridgeController controller;
  final VoidCallback onOpenSettings;
  final GestureDragUpdateCallback onDragUpdate;
  final ValueChanged<bool>? onTyping;

  @override
  Widget build(BuildContext context) {
    final connected = controller.phase == LinkPhase.ready && controller.peerName != null;
    final recent = controller.transfers.take(5).toList();
    final unpaired = controller.trusted.isEmpty && !connected;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GestureDetector(
          onVerticalDragUpdate: onDragUpdate,
          child: Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: controller.isTransferring
                      ? dockBlue
                      : connected
                      ? dockGreen
                      : dockGray,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  connected ? '已连接 · ${controller.peerName}' : '未连接',
                  key: const Key('dock-status'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: dockFace(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              IconButton(
                key: const Key('dock-gear'),
                tooltip: '设置',
                visualDensity: VisualDensity.compact,
                onPressed: onOpenSettings,
                icon: const Icon(Icons.settings_rounded, size: 18),
              ),
            ],
          ),
        ),
        if (controller.detail != null && controller.detail!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(controller.detail!, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (!connected)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('dock-rescan'),
              onPressed: controller.bumpDiscovery,
              child: const Text('重新搜索'),
            ),
          ),
        if (connected)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: controller.disconnect,
              child: const Text('断开'),
            ),
          ),
        if (unpaired)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              '在手机上打开 ClipBridge，确认配对',
              key: const Key('unpaired-guide'),
              style: dockFace(fontSize: 13, height: 1.35, color: scheme.onSurface),
            ),
          ),
        Text('接收方式', style: dockFace(fontSize: 12, color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        _PillChoice<ReceiveMode>(
          selected: controller.settings.receiveMode,
          options: const [
            (value: ReceiveMode.clipboard, label: '仅剪贴板', key: Key('mode-clipboard')),
            (value: ReceiveMode.paste, label: '自动粘贴', key: Key('mode-paste')),
          ],
          onChanged: (value) {
            controller.updateSettings(controller.settings.copyWith(receiveMode: value));
          },
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: FilledButton(
                key: const Key('send-clipboard'),
                onPressed: controller.sendClipboard,
                child: const Text('发送当前剪贴板'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                key: const Key('send-file'),
                onPressed: controller.pickAndSendFile,
                child: const Text('发送文件'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: controller.pickAndSendImage,
                child: const Text('图片'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _sendTyped(context),
                child: const Text('发送文字'),
              ),
            ),
          ],
        ),
        if (controller.pendingShare != null) ...[
          const SizedBox(height: 8),
          Text(controller.pendingShare!.name ?? controller.pendingShare!.text ?? '待发送的分享'),
          Row(
            children: [
              TextButton(onPressed: controller.sendPendingShare, child: const Text('发送')),
              TextButton(onPressed: controller.dismissPendingShare, child: const Text('忽略')),
            ],
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Text('最近', style: dockFace(fontSize: 12, color: scheme.onSurfaceVariant)),
            const Spacer(),
            if (controller.transfers.isNotEmpty)
              TextButton(
                onPressed: controller.clearHistory,
                child: const Text('清除记录'),
              ),
          ],
        ),
        if (recent.isEmpty)
          Text('还没有传输记录', style: dockFace(fontSize: 13, color: scheme.onSurface))
        else
          ...recent.map((record) => _RecordRow(controller: controller, record: record)),
        if (controller.discovered.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('附近设备', style: dockFace(fontSize: 12, color: scheme.onSurfaceVariant)),
          ...controller.discovered.map((peer) {
            final trusted = controller.trusted.any((item) => item.id == peer.id);
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(peer.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${peer.host}:${peer.tcpPort}'),
              trailing: TextButton(
                onPressed: () => controller.connectDiscovered(peer),
                child: Text(trusted ? '连接' : '配对'),
              ),
            );
          }),
        ],
      ],
    );
  }

  Future<void> _sendTyped(BuildContext context) async {
    final text = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('发送文字'),
        content: TextField(
          controller: text,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          onTap: () => onTyping?.call(true),
          decoration: const InputDecoration(hintText: '要发送的文字'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(context, text.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    onTyping?.call(false);
    if (value != null && value.trim().isNotEmpty) {
      await controller.sendText(value);
    }
  }
}

class _RecordRow extends StatelessWidget {
  const _RecordRow({required this.controller, required this.record});

  final BridgeController controller;
  final TransferRecord record;

  @override
  Widget build(BuildContext context) {
    final icon = switch (record.kind) {
      PayloadKind.text => Icons.notes_rounded,
      PayloadKind.image => Icons.image_outlined,
      PayloadKind.file => Icons.insert_drive_file_outlined,
    };
    final direction = record.direction == TransferDirection.outgoing ? '发出' : '收到';
    final kind = switch (record.kind) {
      PayloadKind.text => '文字',
      PayloadKind.image => '图片',
      PayloadKind.file => '文件',
    };
    final path = record.publishedUri ?? record.savedPath;
    return InkWell(
      key: Key('recent-${record.id}'),
      onTap: () {
        if (record.kind == PayloadKind.text && record.textBody != null && record.textBody!.isNotEmpty) {
          controller.copyText(record.textBody!);
          return;
        }
        if (path != null) controller.reveal(path);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    record.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: dockFace(color: Theme.of(context).colorScheme.onSurface),
                  ),
                  Text(
                    '$direction · $kind · ${formatTime(record.createdAt)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            if (record.canRetry)
              TextButton(
                onPressed: () => controller.retry(record.id),
                child: const Text('重试'),
              ),
          ],
        ),
      ),
    );
  }
}

class DockSettingsPage extends StatefulWidget {
  const DockSettingsPage({
    super.key,
    required this.controller,
    required this.onClose,
    this.onTyping,
  });

  final BridgeController controller;
  final VoidCallback onClose;
  final ValueChanged<bool>? onTyping;

  @override
  State<DockSettingsPage> createState() => _DockSettingsPageState();
}

class _DockSettingsPageState extends State<DockSettingsPage> {
  late final TextEditingController _name;
  late final TextEditingController _limit;
  late final TextEditingController _host;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.controller.settings.deviceName);
    _limit = TextEditingController(text: '${widget.controller.settings.maxFileMb}');
    _host = TextEditingController();
  }

  @override
  void dispose() {
    _name.dispose();
    _limit.dispose();
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final settings = controller.settings;
    return Column(
      key: const Key('dock-settings'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '设置',
                style: dockFace(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            IconButton(
              tooltip: '返回',
              visualDensity: VisualDensity.compact,
              onPressed: widget.onClose,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ],
        ),
        Text('本机 ${controller.kind.label} · ${formatFingerprint(controller.fingerprint)}'),
        Text(
          controller.localAddresses.isEmpty
              ? '尚未获得局域网地址'
              : '本机地址 ${controller.localAddresses.join('、')} · ${controller.tcpPort}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          decoration: const InputDecoration(hintText: '本机名称'),
          onTap: () => widget.onTyping?.call(true),
          onEditingComplete: () => widget.onTyping?.call(false),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              widget.onTyping?.call(false);
              controller.rename(_name.text);
            },
            child: const Text('保存名称'),
          ),
        ),
        Text('已配对设备', style: Theme.of(context).textTheme.labelLarge),
        if (controller.trusted.isEmpty)
          const Text('还没有配对记录')
        else
          ...controller.trusted.map(
            (peer) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(peer.name),
              subtitle: Text(formatFingerprint(peer.fingerprint)),
              trailing: TextButton(
                onPressed: () => controller.forgetPeer(peer.id),
                child: const Text('忘记'),
              ),
            ),
          ),
        const SizedBox(height: 6),
        TextField(
          controller: _host,
          decoration: const InputDecoration(hintText: '192.168.1.8 或 192.168.42.129:47822'),
          onTap: () => widget.onTyping?.call(true),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              widget.onTyping?.call(false);
              controller.connectManual(_host.text);
            },
            child: const Text('连接此地址'),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动重连'),
          value: settings.autoReconnect,
          onChanged: (value) => controller.updateSettings(settings.copyWith(autoReconnect: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动同步复制的内容'),
          value: settings.autoSyncClipboard,
          onChanged: (value) =>
              controller.updateSettings(settings.copyWith(autoSyncClipboard: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('发送前确认'),
          value: settings.confirmBeforeSend,
          onChanged: (value) =>
              controller.updateSettings(settings.copyWith(confirmBeforeSend: value)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('暂停同步'),
          value: settings.paused,
          onChanged: controller.setPaused,
        ),
        const SizedBox(height: 4),
        Text('单次大小上限（MB）', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        TextField(
          key: const Key('file-limit'),
          controller: _limit,
          keyboardType: TextInputType.number,
          onTap: () => widget.onTyping?.call(true),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              widget.onTyping?.call(false);
              final mb = int.tryParse(_limit.text.trim());
              if (mb == null) return;
              controller.updateSettings(settings.copyWith(maxFileBytes: mb * 1024 * 1024));
            },
            child: const Text('保存上限'),
          ),
        ),
        Text('贴边位置', style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: 6),
        _PillChoice<String>(
          key: const Key('dock-edge'),
          selected: settings.dockEdge == 'left' ? 'left' : 'right',
          options: const [
            (value: 'left', label: '左侧', key: Key('edge-left')),
            (value: 'right', label: '右侧', key: Key('edge-right')),
          ],
          onChanged: (value) {
            controller.updateSettings(settings.copyWith(dockEdge: value));
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('开机自启'),
          value: settings.launchAtStartup,
          onChanged: (value) =>
              controller.updateSettings(settings.copyWith(launchAtStartup: value)),
        ),
        SwitchListTile(
          key: const Key('notification-sound'),
          contentPadding: EdgeInsets.zero,
          title: const Text('提示音'),
          value: settings.notificationSound,
          onChanged: (value) =>
              controller.updateSettings(settings.copyWith(notificationSound: value)),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => controller.reveal(controller.inboxDir.path),
            child: const Text('打开接收目录'),
          ),
        ),
      ],
    );
  }
}

class _PillChoice<T> extends StatelessWidget {
  const _PillChoice({
    super.key,
    required this.selected,
    required this.options,
    required this.onChanged,
  });

  final T selected;
  final List<({T value, String label, Key key})> options;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            for (final option in options)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(1),
                  child: Material(
                    color: option.value == selected ? dockBlue : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    child: InkWell(
                      key: option.key,
                      borderRadius: BorderRadius.circular(8),
                      onTap: () => onChanged(option.value),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          option.label,
                          textAlign: TextAlign.center,
                          style: dockFace(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: option.value == selected
                                ? Colors.white
                                : Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class PairCard extends StatelessWidget {
  const PairCard({
    super.key,
    required this.prompt,
    required this.secondsLeft,
    required this.onAccept,
    required this.onReject,
  });

  final PairPrompt prompt;
  final int secondsLeft;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      key: const Key('pair-card'),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dockBlue.withValues(alpha: 0.4)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确认新设备', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('${prompt.name}（${prompt.kind.label}）请求配对'),
            Text('指纹 ${formatFingerprint(prompt.fingerprint)}'),
            Text(
              prompt.sas,
              style: dockFace(
                fontSize: 28,
                fontWeight: FontWeight.w700,
                letterSpacing: 4,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
            Text('请与另一台设备核对。$secondsLeft 秒后自动拒绝。'),
            Row(
              children: [
                TextButton(onPressed: onReject, child: const Text('拒绝')),
                FilledButton(onPressed: onAccept, child: const Text('同意')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
