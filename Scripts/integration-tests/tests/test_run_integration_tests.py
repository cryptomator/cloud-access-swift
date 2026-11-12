# Runs Scripts/run-integration-tests.sh as a whole, with stubs for xcodebuild and xcrun and hand-written results.

import collections
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(os.path.dirname(TESTS_DIR)), "run-integration-tests.sh")
BUNDLE = "CryptomatorCloudAccessIntegrationTests"
STILL_FAILING = os.path.join("integration-output", "still-failing.txt")

FETCH = "IntegrationTests/Conformance/fetchItemMetadataForFile(backend:)"
DELETE = "IntegrationTests/Conformance/deleteFile(backend:)"
RUNNER = "IntegrationTests/Runner/transientErrorIsRetried()"
VAULT_FORMATS = "IntegrationTests/Runner/vaultBackendUsesTheDecoratorOfItsFormat(format:)"
S3 = "IntegrationTests/ProviderSpecific/S3Tests/multipartUpload()"
RUNNER_ERROR = "The test runner encountered an error"
SENTINEL = "SECRETKEY123"

MAIN_PASS_INCOMPLETE = ":x: The main pass did not complete: {}. Nothing was re-run, and the next attempt runs everything."
RERUN_INCOMPLETE = ":x: The re-run pass did not complete: {}. Its pairs count as still failing."

Result = collections.namedtuple("Result", "exit_code stdout stderr")
Call = collections.namedtuple("Call", "filter arguments")


def failure(text, file=None, line=None):
    node = {"nodeType": "Failure Message", "name": text}
    if file:
        node["sourceLocation"] = {"filePath": file, "lineNumber": line}
    return node


def argument(token, result="Passed", *failures):
    return {"nodeType": "Arguments", "name": token, "result": result, "children": list(failures)}


def test_case(identifier, result="Passed", *children):
    name = identifier.rsplit("/", 1)[-1]
    return {"nodeType": "Test Case", "name": name, "nodeIdentifier": identifier, "result": result, "children": list(children)}


def skipped(identifier):
    """A test that didn't run, which is reported without its arguments."""
    return test_case(identifier, "Skipped", {"nodeType": "Skip Message", "name": "Test skipped"})


def results(*test_cases):
    suite = {"nodeType": "Test Suite", "name": "IntegrationTests", "nodeIdentifier": "IntegrationTests", "result": "Failed", "children": list(test_cases)}
    bundle = {"nodeType": "Unit test bundle", "name": BUNDLE, "result": "Failed", "children": [suite]}
    plan = {"nodeType": "Test Plan", "name": "Test Scheme Action", "result": "Failed", "children": [bundle]}
    return {"devices": [], "testNodes": [plan], "testPlanConfigurations": []}


def only_testing(*identifiers):
    return ["-only-testing:{}/{}".format(BUNDLE, identifier) for identifier in identifiers]


class RunIntegrationTestsScriptTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)
        self.fixtures = os.path.join(self.root, "fixtures")
        self.working_directory = os.path.join(self.root, "work")
        for directory in ("fixtures", "work", "tmp", "bin"):
            os.mkdir(os.path.join(self.root, directory))
        # A link to the interpreter that runs these tests, so that the script runs with it and nothing else from its directory is on the PATH.
        os.symlink(sys.executable, os.path.join(self.root, "bin", "python3"))

    # Fixtures

    def write_pass(self, name, content, exit_code=0, log=None):
        """Writes what the stubs serve for a pass: its test results (a dict, or a string to serve as it is), the exit code of xcodebuild and the action log."""
        with open(os.path.join(self.fixtures, name + ".json"), "w") as file:
            file.write(content if isinstance(content, str) else json.dumps(content))
        with open(os.path.join(self.fixtures, name + ".exit"), "w") as file:
            file.write(str(exit_code))
        if log is not None:
            with open(os.path.join(self.fixtures, name + ".log"), "w") as file:
                file.write(log)

    def write_failed_main_pass(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed")), test_case(DELETE, "Failed", argument("pcloud-plain", "Failed"))), exit_code=65)

    def write_file(self, content):
        path = os.path.join(self.root, "only.txt")
        with open(path, "w") as file:
            file.write(content)
        return path

    def write_still_failing_of_earlier_run(self, content):
        os.mkdir(os.path.join(self.working_directory, "integration-output"))
        with open(os.path.join(self.working_directory, STILL_FAILING), "w") as file:
            file.write(content)

    # Running

    def run_script(self, *arguments, **environment):
        path = [os.path.join(TESTS_DIR, "stubs"), os.path.join(self.root, "bin"), "/usr/bin", "/bin"]
        env = {"PATH": os.pathsep.join(path), "TMPDIR": os.path.join(self.root, "tmp"), "STUB_FIXTURES": self.fixtures}
        env.update(environment)
        process = subprocess.run([SCRIPT] + list(arguments), cwd=self.working_directory, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, timeout=120)
        self.assertFalse(os.path.exists(os.path.join(self.fixtures, "unexpected.log")), "A stub was invoked in an unexpected way")
        return Result(process.returncode, process.stdout, process.stderr)

    def calls(self):
        path = os.path.join(self.fixtures, "calls.log")
        if not os.path.exists(path):
            return []
        calls = []
        with open(path) as file:
            for line in file.read().splitlines():
                if line.startswith("filter="):
                    calls.append(Call(line[len("filter="):], []))
                elif line.startswith("arg="):
                    calls[-1].arguments.append(line[len("arg="):])
        return calls

    def still_failing(self):
        path = os.path.join(self.working_directory, STILL_FAILING)
        if not os.path.exists(path):
            return None
        with open(path) as file:
            return file.read()

    def assert_last_call(self, count, filter, *identifiers):
        """Asserts how often xcodebuild was called, and the filter and the selected tests of its last call."""
        calls = self.calls()
        self.assertEqual(count, len(calls))
        self.assertEqual(filter, calls[-1].filter)
        self.assertEqual(only_testing(*identifiers), [argument for argument in calls[-1].arguments if argument.startswith("-only-testing:")])

    def assert_main_pass_incomplete(self, cause):
        self.write_still_failing_of_earlier_run("stale\tpcloud-plain\n")
        result = self.run_script()
        self.assertEqual(1, result.exit_code)
        self.assertIn(MAIN_PASS_INCOMPLETE.format(cause), result.stdout.splitlines())
        self.assertEqual(1, len(self.calls()))
        self.assertIsNone(self.still_failing())

    def assert_rerun_incomplete(self, cause):
        result = self.run_script()
        self.assertEqual(1, result.exit_code)
        self.assertIn(RERUN_INCOMPLETE.format(cause), result.stdout.splitlines())
        self.assert_last_call(2, "pcloud-plain", FETCH, DELETE)
        self.assertEqual("{}\tpcloud-plain\n{}\tpcloud-plain\n".format(FETCH, DELETE), self.still_failing())

    # Passing and failing pairs

    def test_all_pairs_pass(self):
        self.write_pass("pass1", results(test_case(FETCH, "Passed", argument("pcloud-plain"), argument("pcloud-vf8", "Expected Failure")), skipped(S3)))

        result = self.run_script()

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `pcloud-plain` | 1 | 0 | 0 | 0 |", lines)
        self.assertIn("| `pcloud-vf8` | 1 | 0 | 0 | 0 |", lines)
        self.assertIn("| `s3` | 0 | 0 | 0 | 1 |", lines)
        self.assertNotIn("### Still failing", result.stdout)
        calls = self.calls()
        self.assertEqual(1, len(calls))
        self.assertEqual("", calls[0].filter)
        bundle = os.path.join(os.path.dirname(calls[0].arguments[6]), "pass1.xcresult")
        self.assertEqual(["test-without-building", "-scheme", "CryptomatorCloudAccess-Package", "-destination", "name=iPhone 17", "-resultBundlePath", bundle, "-collect-test-diagnostics", "never", "-only-testing:" + BUNDLE], calls[0].arguments)

    def test_pair_that_passes_on_rerun_is_healed(self):
        self.write_pass("pass1", results(
            test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Caught error: itemNotFound", "/checkout/Tests/Conformance.swift", 12)), argument("pcloud-vf8")),
            test_case(DELETE, "Passed", argument("pcloud-plain")),
        ), exit_code=65)
        # A result of the re-run for a pair that passed in the main pass changes nothing.
        self.write_pass("pass2", results(test_case(FETCH, "Failed", argument("pcloud-plain"), argument("pcloud-vf8", "Failed"))), exit_code=65)

        result = self.run_script(BACKENDS="pcloud")

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `pcloud-plain` | 1 | 0 | 1 | 0 |", lines)
        self.assertIn("| `pcloud-vf8` | 1 | 0 | 0 | 0 |", lines)
        self.assertIn("### Passed only on re-run", lines)
        self.assertIn("- `{}` `pcloud-plain`: itemNotFound (Conformance.swift:12)".format(FETCH), lines)
        self.assertNotIn("### Still failing", lines)
        self.assertEqual("pcloud", self.calls()[0].filter)
        self.assert_last_call(2, "pcloud-plain", FETCH)

    def test_pair_that_fails_again_stays_failing(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Expectation failed: a == b", "/checkout/Tests/Conformance.swift", 12)))), exit_code=65)
        self.write_pass("pass2", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Caught error: unauthorized")))), exit_code=65)

        result = self.run_script()

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\tpcloud-plain\n".format(FETCH), self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `pcloud-plain` | 0 | 1 | 0 | 0 |", lines)
        self.assertIn("### Still failing", lines)
        self.assertIn("- `{}` `pcloud-plain`: unauthorized".format(FETCH), lines)
        self.assertNotIn("### Passed only on re-run", lines)
        self.assert_last_call(2, "pcloud-plain", FETCH)

    def test_pair_without_result_of_rerun_stays_failing(self):
        self.write_failed_main_pass()
        self.write_pass("pass2", results(test_case(DELETE, "Passed", argument("pcloud-plain"))))

        result = self.run_script()

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\tpcloud-plain\n".format(FETCH), self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `pcloud-plain` | 0 | 1 | 1 | 0 |", lines)
        self.assertIn("- `{}` `pcloud-plain`: no failure message".format(FETCH), lines)
        self.assert_last_call(2, "pcloud-plain", FETCH, DELETE)

    def test_pair_that_rerun_skips_stays_failing(self):
        self.write_pass("pass1", results(test_case(S3, "Failed")), exit_code=65)
        self.write_pass("pass2", results(skipped(S3)))

        result = self.run_script()

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\ts3\n".format(S3), self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `s3` | 0 | 1 | 0 | 0 |", lines)
        self.assertIn("- `{}` `s3`: no failure message".format(S3), lines)
        self.assert_last_call(2, "s3", S3)

    # Tokens

    def test_test_of_no_backend_is_rerun_with_filter_of_main_pass(self):
        self.write_pass("pass1", results(test_case(RUNNER, "Failed", failure("Expectation failed: a == b"))), exit_code=65)
        self.write_pass("pass2", results(test_case(RUNNER, "Failed")), exit_code=65)

        result = self.run_script(BACKENDS="pcloud,s3-vf8")

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\t-\tpcloud,s3-vf8\n".format(RUNNER), self.still_failing())
        self.assertIn("- `{}` `-`: expectation failed".format(RUNNER), result.stdout.splitlines())
        self.assert_last_call(2, "pcloud,s3-vf8", RUNNER)

    def test_test_of_no_backend_is_rerun_on_all_backends_after_unfiltered_main_pass(self):
        # The failed backend pair has a token, which must not narrow the re-run's filter.
        self.write_pass("pass1", results(test_case(RUNNER, "Failed"), test_case(FETCH, "Failed", argument("pcloud-plain", "Failed"))), exit_code=65)
        self.write_pass("pass2", results(test_case(RUNNER, "Failed"), test_case(FETCH, "Failed", argument("pcloud-plain", "Failed"))), exit_code=65)

        result = self.run_script()

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\t-\t\n{}\tpcloud-plain\n".format(RUNNER, FETCH), self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("- `{}` `-`: no failure message".format(RUNNER), lines)
        self.assertIn("- `{}` `pcloud-plain`: no failure message".format(FETCH), lines)
        self.assert_last_call(2, "", RUNNER, FETCH)

    def test_test_of_no_backend_is_healed_by_rerun_with_another_filter(self):
        self.write_pass("pass1", results(test_case(RUNNER, "Failed"), test_case(FETCH, "Failed", argument("pcloud-plain", "Failed"))), exit_code=65)
        self.write_pass("pass2", results(test_case(RUNNER, "Passed"), test_case(FETCH, "Passed", argument("pcloud-plain"))))

        result = self.run_script(BACKENDS="pcloud")

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        self.assertIn("| `-` | 0 | 0 | 1 | 0 |", result.stdout.splitlines())
        self.assert_last_call(2, "pcloud,pcloud-plain", RUNNER, FETCH)

    def test_test_with_other_arguments_than_backends_is_one_pair_of_no_backend(self):
        failed_test = results(test_case(VAULT_FORMATS, "Failed", argument(".vf6", "Failed"), argument(".vf8")))
        self.write_pass("pass1", failed_test, exit_code=65)
        self.write_pass("pass2", failed_test, exit_code=65)

        result = self.run_script(BACKENDS="pcloud")

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\t-\tpcloud\n".format(VAULT_FORMATS), self.still_failing())
        self.assertIn("| `-` | 0 | 1 | 0 | 0 |", result.stdout.splitlines())
        self.assert_last_call(2, "pcloud", VAULT_FORMATS)

    def test_provider_specific_test_is_rerun_with_its_provider(self):
        self.write_pass("pass1", results(test_case(S3, "Failed")), exit_code=65)
        self.write_pass("pass2", results(test_case(S3, "Passed")))

        result = self.run_script()

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        self.assertIn("| `s3` | 0 | 0 | 1 | 0 |", result.stdout.splitlines())
        self.assert_last_call(2, "s3", S3)

    # --only

    def test_only_runs_listed_tests_on_listed_backends(self):
        only_file = self.write_file("{}\tpcloud-plain\n{}\ts3\n".format(FETCH, S3))
        self.write_pass("pass1", results(test_case(FETCH, "Passed", argument("pcloud-plain")), test_case(S3, "Passed")))

        result = self.run_script("--only", only_file, BACKENDS="webdav")

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `pcloud-plain` | 1 | 0 | 0 | 0 |", lines)
        self.assertIn("| `s3` | 1 | 0 | 0 | 0 |", lines)
        self.assert_last_call(1, "pcloud-plain,s3", FETCH, S3)

    def test_only_reads_list_that_the_run_replaces(self):
        self.write_still_failing_of_earlier_run("{}\tpcloud-plain\n".format(FETCH))
        self.write_pass("pass1", results(test_case(FETCH, "Passed", argument("pcloud-plain"))))

        result = self.run_script("--only", STILL_FAILING)

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        self.assert_last_call(1, "pcloud-plain", FETCH)

    def test_only_with_unfiltered_test_of_no_backend_selects_all_backends(self):
        only_file = self.write_file("{}\t-\t\n{}\tpcloud-plain\n".format(RUNNER, FETCH))
        self.write_pass("pass1", results(test_case(RUNNER, "Passed"), test_case(FETCH, "Passed", argument("pcloud-plain"))))

        result = self.run_script("--only", only_file)

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        self.assertIn("| `-` | 1 | 0 | 0 | 0 |", result.stdout.splitlines())
        self.assert_last_call(1, "", RUNNER, FETCH)

    def test_only_keeps_listed_pair_without_result_failing(self):
        only_file = self.write_file("{}\tpcloud-plain\n{}\tpcloud-plain\n".format(FETCH, DELETE))
        self.write_pass("pass1", results(test_case(DELETE, "Passed", argument("pcloud-plain"))))

        result = self.run_script("--only", only_file)

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\tpcloud-plain\n".format(FETCH), self.still_failing())
        self.assertIn("- `{}` `pcloud-plain`: no result".format(FETCH), result.stdout.splitlines())
        self.assertEqual(1, len(self.calls()))

    def test_only_keeps_listed_pair_that_is_skipped_failing(self):
        only_file = self.write_file("{}\ts3\n".format(S3))
        self.write_pass("pass1", results(skipped(S3)))

        result = self.run_script("--only", only_file)

        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\ts3\n".format(S3), self.still_failing())
        lines = result.stdout.splitlines()
        self.assertIn("| `s3` | 0 | 1 | 0 | 0 |", lines)
        self.assertIn("- `{}` `s3`: no failure message".format(S3), lines)
        self.assertEqual(1, len(self.calls()))

    def test_malformed_only_file_runs_nothing(self):
        contents = {"no tab": FETCH + "\n", "empty token": FETCH + "\t\n", "empty file": ""}
        for name, content in contents.items():
            with self.subTest(name):
                result = self.run_script("--only", self.write_file(content))

                self.assertEqual(2, result.exit_code)
                self.assertIn("Can't read the pairs to run", result.stderr)
                self.assertEqual([], self.calls())

    def test_missing_only_file_runs_nothing(self):
        result = self.run_script("--only", os.path.join(self.root, "missing.txt"))

        self.assertEqual(2, result.exit_code)
        self.assertIn("Can't read the pairs to run", result.stderr)
        self.assertEqual([], self.calls())

    def test_unknown_argument_runs_nothing(self):
        result = self.run_script("--bogus")

        self.assertEqual(2, result.exit_code)
        self.assertIn("Unknown argument: --bogus", result.stderr)
        self.assertEqual([], self.calls())

    # Incomplete main pass

    def test_main_pass_with_crash_message_of_test_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed"), failure("Crash: xctest at specialized closure"))), exit_code=65)
        self.assert_main_pass_incomplete("a test process crashed")

    def test_main_pass_with_crash_message_of_argument_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Crash: xctest at specialized closure")))), exit_code=65)
        self.assert_main_pass_incomplete("a test process crashed")

    def test_main_pass_with_crash_as_underlying_error_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed"), failure("The test runner failed. Underlying Error: Crash: xctest (1234)"))), exit_code=65)
        self.assert_main_pass_incomplete("a test process crashed")

    def test_main_pass_with_restarted_test_process_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Test crashed with signal kill, restarting after unexpected exit")))), exit_code=65)
        self.assert_main_pass_incomplete("a test process crashed")

    def test_main_pass_with_lost_connection_to_test_process_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Lost connection to the test process")))), exit_code=65)
        self.assert_main_pass_incomplete("a test process crashed")

    def test_main_pass_with_test_that_did_not_finish_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("The test did not finish")))), exit_code=65)
        self.assert_main_pass_incomplete("a test process crashed")

    def test_main_pass_with_runner_error_is_incomplete(self):
        self.write_pass("pass1", results(test_case(RUNNER_ERROR, "Failed", failure("The simulator couldn't be cloned")), test_case(FETCH, "Passed", argument("pcloud-plain"))), exit_code=65)
        self.assert_main_pass_incomplete("the test runner reported an error")

    def test_main_pass_whose_test_process_exited_before_testing_is_incomplete(self):
        self.write_pass("pass1", results(test_case(RUNNER_ERROR, "Failed", failure("Early unexpected exit, operation never finished bootstrapping - no restart will be attempted."))), exit_code=65)
        self.assert_main_pass_incomplete("the test process exited before testing started")

    def test_main_pass_whose_test_process_crashed_before_testing_is_incomplete(self):
        self.write_pass("pass1", results(test_case(RUNNER_ERROR, "Failed", failure("Early unexpected exit, operation never finished bootstrapping - no restart will be attempted."), failure("Crash: xctest at dyld"))), exit_code=65)
        self.assert_main_pass_incomplete("the test process crashed before testing started")

    def test_main_pass_that_failed_without_failed_pair_is_incomplete(self):
        self.write_pass("pass1", results(test_case(FETCH, "Passed", argument("pcloud-plain"))), exit_code=65)
        self.assert_main_pass_incomplete("it failed without a failed test")

    def test_main_pass_without_results_is_incomplete(self):
        self.write_pass("pass1", results())
        self.assert_main_pass_incomplete("no test reported a result")

    def test_main_pass_with_unreadable_results_is_incomplete(self):
        self.assert_main_pass_incomplete("its results can't be read")

    def test_main_pass_with_unparseable_results_is_incomplete(self):
        self.write_pass("pass1", "not JSON")
        self.assert_main_pass_incomplete("its results can't be parsed")

    # Incomplete re-run

    def test_results_of_rerun_with_runner_error_do_not_count(self):
        self.write_failed_main_pass()
        self.write_pass("pass2", results(test_case(RUNNER_ERROR, "Failed", failure("The simulator couldn't be cloned")), test_case(FETCH, "Passed", argument("pcloud-plain"))), exit_code=65)
        self.assert_rerun_incomplete("the test runner reported an error")

    def test_rerun_with_crash_is_incomplete(self):
        self.write_failed_main_pass()
        self.write_pass("pass2", results(test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure("Crash: xctest at specialized closure"))), test_case(DELETE, "Passed", argument("pcloud-plain"))), exit_code=65)
        self.assert_rerun_incomplete("a test process crashed")

    def test_rerun_with_unreadable_results_is_incomplete(self):
        self.write_failed_main_pass()
        self.assert_rerun_incomplete("its results can't be read")

    # Summary

    def test_failed_summary_fails_the_run(self):
        self.write_pass("pass1", results(test_case(FETCH, "Passed", argument("pcloud-plain"))))
        output_directory = os.path.join(self.working_directory, "integration-output")
        os.mkdir(output_directory)
        os.chmod(output_directory, stat.S_IRUSR | stat.S_IXUSR)
        self.addCleanup(os.chmod, output_directory, stat.S_IRWXU)

        result = self.run_script()

        self.assertEqual(1, result.exit_code)
        self.assertIsNone(self.still_failing())
        self.assertNotIn("## Integration tests", result.stdout)
        self.assertEqual(1, len(self.calls()))

    def test_summary_withholds_credentials(self):
        url_error = 'Caught error: Error Domain=NSURLErrorDomain Code=-1001 "The request timed out." UserInfo={{NSErrorFailingURLStringKey=https://user:{}@example.com/}}'.format(SENTINEL)
        failed_tests = results(
            test_case(FETCH, "Failed", argument("pcloud-plain", "Failed", failure(url_error))),
            test_case(DELETE, "Failed", argument("pcloud-plain", "Failed", failure("Request to https://example.com/?token={} failed".format(SENTINEL)))),
        )
        log = "".join([
            '"emittedOutput" : "[integration-retry] fetchItemMetadataForFile(backend:) pcloud-plain attempt 1: Error Domain=NSURLErrorDomain Code=-1005 UserInfo={{NSErrorFailingURLStringKey=https://user:{}@example.com/}}\\n'.format(SENTINEL),
            "[integration-retry] deleteFile(backend:) pcloud-plain attempt 1: https://example.com/?token={} failed\\n".format(SENTINEL),
        ])
        self.write_pass("pass1", failed_tests, exit_code=65, log=log)
        self.write_pass("pass2", failed_tests, exit_code=65)
        summary_file = os.path.join(self.root, "step-summary.md")

        result = self.run_script(GITHUB_STEP_SUMMARY=summary_file)

        with open(summary_file) as file:
            summary = file.read()
        self.assertEqual(1, result.exit_code)
        self.assertEqual("{}\tpcloud-plain\n{}\tpcloud-plain\n".format(FETCH, DELETE), self.still_failing())
        for output in (result.stdout, result.stderr, summary):
            self.assertNotIn(SENTINEL, output)
        self.assertEqual(result.stdout[result.stdout.index("## Integration tests"):], summary)
        lines = summary.splitlines()
        self.assertIn("- `{}` `pcloud-plain`: NSURLErrorDomain -1001".format(FETCH), lines)
        self.assertIn("- `{}` `pcloud-plain`: details withheld".format(DELETE), lines)
        self.assertIn("- pass1: `fetchItemMetadataForFile(backend:)` `pcloud-plain` attempt 1: NSURLErrorDomain -1005", lines)
        self.assertIn("- pass1: `deleteFile(backend:)` `pcloud-plain` attempt 1: details withheld", lines)

    def test_summary_lists_each_retry_once_and_cuts_its_message(self):
        # The action log is JSON, so a line of the console ends at an escaped line break or at the string's closing quote.
        retries = '[integration-retry] deleteFile(backend:) pcloud-plain attempt 1: itemNotFound\\n[integration-retry] multipartUpload() s3 attempt 2: noInternetConnection","kind":"output"'
        log = '{{"emittedOutput":"{}}}\n{{"emittedOutput":"{}}}\n'.format(retries, retries)
        self.write_pass("pass1", results(test_case(DELETE, "Passed", argument("pcloud-plain")), test_case(S3, "Passed")), log=log)

        result = self.run_script()

        self.assertEqual(0, result.exit_code)
        self.assertEqual("", self.still_failing())
        self.assertEqual(1, len(self.calls()))
        lines = result.stdout.splitlines()
        self.assertIn("<details><summary>Retried in-process (2)</summary>", lines)
        self.assertEqual(1, lines.count("- pass1: `deleteFile(backend:)` `pcloud-plain` attempt 1: itemNotFound"))
        self.assertEqual(1, lines.count("- pass1: `multipartUpload()` `s3` attempt 2: noInternetConnection"))


if __name__ == "__main__":
    unittest.main()
