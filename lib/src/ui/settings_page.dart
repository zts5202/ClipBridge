import 'package:flutter/material.dart';

import '../bridge_controller.dart';
import '../core/models.dart';
import 'widgets.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});

  final BridgeController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _name;
  late final TextEditingController _limit;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.controller.settings.deviceName);
    _limit = TextEditingController(text: '${widget.controller.settings.maxFileMb}');
  }

  @override
  void dispose() {
    _name.dispose();
    _limit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final settings = controller.settings;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
      children: [
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本机显示名', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(controller: _name, decoration: const InputDecoration(hintText: '给这台设备起个名字')),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => controller.rename(_name.text),
                child: const Text('保存名称'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SoftCard(
          child: Column(
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('自动重连已配对设备'),
                subtitle: const Text('同一局域网再次出现时直接恢复加密会话，无需重新确认'),
                value: settings.autoReconnect,
                onChanged: (value) => controller.updateSettings(settings.copyWith(autoReconnect: value)),
              ),
              if (controller.kind == DeviceKind.pc)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('自动同步复制的内容'),
                  subtitle: const Text('电脑复制文字或图片后，自动发给已连接的手机'),
                  value: settings.autoSyncClipboard,
                  onChanged: (value) =>
                      controller.updateSettings(settings.copyWith(autoSyncClipboard: value)),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('发送前确认'),
                subtitle: const Text('手动发送时先询问。自动同步不受此开关影响'),
                value: settings.confirmBeforeSend,
                onChanged: (value) =>
                    controller.updateSettings(settings.copyWith(confirmBeforeSend: value)),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('暂停同步'),
                subtitle: const Text('保持连接，但不再收发剪贴板和文件'),
                value: settings.paused,
                onChanged: controller.setPaused,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (controller.kind == DeviceKind.pc) ...[
          SoftCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('默认接收方式', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                SegmentedButton<ReceiveMode>(
                  segments: const [
                    ButtonSegment(value: ReceiveMode.clipboard, label: Text('仅剪贴板')),
                    ButtonSegment(value: ReceiveMode.paste, label: Text('自动粘贴')),
                  ],
                  selected: {settings.receiveMode},
                  onSelectionChanged: (value) {
                    controller.updateSettings(settings.copyWith(receiveMode: value.first));
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
        ],
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('单次大小上限（MB）', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _limit,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(hintText: '默认 200'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () {
                  final mb = int.tryParse(_limit.text.trim());
                  if (mb == null) return;
                  controller.updateSettings(
                    settings.copyWith(maxFileBytes: mb * 1024 * 1024),
                  );
                },
                child: const Text('保存上限'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('权限与网络', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '手机需要通知权限，以便前台服务在后台保持局域网连接。图片和文件通过系统选择器读取，不申请整个存储空间。\n\n电脑首次启动若防火墙询问，请允许专用网络。热点场景下，让电脑连接手机打开的热点即可，不必同一台路由器。\n\n访客网络或 AP 隔离会让设备互相看不见。剪贴坞只使用局域网，不会上传到云端。',
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => controller.reveal(controller.inboxDir.path),
                child: const Text('打开接收目录'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
