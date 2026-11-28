"""Interactive desktop provisioning orchestration and macOS adapters."""

import base64
from contextlib import contextmanager
import datetime as dt
from getpass import GetPassWarning, getpass
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
from urllib.parse import urlsplit
import warnings
import uuid
import zipfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def provider_origin(value):
    url = urlsplit(value)
    require(url.scheme == "https" and url.hostname and url.netloc == url.hostname
            and re.fullmatch(r"[a-z0-9.-]+", url.hostname)
            and url.path in ("", "/") and not url.query and not url.fragment,
            "Set ZAG_ANISETTE_URL to the HTTPS origin of the authorized anisette v3 service")
    return f"https://{url.hostname}"


def scope(*parts):
    return hashlib.sha256(json.dumps(parts, separators=(",", ":")).encode()).hexdigest()


def command(args, data=None, stage="Desktop helper"):
    result = subprocess.run(args, input=data, capture_output=True, timeout=120)
    require(result.returncode == 0, f"{stage} failed (exit {result.returncode})")
    return result.stdout


class Keychain:
    def __init__(self, helper):
        self.helper = helper

    def read(self, item):
        result = subprocess.run([self.helper, "read", item], capture_output=True, timeout=120)
        if result.returncode == 3:
            return None
        require(result.returncode == 0, "Could not read desktop installer Keychain item")
        return result.stdout

    def write(self, item, value):
        command([self.helper, "write", item], value, "Keychain write")


