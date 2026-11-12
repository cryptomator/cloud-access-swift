import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from retry_log import retry_lines


class RetryLinesTests(unittest.TestCase):
    def test_retry_of_test_runner_is_listed(self):
        log = "[integration-retry] deleteFile(backend:) pcloud-vf8 attempt 1: noInternetConnection\n"
        self.assertEqual(["- pass1: `deleteFile(backend:)` `pcloud-vf8` attempt 1: noInternetConnection"], retry_lines(log, "pass1"))

    def test_message_ends_at_backslash_and_double_quote(self):
        log = '"[integration-retry] moveFile(backend:) s3-vf6 attempt 1: itemNotFound\\n[integration-retry] multipartUpload() s3 attempt 2: consistencyTimeout","kind"'
        self.assertEqual([
            "- pass2: `moveFile(backend:)` `s3-vf6` attempt 1: itemNotFound",
            "- pass2: `multipartUpload()` `s3` attempt 2: consistencyTimeout",
        ], retry_lines(log, "pass2"))

    def test_repeated_retry_is_listed_once(self):
        log = "[integration-retry] deleteFile(backend:) pcloud-vf8 attempt 1: unauthorized\n" * 2
        self.assertEqual(["- pass1: `deleteFile(backend:)` `pcloud-vf8` attempt 1: unauthorized"], retry_lines(log, "pass1"))

    def test_line_without_marker_is_not_listed(self):
        self.assertEqual([], retry_lines("deleteFile(backend:) pcloud-vf8 attempt 1: unauthorized\n", "pass1"))

    def test_retry_without_message_is_listed(self):
        log = '[integration-retry] deleteFile(backend:) pcloud-vf8 attempt 1: "\n'
        self.assertEqual(["- pass1: `deleteFile(backend:)` `pcloud-vf8` attempt 1: no failure message"], retry_lines(log, "pass1"))


if __name__ == "__main__":
    unittest.main()
