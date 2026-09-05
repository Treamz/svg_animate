import 'dart:typed_data';

/// The part of `dart:io`'s `File` that [SvgAnimateFileLoader] uses, for the web,
/// which has no `dart:io` to take it from.
///
/// Nothing implements this there, so a file loader cannot be built on the web —
/// which was already true. What it buys is that importing the library no longer
/// drags `dart:io` into a web build, and the package can be analysed as
/// supporting the web at all.
abstract class File {
  /// Where the file is.
  String get path;

  /// The whole of the file, read synchronously.
  Uint8List readAsBytesSync();
}