class Identity:
    def __init__(self, store, account, team, openssl, approve, upgrade=False, expected_leaf=None):
        self.store = store
        self.upgrade = upgrade
        self.expected_leaf = expected_leaf
        self.key_item = scope("signing-key", account, team)
        self.pending_item = scope("pending-csr", account, team)
        self.machine_item = scope("certificate-machine", account, team)
        self.openssl = openssl
        self.approve = approve
        self.key = store.read(self.key_item)
        self.public = (command([openssl, "pkey", "-pubout"], self.key, "Read local signing key")
                       if self.key is not None else None)
        self.certificate = None

    def matches(self, der):
        if self.public is None:
            return False
        public = command([self.openssl, "x509", "-inform", "DER", "-pubkey", "-noout"],
                         der, "Read Apple certificate public key")
        if public != self.public:
            return False
        result = subprocess.run([self.openssl, "x509", "-inform", "DER", "-checkend", "0", "-noout"],
                                input=der, capture_output=True, timeout=120)
        return result.returncode == 0

    def select(self, certificates):
        matches = {}
        for index, encoded in enumerate(certificates):
            leaf = base64.b64decode(encoded, validate=True)
            fingerprint = hashlib.sha256(leaf).hexdigest()
            if (self.expected_leaf is None or fingerprint == self.expected_leaf) and self.matches(leaf):
                if not self.upgrade:
                    return {"index": index}
                matches[fingerprint] = index
        require(len(matches) <= 1, "Several certificates match the existing key and the installed leaf is unknown")
        if matches:
            return {"index": next(iter(matches.values()))}
        require(not self.upgrade, "Upgrade requires an active Apple certificate for the existing local signing key")
        require(self.store.read(self.pending_item) in (None, b""),
                "Previous certificate issuance is unresolved. Check Apple certificate inventory before retrying.")
        require(confirm_action(self.approve, "Create an Apple Development certificate if Apple has capacity?", "CREATE", "Create Certificate") == "CREATE",
                "Certificate creation cancelled")
        if self.key is None:
            self.key = command([self.openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"],
                               stage="Generate signing key")
            self.public = command([self.openssl, "pkey", "-pubout"], self.key, "Read generated public key")
            self.store.write(self.key_item, self.key)
        csr = command([self.openssl, "req", "-new", "-key", "/dev/stdin", "-subj", "/CN=Zag Installer"],
                      self.key, "Create certificate request")
        # Save before returning the CSR. A failed response can hide successful issuance.
        machine_id = self.store.read(self.machine_item)
        if machine_id is None:
            machine_id = str(uuid.uuid4()).upper().encode("ascii")
            self.store.write(self.machine_item, machine_id)
        self.store.write(self.pending_item, b"pending")
        return {"csr": csr.decode("ascii"), "machine_id": machine_id.decode("ascii")}

    def bind(self, encoded):
        certificate = base64.b64decode(encoded, validate=True)
        require(self.matches(certificate), "Apple certificate does not match the account-scoped desktop key")
        require(self.expected_leaf is None or hashlib.sha256(certificate).hexdigest() == self.expected_leaf,
                "Apple certificate differs from the verified installation's signing identity")
        self.clear_request()
        self.certificate = certificate
        return True

    def clear_request(self):
        if self.store.read(self.pending_item):
            self.store.write(self.pending_item, b"")


def secret(prompt):
    with warnings.catch_warnings():
        warnings.simplefilter("error", GetPassWarning)
        try:
            return getpass(prompt)
        except GetPassWarning as error:
            raise ValueError("Secure Terminal input is unavailable") from error


def two_factor(event, approve):
    if event["retry"]:
        print("Apple requested another verification attempt.")
    numbers = [number for number in event["numbers"]
               if re.fullmatch(r"[0-9]{2}", number["last_two"])]
    for index, number in enumerate(numbers, 1):
        print(f"  {index}. SMS to number ending in {number['last_two']}")
    choices = "d for trusted device, q to cancel"
    if not event["unknown"]:
        choices = "c to enter code, r to resend, " + choices
    choice = approve(f"Apple verification ({choices}, or select an SMS number): ").strip().lower()
    if choice == "c" and not event["unknown"]:
        code = secret("Apple verification code: ").strip()
        require(re.fullmatch(r"[0-9]{6}", code), "Expected a six-digit Apple verification code")
        return {"action": "code", "code": code}
    if choice == "d":
        return {"action": "devices"}
    if choice == "r" and not event["unknown"]:
        return {"action": "resend"}
    if re.fullmatch(r"[0-9]{1,5}", choice) and 1 <= int(choice) <= len(numbers):
        return {"action": "sms", "id": numbers[int(choice) - 1]["id"]}
    return {"action": "abort"}


class NativeAnisette:
    def __init__(self, helper, store, approve):
        self.helper = helper
        self.store = store
        self.approve = approve
        self.item = None
        self.state = None

    def identity(self):
        result = json.loads(command([self.helper, "identity"], b"", "Load clean-room Apple ADI provider"))
        return result["identity"]

    def headers(self, prepare):
        require(self.item is not None, "Missing local anisette account scope")
        if prepare:
            self.state = self.store.read(self.item)
        if self.state is None:
            require(prepare and confirm_action(self.approve, "Allow a new local ADI profile to provision with Apple?", "ANISETTE", "Continue")
                    == "ANISETTE", "Apple ADI provisioning cancelled")
            mode = "provision"
        else:
            mode = "headers"
        result = json.loads(command([self.helper, mode], self.state or b"", "Derive local anisette"))
        if "status" in result:
            status, count = result["status"], result["requests"]
            require(type(status) is int and type(count) is int, "Invalid local ADI status")
            hint = result.get("network_hint")
            detail = f" {hint}" if isinstance(hint, str) else ""
            raise ValueError(f"Apple ADI failed with status {status} after {count} Apple requests.{detail}")
        if mode == "provision":
            state = base64.b64decode(result["state"], validate=True)
            require(state and len(state) <= 1024 * 1024, "Invalid local ADI state")
            self.store.write(self.item, state)
            self.state = state
        return result["headers"]


class Provisioning:
    def __init__(self, endpoint, udid, store, openssl, choose_team, approve, native_helper=None,
                 upgrade=False, components=None):
        self.endpoint = endpoint
        self.native = NativeAnisette(native_helper, store, approve) if native_helper else None
        self.udid = udid
        self.store = store
        self.openssl = openssl
        self.choose_team = choose_team
        self.approve = approve
        self.anisette_scope = None
        self.identity = None
        self.team = None
        self.upgrade = upgrade
        self.components = components if components is not None else {"": ""}
        self.profiles = {}
        self.account_bootstrap = False
        self.account_credential = None
        self.account_id = None
        self.email = None
        self._pending_password = None

    def handle(self, message):
        event = message["event"]
        if event == "configuration":
            from ui_protocol import Channel
            channel = getattr(self.approve, "__self__", None)
            if self.native and isinstance(channel, Channel):
                email, self._pending_password = channel.credentials()
            else:
                email = self.approve("Apple ID: ").strip()
            require(email, "Apple ID is required")
            self.email = email
            if self.native:
                self.native.item = scope("anisette", "clean-room-mac-legacy-v1", email.casefold())
                config = {"provider": "native", "email": email, "udid": self.udid, "suffixes": list(self.components.values())}
                if self.account_bootstrap:
                    config["account_bootstrap"] = True
                return config
            require(self.endpoint and confirm_action(self.approve, f"Use approved anisette service {self.endpoint}?", "ANISETTE", "Continue")
                    == "ANISETTE", "Remote anisette cancelled")
            self.anisette_scope = scope("anisette", self.endpoint, email.casefold())
            return {"provider": "remote", "endpoint": self.endpoint, "email": email, "udid": self.udid,
                    "suffixes": list(self.components.values())}
        if event in ("native_identity", "native_headers"):
            require(self.native is not None, "Local anisette is not configured")
            if event == "native_identity":
                return self.native.identity()
            return self.native.headers(message["prepare"])
        if event == "password":
            if self._pending_password is not None:
                password, self._pending_password = self._pending_password, None
                return password
            return secret("Apple ID password: ")
        if event in ("state_read", "state_write"):
            require(self.anisette_scope is not None, "Missing anisette account scope")
            item = scope(self.anisette_scope, message["key"])
            if event == "state_read":
                data = self.store.read(item)
                return None if data is None else data.decode("utf-8")
            self.store.write(item, message["value"].encode())
            return True
        if event == "two_factor":
            return two_factor(message, self.approve)
        if event == "team":
            account = message["account"]
            require(isinstance(account, str) and account, "Missing authenticated Apple account ID")
            self.account_id = account
            self.team = self.choose_team(message["teams"])
            self.receipt_item = scope("installed-leaf", self.udid.casefold(), self.team)
            stored_leaf = self.store.read(self.receipt_item) if self.upgrade else None
            expected = None
            if stored_leaf is not None:
                expected = stored_leaf.decode("ascii")
                require(re.fullmatch(r"[0-9a-f]{64}", expected), "Installed signing receipt is unreadable")
            self.identity = Identity(self.store, account, self.team, self.openssl, self.approve, self.upgrade, expected)
            return self.team
        if event == "account_bootstrap":
            # This event arrives over the private child pipe, never the GUI
            # event stream, and is retained in memory only for this install.
            require(self.account_bootstrap and self.native is not None and self.identity is not None
                    and self.account_credential is None, "Unexpected account bootstrap event")
            token = message.get("credential")
            require(isinstance(token, dict) and set(token) == {"accountID", "token", "expiresAtMs"}
                    and token["accountID"] == self.account_id
                    and isinstance(token["accountID"], str) and 0 < len(token["accountID"]) <= 128
                    and isinstance(token["token"], str) and 0 < len(token["token"]) <= 3500
                    and all(ord(c) >= 32 for c in token["token"])
                    and type(token["expiresAtMs"]) is int
                    and token["expiresAtMs"] > int(dt.datetime.now(dt.timezone.utc).timestamp() * 1000),
                    "Invalid portable developer credential")
            require(isinstance(self.email, str) and 0 < len(self.email) <= 320, "Invalid account label")
            payload = json.dumps({"token": token, "email": self.email}, separators=(",", ":")).encode()
            require(len(payload) <= 4096, "Portable developer credential exceeds handoff limit")
            self.account_credential = payload
            return True
        if event == "failure":
            code = message.get("code")
            from ui_protocol import AppleFailure
            raise AppleFailure(message.get("stage"), code, message.get("network_hint"))
        require(self.identity is not None, "Missing authenticated signing identity")
        if event == "certificate":
            return self.identity.select(message["certificates"])
        if event == "certificate_refused":
            self.identity.clear_request()
            return True
        if event == "certificate_selected":
            return self.identity.bind(message["der"])
        if event == "profile":
            require(self.identity.certificate is not None, "Missing verified certificate binding")
            suffix = message["suffix"]
            require(suffix in self.components.values() and suffix not in self.profiles, "Unexpected provisioned component")
            self.profiles[suffix] = base64.b64decode(message["data"], validate=True)
            return True
        raise ValueError("Unknown desktop provisioning event")

    def run(self, binary):
        with subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL, text=True, encoding="utf-8") as child:
            try:
                for line in child.stdout:
                    response = self.handle(json.loads(line))
                    child.stdin.write(json.dumps(response) + "\n")
                    child.stdin.flush()
                require(child.wait(timeout=10) == 0 and self.profiles.keys() == set(self.components.values()),
                        "Desktop Apple provisioning did not complete")
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
        return self.team, self.identity, self.profiles


