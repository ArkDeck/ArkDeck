import ArkDeckStorage
import Foundation

/// Builds historical authority bytes through the production decoder. Tests must not use a
/// source-level constructor for an authority that current products are forbidden to create.
func historicalStandingAuthority(
  authorizationID: String,
  mainCommitOID: String,
  authorizationBlobOID: String,
  approvalPRNumber: Int
) throws -> AgentExecutionAuthorityReference {
  let object: [String: Any] = [
    "kind": "standingAuthorization",
    "authorizationId": authorizationID,
    "mainCommitOID": mainCommitOID,
    "authorizationBlobOID": authorizationBlobOID,
    "approvalPRNumber": approvalPRNumber,
  ]
  return try JSONDecoder().decode(
    AgentExecutionAuthorityReference.self,
    from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}

func historicalChatAuthority(
  confirmationDigestSHA256: String,
  planDigestSHA256: String,
  archiveDigestSHA256: String,
  stepSetDigestSHA256: String,
  targetDigestSHA256: String,
  confirmedAt: String
) throws -> AgentExecutionAuthorityReference {
  let object: [String: Any] = [
    "kind": "chatConfirmation",
    "confirmationDigestSHA256": confirmationDigestSHA256,
    "planDigestSHA256": planDigestSHA256,
    "archiveDigestSHA256": archiveDigestSHA256,
    "stepSetDigestSHA256": stepSetDigestSHA256,
    "targetDigestSHA256": targetDigestSHA256,
    "confirmedAt": confirmedAt,
  ]
  return try JSONDecoder().decode(
    AgentExecutionAuthorityReference.self,
    from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
}
