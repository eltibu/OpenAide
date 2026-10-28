import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_assistant/features/chat/file_details.dart';

void main() {
  test('sizes, PDFs and the PDF page', () {
    expect(fileSize(512), '512 B');
    expect(fileSize(2048), '2.0 KB');
    expect(fileSize(3 * 1024 * 1024), '3.0 MB');
    expect(isPdf('a.PDF'), isTrue);
    expect(isPdf('a', 'application/pdf'), isTrue);
    expect(isPdf('a.docx'), isFalse);
    expect(pdfPage(), contains('function setZoom'));
  });
}