def personal_entitlements(artifact, profile, certificate, team, udid, suffix=""):
    identifier = artifact.mapped_bundle(team) + suffix
    qualified = f"{team}.{identifier}"
    require(profile.get("LocalProvision") is True, "Apple did not issue a Personal Team profile")
    entitlements = {
        "application-identifier": qualified,
        "com.apple.developer.team-identifier": team,
        "get-task-allow": True,
        "keychain-access-groups": [qualified],
    }
    artifact.validate_profile(profile, entitlements, certificate, team, identifier, udid,
                              dt.datetime.now(dt.timezone.utc))
    return entitlements


def prepare_profile_root(artifact, repo, root, supplied=None):
    if supplied is None:
        pinned = (repo / "AppleAuthCore/zag-isideload/src/assets/apple_root.cer").read_bytes()
    else:
        require(supplied.is_file() and 0 < supplied.stat().st_size < 65536, "Invalid Apple root PEM")
        pinned = artifact.command("openssl", "x509", "-in", str(supplied), "-outform", "DER")
    require(hashlib.sha256(pinned).hexdigest() == artifact.APPLE_ROOT, "Unexpected profile trust anchor")
    root.write_text("-----BEGIN CERTIFICATE-----\n" + base64.encodebytes(pinned).decode("ascii")
                    + "-----END CERTIFICATE-----\n", encoding="ascii")


