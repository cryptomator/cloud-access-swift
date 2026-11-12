import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from failure_reason import KNOWN_ERRORS, reason

SENTINEL = "SECRETKEY123"
URL = "https://user:{}@example.com/file?token={}".format(SENTINEL, SENTINEL)
WITHHELD = "details withheld"


class ReasonTests(unittest.TestCase):
    def assert_reason(self, expected, message):
        self.assertEqual(expected, reason(message), message)
        self.assertNotIn(SENTINEL, reason(message), message)

    def test_message_without_text_has_no_reason(self):
        self.assert_reason("", "")
        self.assert_reason("", " \n\t")

    def test_error_is_reduced_to_domain_and_code(self):
        self.assert_reason("NSURLErrorDomain -1001", "Error Domain=NSURLErrorDomain Code=-1001")
        self.assert_reason("NSURLErrorDomain -1001", 'Caught error: Error Domain=NSURLErrorDomain Code=-1001 "The request timed out." UserInfo={{NSErrorFailingURLStringKey={}}}'.format(URL))
        self.assert_reason("com.example.Sub_domain-1 7", "{} failed with Error Domain=com.example.Sub_domain-1 Code=7".format(URL))

    def test_known_error_is_reduced_to_its_case(self):
        for error in sorted(KNOWN_ERRORS):
            self.assert_reason(error, error)
            self.assert_reason(error, "Caught error: " + error)
            self.assert_reason(error, "{}({})".format(error, URL))
            self.assert_reason(error, "Caught error: {}(first line\n{})".format(error, URL))

    def test_unknown_error_is_withheld(self):
        self.assert_reason(WITHHELD, "someOtherError")
        self.assert_reason(WITHHELD, "Caught error: someOtherError({})".format(URL))

    def test_known_error_followed_by_text_is_withheld(self):
        self.assert_reason(WITHHELD, "itemNotFound at {}".format(URL))
        self.assert_reason(WITHHELD, "itemNotFound({}) at {}".format(URL, SENTINEL))

    def test_known_error_that_was_not_thrown_is_kept(self):
        self.assert_reason("Expected itemNotFound, but nothing was thrown", "Expected itemNotFound, but nothing was thrown")
        self.assert_reason(WITHHELD, "Expected someOtherError, but nothing was thrown")
        self.assert_reason(WITHHELD, "Expected {}, but nothing was thrown".format(SENTINEL))

    def test_failed_expectation_is_not_quoted(self):
        self.assert_reason("expectation failed", "Expectation failed: (metadata.name → {}) == name".format(SENTINEL))

    def test_other_text_is_withheld(self):
        self.assert_reason(WITHHELD, URL)
        self.assert_reason(WITHHELD, "The operation couldn't be completed. {}".format(SENTINEL))


if __name__ == "__main__":
    unittest.main()
