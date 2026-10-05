"""Published alias fixture and synthetic assembly regressions; no device evidence."""
import json
from pathlib import Path

from gj_record import catalog
from gj_record.criteria import PASS
from gj_record.test_gj_record import Case, D, OPERATIONS, sha

REPO = Path(__file__).resolve().parents[2]


class CanonicalCatalogTests(Case):
    def alias_catalog(self):
        alias = json.loads((REPO / "Catalog/operations/flash.dayu200.json").read_text(encoding="utf-8"))
        descriptors = [{"id": operation, "version": 1} for operation in OPERATIONS] + [alias]
        body = json.dumps(descriptors, separators=(",", ":"))
        digest = sha(body.encode())
        text = (f'pub const CATALOG_DIGEST: &str = "{digest}";\n'
                f'pub const CATALOG_CANONICAL_JSON: &str = r#"{body}"#;\n')
        self.repo.digest = self.journal.digest = digest
        self.repo.revision = self.repo.commit(text)
        return alias

    def alias_listing(self, alias):
        operations = [{"reference": f"{operation}@1", "canonicalReference": f"{operation}@1",
                       "aliasFor": None, "availability": "available", "reasonCodes": []}
                      for operation in OPERATIONS]
        operations.append({"reference": alias["id"], "canonicalReference": alias["id"],
                           "aliasFor": alias["aliasFor"], "availability": "unavailable",
                           "reasonCodes": ["provider_not_registered"]})
        return operations

    def test_published_catalog_retains_full_digest_but_counts_only_canonical_operations(self):
        text = (REPO / catalog.GENERATED_RUST).read_text(encoding="utf-8")
        digest, operations = catalog.parse_generated(text)
        self.assertEqual(digest, catalog._DIGEST.search(text).group(1))
        self.assertNotIn("flash.dayu200", operations)
        self.assertIn("flash.full-restore@1", operations)
        self.assertEqual(len(operations), 31)
        with self.assertRaisesRegex(catalog.CatalogError, "does not hash"):
            catalog.parse_generated(text.replace("flash.dayu200", "flash.changed-alias"))

    def test_full_assembly_accepts_the_published_alias_without_counting_it_twice(self):
        alias = self.alias_catalog()
        self.journal.facts()
        self.journal.ok("operation.list", ["operation", "list"], self.alias_listing(alias))
        self.journal.gj1()
        document = self.assemble()
        self.assertEqual(self.journey(document)["state"], PASS)
        coverage = document["operationRealDeviceCoverage"]
        self.assertEqual(coverage["canonicalOperationCount"], len(OPERATIONS))
        self.assertNotIn(alias["id"], [row["operationReference"] for row in coverage["operations"]])
        self.assertEqual(document["catalogDigest"], self.repo.digest)

    def test_alias_does_not_replace_a_missing_canonical_operation(self):
        alias = self.alias_catalog()
        self.journal.facts()
        operations = [row for row in self.alias_listing(alias)
                      if row["reference"] != alias["aliasFor"]]
        self.journal.ok("operation.list", ["operation", "list"], operations)
        self.refused("canonical operation set")
