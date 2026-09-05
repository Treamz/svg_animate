/// `dart:io`'s `File` where the platform has one, and a stand-in where it does
/// not.
///
/// `dart:io` cannot be compiled into a web build, and importing it anywhere in
/// the library is enough for the whole package to be analysed as not supporting
/// the web. That is how it came to be published for five platforms while its
/// own README promised six and described what it does on the sixth.
library;

export '_file_io.dart' if (dart.library.js_interop) '_file_none.dart';
