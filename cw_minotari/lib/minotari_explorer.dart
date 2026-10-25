/// Link to a mined XTM block, highlighting its first known payment output.
/// A wallet-local transaction ID is never used as a payment reference.
String? minotariExplorerUrl({
  required int? height,
  required List<String> payrefs,
  bool isTestnet = false,
}) {
  if (height == null || height <= 0) {
    return null;
  }

  final validReference = RegExp(r"^[0-9a-fA-F]{64}$");
  final reference = payrefs.where(validReference.hasMatch).firstOrNull;
  return Uri.https(
    isTestnet ? "explore-esmeralda.tari.com" : "explore.tari.com",
    "/blocks/$height",
    reference == null ? null : {"payref": reference.toLowerCase()},
  ).toString();
}
