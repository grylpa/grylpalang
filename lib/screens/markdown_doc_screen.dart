import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

/// Renders a bundled Markdown asset in a scrollable, selectable page. Used for
/// in-app docs (e.g. the sentence-bank format guide).
class MarkdownDocScreen extends StatelessWidget {
  const MarkdownDocScreen({super.key, required this.title, required this.assetPath});

  final String title;
  final String assetPath;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(assetPath),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText('Failed to load $assetPath\n\n${snapshot.error}'),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(16),
            child: SingleChildScrollView(child: MarkdownBody(data: snapshot.data ?? '', selectable: true)),
          );
        },
      ),
    );
  }
}
