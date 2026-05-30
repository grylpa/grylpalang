/// One chapter / spine item from a parsed EPUB. [title] is best-effort
/// (the chapter's `<h1>`/`<h2>`/`<title>`, falling back to "Chapter N"); [text]
/// is the plain-text body with paragraph boundaries preserved as blank lines.
class BookChapter {
  final String title;
  final String text;
  const BookChapter({required this.title, required this.text});
}
