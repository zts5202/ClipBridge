import 'package:flutter/material.dart';

import '../bridge_controller.dart';
import '../core/models.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.controller, required this.onOpenDevices});

  final BridgeController controller;
  final VoidCallback onOpenDevices;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final recent = controller.transfers.take(5).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        StatusBanner(
          label: controller.phaseLabel,
          phase: controller.phase,
          peerName: controller.peerName,
          detail: controller.detail,
        ),
        const SizedBox(height: 14),
        if (controller.kind == DeviceKind.pc) ...[
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('电脑接收方式', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<ReceiveMode>(
                  segments: const [
                    ButtonSegment(
                      value: ReceiveMode.clipboard,
                      label: Text('仅剪贴板'),
                      icon: Icon(Icons.content_paste_rounded),
                    ),
                    ButtonSegment(
                      value: ReceiveMode.paste,
                      label: Text('剪贴板并自动粘贴'),
                      icon: Icon(Icons.keyboard_rounded),
                    ),
                  ],
                  selected: {controller.settings.receiveMode},
                  onSelectionChanged: (value) {
                    controller.updateSettings(
                      controller.settings.copyWith(receiveMode: value.first),
                    );
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  controller.settings.receiveMode == ReceiveMode.paste
                      ? '收到文字或图片后写入剪贴板，并向前台窗口发送 Ctrl+V。失败时只保留剪贴板并通知。'
                      : '收到文字或图片后只写入剪贴板，由你自己 Ctrl+V。文件始终保存到下载目录。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('发送到${controller.peerName ?? '已连接设备'}', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              TextField(
                controller: _text,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(hintText: '输入或粘贴要发送的文字'),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () async {
                      final value = _text.text;
                      if (value.trim().isEmpty) return;
                      await controller.sendText(value);
                      if (mounted) _text.clear();
                    },
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('发送文字'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.pickAndSendImage,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('图片'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.pickAndSendFile,
                    icon: const Icon(Icons.attach_file_rounded),
                    label: const Text('文件'),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.sendClipboard,
                    icon: const Icon(Icons.content_paste_go_rounded),
                    label: const Text('发送剪贴板'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (controller.pendingShare != null) ...[
          const SizedBox(height: 14),
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('有待发送的系统分享'),
                const SizedBox(height: 8),
                Text(controller.pendingShare!.name ?? controller.pendingShare!.text ?? '分享内容'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(onPressed: controller.sendPendingShare, child: const Text('发送')),
                    TextButton(onPressed: controller.dismissPendingShare, child: const Text('忽略')),
                  ],
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          children: [
            Text('最近传输', style: Theme.of(context).textTheme.titleMedium),
            const Spacer(),
            if (!controller.isReady)
              TextButton(onPressed: widget.onOpenDevices, child: const Text('去连接设备')),
          ],
        ),
        const SizedBox(height: 8),
        if (recent.isEmpty)
          const EmptyHint(
            icon: Icons.inbox_outlined,
            title: '还没有传输记录',
            message: '连接后可以从这里发送文字、图片和文件。记录只保存在本机。',
          )
        else
          ...recent.map(
            (record) => TransferTile(
              record: record,
              onRetry: () => controller.retry(record.id),
              onOpen: () {
                final path = record.publishedUri ?? record.savedPath;
                if (path != null) controller.reveal(path);
              },
            ),
          ),
      ],
    );
  }
}
