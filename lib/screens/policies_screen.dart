import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

class PoliciesScreen extends StatelessWidget {
  const PoliciesScreen({super.key});

  static const String _assetPath = 'assets/legal/policies.md';

  Future<String> _loadMarkdown() async {
    return rootBundle.loadString(_assetPath);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Policies')),
      body: FutureBuilder<String>(
        future: _loadMarkdown(),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                'Failed to load policies.\n\n'
                    'Asset: $_assetPath\n\n'
                    'Error: ${snapshot.error}',
              ),
            );
          }

          final md = snapshot.data ?? '';
          return Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(
              child: MarkdownBody(
                data: md,
                selectable: true,
              ),
            ),
          );
        },
      ),
    );
  }
}
