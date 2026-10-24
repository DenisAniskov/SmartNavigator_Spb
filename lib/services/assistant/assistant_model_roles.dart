/// Client-side classification of the model the backend confirmed in
/// [AssistantReply.model]. The IDs are never shown to users; they only decide
/// whether the backup notice is attached to a completed answer.
///
/// The list is fail-safe by design: a model the client does not recognise
/// (null or a future replacement configured on the backend) is never declared
/// the backup. Until the backend adds an explicit `model_role` field, a new
/// backup ID requires a client release to be flagged here.
abstract final class AssistantModelRoles {
  /// Primary model of the current Railway deployment.
  static const String primary = 'nvidia/nemotron-3-ultra-550b-a55b:free';

  /// Backup model served when the primary is unavailable.
  static const String backup = 'nvidia/nemotron-3.5-lightning:free';

  /// True only for the confirmed backup ID. Null and unknown IDs return
  /// false: without confirmation the client must not claim that an answer
  /// came from the backup model.
  static bool isBackup(String? model) => model == backup;
}
