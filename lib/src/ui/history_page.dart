import 'package:flutter/material.dart';

import '../bridge_controller.dart';
import 'widgets.dart';

class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key, required this.controller});

  final BridgeController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.transfers;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        Row(
          children: [
            Text('传输记录', style: Theme.of(context).textTheme.titleLarge),
            const Spacer(),
            TextButton(
              onPressed: items.isEmpty ? null : controller.clearHistory,
              child: const Text('清除记录'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (items.isEmpty)
          const EmptyHint(
            icon: Icons.history_rounded,
            title: '记录是空的',
            message: '成功、失败和进行中的传输都会出现在这里。清除记录不会删除已经保存的文件。',
          )
        else
          ...items.map(
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
