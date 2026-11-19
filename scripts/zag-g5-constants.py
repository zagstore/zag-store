# G5: the campaign ledger and the constants file, for zag-g5-build-check.sh.
#   check   (constants file on stdin) conditions, ledger row, constants form
#   write   prints the constants file for the authorised row
#   verify  (constants file on stdin) the form of a constants commit
#   id      prints the authorised campaign ID
import datetime, os, re, sys

LEDGER = os.environ.get("ZAG_G5_LEDGER", "")
CONDITIONS = os.environ.get("ZAG_G5_CONDITIONS", "").split()
EXPECTED_CONDITIONS = {"ZAG_APPLE_BRIDGE", "ZAG_ZSIGN_STRICT", "ZAG_LIVE_EXPERIMENT"}
COLUMNS = ["ID", "Number", "Authorisation (quoted)", "notBefore (UTC)", "notAfter (UTC)", "Account label", "Provider",
           "Serial policy", "Branch SHA", "Build nonce", "IPA SHA-256", "State"]
PLACEHOLDER_ID = 'static let campaignID = "G5-C0"'


def refuse(reason):
    print(f"REFUSED: {reason}", file=sys.stderr)
    sys.exit(1)


def rows():
    text = open(LEDGER).read()
    table = [line for line in text.splitlines() if line.startswith("|")]
    if not table or [c.strip() for c in table[0].strip("|").split("|")] != COLUMNS:
        refuse("the ledger's campaign table does not have the expected columns")
    result = []
    for line in table[2:]:
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != len(COLUMNS):
            refuse("a ledger row has the wrong number of cells")
        result.append(dict(zip(COLUMNS, cells)))
    return result


def when(text):
    try:
        value = datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        refuse(f"a window time is not ISO 8601 UTC (YYYY-MM-DDTHH:MM:SSZ)")
    return value


def authorised():
    if set(CONDITIONS) != EXPECTED_CONDITIONS or len(CONDITIONS) != 3:
        refuse(f"the conditions must be exactly {sorted(EXPECTED_CONDITIONS)}; never DEBUG or ZAG_G5_TESTS (got {CONDITIONS})")
    all_rows = rows()
    candidates = [r for r in all_rows if r["State"] == "authorised"]
    if not candidates:
        refuse("no campaign is authorised in the ledger")
    if len(candidates) > 1:
        refuse("more than one campaign is authorised")
    row = candidates[0]
    if not re.fullmatch(r"[1-9][0-9]*", row["Number"]) or row["ID"] != f"G5-C{row['Number']}":
        refuse("the authorised row's ID and number do not match (G5-C<n>, n ≥ 1)")
    number = int(row["Number"])
    used = [int(r["Number"]) for r in all_rows if r is not row and r["State"] != "authorised" and r["Number"].isdigit()]
    if any(n >= number for n in used):
        refuse("the authorised number is not above every built, running or closed campaign")
    start, end = when(row["notBefore (UTC)"]), when(row["notAfter (UTC)"])
    now = datetime.datetime.now(datetime.timezone.utc)
    if not (start < end <= start + datetime.timedelta(days=7)):
        refuse("the window is empty or longer than 7 days")
    if now >= end:
        refuse("the authorisation window has passed")
    if not row["Provider"].startswith("https://"):
        refuse("the provider is not an https URL")
    if row["Serial policy"] not in ("g3Fixed", "g3PerAccount"):
        refuse("the serial policy is not g3Fixed or g3PerAccount")
    if row["Serial policy"] == "g3Fixed" and not os.environ.get("ZAG_G5_DEVICE_SERIAL"):
        refuse("g3Fixed needs ZAG_G5_DEVICE_SERIAL (never stored in the ledger)")
    if not re.fullmatch(r"[A-Z]", row["Account label"]):
        refuse("the account label must be a single letter, never an address")
    return row, start, end


def swift_string(value):
    if not re.fullmatch(r"[A-Za-z0-9:/._\-]*", value):
        refuse("a constant has characters outside the allowed set")
    return f'"{value}"'


command = sys.argv[1]
if command == "check":
    source = sys.stdin.read()
    row, _, _ = authorised()
    if PLACEHOLDER_ID not in source and f'static let campaignID = "{row["ID"]}"' not in source:
        refuse("the constants file names a different campaign")
    print(f"OK: {row['ID']} is authorised; conditions {' '.join(CONDITIONS)}")
elif command == "id":
    print(authorised()[0]["ID"])
elif command == "write":
    row, start, end = authorised()
    nonce, branch = os.environ["ZAG_G5_NONCE"], os.environ["ZAG_G5_BRANCH_SHA"]
    assert re.fullmatch(r"[0-9a-f]{32}", nonce) and nonce != "0" * 32 and re.fullmatch(r"[0-9a-f]{40}", branch)
    serial = os.environ.get("ZAG_G5_DEVICE_SERIAL", "") if row["Serial policy"] == "g3Fixed" else ""
    gates = ", ".join(f'"G{n}": true' for n in range(1, 7))
    print(f"""#if ZAG_LIVE_EXPERIMENT
import Foundation

// G5: the one campaign this experiment build may run (plan §3.2, §5.5).
// Written by scripts/zag-g5-build-check.sh from the `authorised` row of
// docs/free-developer-accounts/G5-CAMPAIGNS.md, in its own constants commit.
enum ZagLiveExperimentCampaignConstants {{
	static let campaignID = {swift_string(row["ID"])}
	static let campaignNumber = {int(row["Number"])}
	static let notBefore: TimeInterval = {int(start.timestamp())}
	static let notAfter: TimeInterval = {int(end.timestamp())}
	static let buildNonce = {swift_string(nonce)}
	static let anisetteURL = {swift_string(row["Provider"])}
	static let deviceSerialPolicy = {swift_string(row["Serial policy"])}
	static let deviceSerial = {swift_string(serial)}
	static let branchSHA = {swift_string(branch)}
	static let bridgeLibSHA = {swift_string(os.environ["ZAG_G5_BRIDGE_SHA"])}
	static let zsignSHA = {swift_string(os.environ["ZAG_G5_ZSIGN_SHA"])}
	static let gates = [{gates}]
}}
#endif""")
elif command == "verify":
    source = sys.stdin.read()
    expected = ["campaignID", "campaignNumber", "notBefore", "notAfter", "buildNonce", "anisetteURL", "deviceSerialPolicy",
                "deviceSerial", "branchSHA", "bridgeLibSHA", "zsignSHA", "gates"]
    names = re.findall(r"^\tstatic let (\w+)", source, flags=re.M)
    if names != expected or not source.startswith("#if ZAG_LIVE_EXPERIMENT\n") or not source.rstrip().endswith("#endif"):
        refuse("the constants file is not in the generated form")
    if re.search(r"\bfunc\b|\bvar\b|\bclass\b|\bimport (?!Foundation)", source):
        refuse("the constants file holds code")
else:
    refuse(f"unknown command {command}")