def signing_components(app, original):
    components = {"": ""}
    for path in sorted(app.rglob("*")):
        if not path.is_dir() or path.suffix not in (".app", ".appex", ".xpc"):
            continue
        relative = path.relative_to(app)
        require(path.suffix == ".appex" and len(relative.parts) == 2 and relative.parts[0] == "PlugIns",
                "Unsupported nested application or extension layout")
        info = plistlib.loads((path / "Info.plist").read_bytes())
        identifier = info.get("CFBundleIdentifier", "")
        require(identifier.startswith(original + "."), "Extension identifier does not belong to Zag Store")
        suffix = identifier[len(original):]
        require(re.fullmatch(r"(?:\.[A-Za-z0-9-]+)+", suffix) and suffix not in components.values(),
                "Invalid or repeated extension identifier")
        components[str(relative)] = suffix
    return components


def sign(artifact, app, relative, team, udid, identity, profiles, components, root, helper, scratch):
    manifest = {}
    for index, (path, suffix) in enumerate(components.items()):
        profile = scratch / f"component-{index}.mobileprovision"
        raw = profiles[suffix]
        profile.write_bytes(raw)
        trusted = plistlib.loads(artifact.command("openssl", "smime", "-verify", "-inform", "DER",
                                                 "-purpose", "any", "-CAfile", str(root), "-no-CApath", "-no-CAstore",
                                                 "-in", str(profile)))
        entitlements = personal_entitlements(artifact, trusted, identity.certificate, team, udid, suffix)
        manifest[path] = {"provision": raw, "entitlements": plistlib.dumps(entitlements)}
    leaf = scratch / "leaf.der"
    leaf.write_bytes(identity.certificate)
    component_file = scratch / "components.plist"
    component_file.write_bytes(plistlib.dumps(manifest))
    command([helper, "sign", app, artifact.mapped_bundle(team), leaf, component_file],
            identity.key, "Strict desktop Zsign signing")
    signed = scratch / "signed.ipa"
    with zipfile.ZipFile(signed, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=3) as archive:
        for path in sorted(app.rglob("*")):
            require(not path.is_symlink(), "Unexpected symbolic link after signing")
            archive.write(path, relative / path.relative_to(app))
    return signed


@contextmanager
def locked_cache(precompiled=None):
    import fcntl  # macOS adapter
    cache = Path.home() / "Library/Caches/app.zagstore.desktop-installer"
    cache.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = cache.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and info.st_mode & 0o077 == 0,
            "Installer cache must be a user-owned private directory")
    descriptor = os.open(cache / "install.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("Another desktop installer session is active") from error
        yield PrecompiledCache(precompiled) if precompiled is not None else BuildCache(cache)
    finally:
        os.close(descriptor)


class PrecompiledCache:
    """Explicit prebuilt helper adapter; never falls back to compilation."""

    def __init__(self, directory):
        original = Path(directory)
        require(original.is_dir() and not original.is_symlink(), "Precompiled helper directory is missing")
        self.directory = original.resolve(strict=True)
        info = self.directory.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                and info.st_mode & 0o022 == 0,
                "Precompiled helper directory must be user-owned and not writable by others")
        self._validate_inventory()

    def _validate_inventory(self):
        # Reject incomplete packages before starting release discovery or Apple sign-in.
        for name in ("release", "handoff", "zag_desktop", "zag-desktop-signer",
                     "zag-desktop-anisette", "openssl"):
            self.executable(name)
        lib = self.directory / "lib"
        require(lib.is_dir() and not lib.is_symlink(),
                "Packaged OpenSSL dependency directory is missing")
        for name in ("libssl.3.dylib", "libcrypto.3.dylib"):
            path = lib / name
            require(path.is_file() and not path.is_symlink(),
                    f"Missing packaged OpenSSL dependency: {name}")
            info = path.stat()
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and info.st_mode & 0o022 == 0,
                    f"Packaged OpenSSL dependency has insecure permissions: {name}")

    def executable(self, name):
        path = self.directory / name
        require(path.is_file() and not path.is_symlink() and os.access(path, os.X_OK),
                f"Required precompiled helper is unavailable: {name}")
        info = path.stat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and info.st_mode & 0o022 == 0,
                f"Packaged helper has insecure ownership or permissions: {name}")
        return path

    def build_swift(self, name, sources):
        require(name in ("release", "handoff"), "Unknown precompiled Swift helper")
        return self.executable(name)

    def signer_tools(self, repo):
        return self.executable("zag-desktop-signer"), self.executable("openssl")

    def installer_tools(self, repo, native):
        signer, openssl = self.signer_tools(repo)
        return (self.executable("zag_desktop"), signer, openssl,
                self.executable("zag-desktop-anisette") if native else None)


