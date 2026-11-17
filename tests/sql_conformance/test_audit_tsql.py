"""Test the T-SQL capture and comparators before a native engine run."""
from datetime import date
import unittest
from unittest.mock import Mock

import pytds

import audit_tsql as audit


def metadata(name, type_code=56):
    return (name, type_code, None, 4, None, None, 0)


class NativeTsqlHarnessTests(unittest.TestCase):
    def setUp(self):
        _, self.setup, cases = audit.manifest_cases()
        self.cases = {case["id"]: case for case in cases}

    def result(self, case, columns, rows):
        return [{"sql": self.cases[case]["statements"][0], "error": None,
                 "results": [{"columns": columns, "rows": rows, "rowcount": len(rows)}]}]

    def test_original_suite_and_batch_are_preserved(self):
        self.assertEqual(len(self.setup), 4)
        self.assertEqual(len(self.cases), 6)
        source = self.cases["TSQL.PROCEDURAL"]["statements"][0]
        self.assertEqual(source, "DECLARE @x INT=1; SELECT @x")
        cursor = Mock(description=(metadata(""),), rowcount=1)
        cursor.fetchall.return_value = [(1,)]
        cursor.nextset.return_value = False
        self.assertTrue(audit.calibrate(self.cases["TSQL.PROCEDURAL"], [audit.observe(cursor, source)]))
        cursor.execute.assert_called_once_with(source)

    def test_ordered_rows_and_duplicate_multiplicity(self):
        top = "TSQL.TOP"
        self.assertFalse(audit.calibrate(self.cases[top], self.result(top, [metadata("id")], [[2], [1]])))
        apply = "TSQL.APPLY"
        columns = [metadata("id"), metadata("v")]
        rows = [[4, 5], [3, 4], [1, 2], [2, 3]]
        self.assertTrue(audit.calibrate(self.cases[apply], self.result(apply, columns, rows)))
        self.assertFalse(audit.calibrate(self.cases[apply], self.result(apply, columns, rows + [rows[0]])))

    def test_date_retains_a_native_type_code(self):
        key = "TSQL.FUNCTIONS"
        rows = [[2, audit.cell(date(2025, 1, 2))]]
        self.assertTrue(audit.calibrate(self.cases[key], self.result(key, [metadata(""), metadata("", 40)], rows)))
        self.assertFalse(audit.calibrate(self.cases[key], self.result(key, [metadata(""), metadata("", 167)], rows)))

    def test_database_error_carries_original_number(self):
        error = pytds.DatabaseError("Invalid SQL")
        error.number, error.severity, error.state, error.line = 102, 15, 1, 2
        cursor = Mock()
        cursor.execute.side_effect = error
        key = "TSQL.OUTPUT"
        result = audit.observe(cursor, self.cases[key]["statements"][0])
        self.assertEqual(result["error"], {"number": 102, "severity": 15, "state": 1, "line": 2, "message": "Invalid SQL"})
        self.assertFalse(audit.calibrate(self.cases[key], [result]))


if __name__ == "__main__":
    unittest.main()
