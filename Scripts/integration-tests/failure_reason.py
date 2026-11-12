# The summary is public, and a failure message can contain request URLs with credentials, e.g., in a URLError. So a failure message
# is reduced to a part that can't contain them: an error's domain and code, a case of a known error, a known error that
# wasn't thrown, or that an expectation failed. Anything else becomes `details withheld`. Expectations aren't quoted,
# because tests interpolate metadata, contents and errors into them.

import re

# The cases of CloudProviderError and IntegrationTestError.
KNOWN_ERRORS = {
    "itemNotFound", "itemAlreadyExists", "itemTypeMismatch", "parentFolderDoesNotExist", "pageTokenInvalid",
    "quotaInsufficient", "unauthorized", "noInternetConnection",
    "consistencyTimeout", "itemNotVisible", "fixtureTimeout", "budgetExceeded",
}

def reason(message):
    message = message.strip()
    if not message:
        return ""
    domain_code = re.search(r"\bError Domain=([A-Za-z0-9_.-]+) Code=(-?\d+)", message)
    if domain_code:
        return f"{domain_code.group(1)} {domain_code.group(2)}"
    known_error = re.fullmatch(r"(?:Caught error: )?([A-Za-z]+)(?:\(.*\))?", message, re.DOTALL)
    if known_error and known_error.group(1) in KNOWN_ERRORS:
        return known_error.group(1)
    not_thrown = re.fullmatch(r"Expected ([A-Za-z]+), but nothing was thrown", message)
    if not_thrown and not_thrown.group(1) in KNOWN_ERRORS:
        return message
    if message.startswith("Expectation failed"):
        return "expectation failed"
    return "details withheld"