class BuildCache:
    def __init__(self, path):
        self.path = path

    def build_swift(self, name, sources):
        tag = hashlib.sha256(b"".join(path.read_bytes() for path in sources)).hexdigest()
        folder = self.path / tag
        binary = folder / name
        if not binary.is_file():
            folder.mkdir(mode=0o700, exist_ok=True)
            pending = folder / (name + ".pending")
            subprocess.run(["swiftc", "-module-cache-path", folder / "module-cache", *sources, "-o", pending],
                           check=True, timeout=120)
            pending.replace(binary)
        return binary

    def signer_tools(self, repo):
        cache = self.path
        openssl = shutil.which("openssl")
        require(openssl and command([openssl, "version"]).startswith(b"OpenSSL 3"),
                "Put Homebrew OpenSSL 3 on PATH before starting")
        signer_sources = [repo / "tools/zag-installer" / name for name in ("DesktopSigner.swift", "build-signer.sh")]
        signer_sources.append(repo / "scripts/zag-build-zsign-macos.sh")
        revision = command(["git", "-C", repo / "Zsign", "rev-parse", "HEAD"]).strip()
        helper_tag = hashlib.sha256(b"".join(path.read_bytes() for path in signer_sources) + revision).hexdigest()
        signer_dir = cache / helper_tag
        signer = signer_dir / "zag-desktop-signer"
        if not signer.is_file():
            signer_dir.mkdir(mode=0o700, exist_ok=True)
            subprocess.run(["bash", repo / "tools/zag-installer/build-signer.sh", signer_dir],
                           check=True, timeout=300)
        return signer, openssl

    def installer_tools(self, repo, native):
        cache = self.path
        print("Building the desktop helpers if needed.", flush=True)
        auth = repo / "AppleAuthCore/zag-isideload/Cargo.toml"
        cargo_target = cache / "cargo"
        subprocess.run(["cargo", "build", "--locked", "--manifest-path", auth, "--features",
                        "live-network", "--example", "zag_desktop", "--target-dir", cargo_target],
                       check=True, timeout=600)
        signer, openssl = self.signer_tools(repo)
        anisette = None
        if native:
            anisette_sources = [repo / "tools/zag-installer" / name
                                for name in ("DesktopAnisette.swift", "DesktopNetwork.swift", "build-anisette.sh")]
            anisette_dir = repo / "AppleAuthCore/apple-auth"
            anisette_sources += [anisette_dir / "build-apple-auth.sh", *sorted((anisette_dir / "patches").glob("*.patch"))]
            tag = hashlib.sha256(b"".join(path.read_bytes() for path in anisette_sources)).hexdigest()
            build_dir = cache / tag
            anisette = build_dir / "zag-desktop-anisette"
            if not anisette.is_file():
                build_dir.mkdir(mode=0o700, exist_ok=True)
                subprocess.run(["bash", repo / "tools/zag-installer/build-anisette.sh", build_dir],
                               check=True, timeout=600)
        return cargo_target / "debug/examples/zag_desktop", signer, openssl, anisette


# Keep Terminal confirmation phrases while using explicit GUI button contracts.
def confirm_action(approve, message, expected, action):
    from ui_protocol import Channel
    channel = getattr(approve, "__self__", None)
    if isinstance(channel, Channel):
        return channel.confirm(message, expected, action)
    return approve(f"{message} Type {expected}: ")
