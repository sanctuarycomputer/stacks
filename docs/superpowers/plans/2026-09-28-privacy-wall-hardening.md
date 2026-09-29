# Privacy wall hardening — plan

Spec: `docs/superpowers/specs/2026-09-28-privacy-wall-hardening-design.md`. TDD: each step writes the failing test first.

1. **Classifier move + lexicon (G1a).** `lib/stacks/etl/classifier.rb` (`Stacks::Etl::Classifier.call`, `.title_exclusion`);
   delete `meet/classifier.rb`; move test to `test/lib/stacks/etl/classifier_test.rb` with one case per new term and
   negative cases ("Design feedback", "fundraise" substring, "design comps", "Quarterly review").
2. **Enum reasons.** `sensitive_content: 9, unreviewed: 10, attendance_unknown: 11` on `Document.excluded_reason`.
3. **Default-deny base (G3).** `Connector#exclusion_for(normalized, doc)` raises; `apply_exclusion` passes `doc`;
   ingest preserves `raw_metadata["privacy_review"]`. Test: every `Connector` subclass overrides it; FakeConnector updated.
4. **Groups policy.** `Groups::Connector#exclusion_for` = title rules, else eligible. Test.
5. **Meet connector (G2 + inheritance).** `deterministic_exclusion(normalized)`: notes → strictest joined transcript
   (human states mapped) else title reason else `attendance_unknown`; transcripts → invite-count rule. Stamps `privacy_inputs`.
   `exclusion_for` = deterministic, then `ContentReview` for eligible transcripts. Update connector tests.
6. **ContentReview (G1b).** `lib/stacks/etl/content_review.rb`: windows, memo by content hash, fail-closed. Tests stub `Stacks::AI`.
7. **Read paths (G4).** get_document segments only for `meet?`; Reindexer `meet?` only; admin exclude cascades to meeting siblings;
   `test/integration/privacy_wall_test.rb`: tripwire over `app/services/mcp/*.rb` + canary tests across search/list/get/weekly-ship tools.
8. **Reclassifier + rake.** `lib/stacks/etl/reclassifier.rb` (order meet → notes → groups; dry-run = deterministic only),
   `stacks:etl:reclassify_privacy[dry_run]`, add to `sync_all`. Tests.
9. Full `bin/rails test`, adversarial review pass (subagent), PR.
