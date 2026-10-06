import 'package:flutter/material.dart';

import '../bridge_controller.dart';
import '../core/models.dart';
import 'widgets.dart';

class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key, required this.controller});

  final BridgeController controller;

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _host = TextEditingController();

  @override
  void dispose() {
    _host.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final discovered = controller.discovered;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(controller.settings.deviceName, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text('本机是${controller.kind.label} · 指纹 ${formatFingerprint(controller.fingerprint)}'),
              const SizedBox(height: 4),
              Text(
                controller.localAddresses.isEmpty
                    ? '尚未获得局域网 IPv4 地址'
                    : '本机地址 ${controller.localAddresses.join('、')} · 端口 ${controller.tcpPort}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Text('附近设备', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (discovered.isEmpty)
          const EmptyHint(
            icon: Icons.wifi_find_rounded,
            title: '还没有发现设备',
            message: '请让手机和电脑处于同一 Wi-Fi、手机热点，或用 USB 网络共享。USB 共享时电脑会主动寻找手机并连出。两端都要打开 ClipBridge。若仍看不到，检查 Windows 是否允许 ClipBridge 通过公用网络防火墙，或直接输入对方 IP。',
          )
        else
          ...discovered.map((peer) {
            final trusted = controller.trusted.any((item) => item.id == peer.id);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SoftCard(
                child: Row(
                  children: [
                    Icon(peer.kind == DeviceKind.phone ? Icons.smartphone_rounded : Icons.computer_rounded),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(peer.name, style: Theme.of(context).textTheme.titleMedium),
                          Text('${peer.kind.label} · ${trusted ? '已配对' : '新设备'} · ${peer.host}'),
                          Text(
                            '指纹 ${formatFingerprint(peer.fingerprint)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    FilledButton(
                      onPressed: () => controller.connectDiscovered(peer),
                      child: Text(trusted ? '连接' : '配对'),
                    ),
                  ],
                ),
              ),
            );
          }),
        const SizedBox(height: 8),
        SoftCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('按地址连接', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _host,
                decoration: const InputDecoration(hintText: '192.168.43.1 或 192.168.1.8:47822'),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => controller.connectManual(_host.text),
                child: const Text('连接此地址'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Text('已配对设备', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (controller.trusted.isEmpty)
          const EmptyHint(
            icon: Icons.link_off_rounded,
            title: '还没有配对记录',
            message: '新设备需要两端同时点同意。配对成功后，可在设置里打开自动重连。',
          )
        else
          ...controller.trusted.map(
            (peer) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: SoftCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(peer.name),
                          Text('${peer.kind.label} · ${formatFingerprint(peer.fingerprint)}'),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () => controller.forgetPeer(peer.id),
                      child: const Text('忘记'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
