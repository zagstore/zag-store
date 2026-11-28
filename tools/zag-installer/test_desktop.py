import base64
import io
import json
import datetime as dt
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import desktop
from test_zag_installer import RELEASE
import zag_installer as installer

TEAM = "FTB8PRW638"
BUNDLE = installer.artifact.mapped_bundle(TEAM)


class IdentityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("openssl"), "OpenSSL is required")
    def test_only_matching_inventory_resolves_an_uncertain_request(self):
        def der(key):
            # macOS OpenSSL 3 cannot reliably reopen /dev/stdin while loading
            # an RSA private key. A private, owner-only fixture also works with
            # the system OpenSSL and does not depend on a shell pipe.
            with tempfile.NamedTemporaryFile(mode="wb", prefix="zag-test-rsa-", suffix=".pem") as key_file:
                key_file.write(key)
                key_file.flush()
                return subprocess.check_output(
                    ["openssl", "req", "-new", "-x509", "-key", key_file.name,
                     "-subj", "/CN=Test", "-days", "1", "-outform", "DER"],
                    stderr=subprocess.DEVNULL)

        values = {}
        store = Mock()
        store.read.side_effect = values.get
        store.write.side_effect = values.__setitem__
        approve = Mock(return_value="CREATE")
        identity = desktop.Identity(store, "authenticated-account", TEAM, "openssl", approve)
        request = identity.select([])
        self.assertIn("BEGIN CERTIFICATE REQUEST", request["csr"])
        self.assertEqual(store.read(identity.pending_item), b"pending")
        other_key = subprocess.check_output(
            ["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048"],
            stderr=subprocess.DEVNULL)
        other = base64.b64encode(der(other_key))
        own = base64.b64encode(der(identity.key))
        restarted = desktop.Identity(store, "authenticated-account", TEAM, "openssl", approve)
        with self.assertRaisesRegex(ValueError, "unresolved"):
            restarted.select([other])
        with self.assertRaisesRegex(ValueError, "does not match"):
            restarted.bind(other)
        self.assertEqual(restarted.select([other, own]), {"index": 1})
        self.assertTrue(restarted.bind(own))
        self.assertEqual(store.read(identity.pending_item), b"")
        other_account = desktop.Identity(store, "different-account", TEAM, "openssl", approve)
        self.assertIsNone(other_account.key)
        approve.assert_called_once()


class CredentialLifecycleTests(unittest.TestCase):
    def portal(self, replies):
        from ui_protocol import Channel
        wire = b"".join((json.dumps({"value": value}) + "\n").encode()
                        for value in replies)
        output = io.BytesIO()
        channel = Channel(input_stream=io.BytesIO(wire), event_stream=output,
                          isolate_output=False)
        portal = desktop.Provisioning(None, "test-device", Mock(), "openssl",
                                      Mock(), channel.ask, native_helper="helper")
        return portal, output

    def test_combined_password_consumed_once_then_secure_retry(self):
        portal, output = self.portal([
            json.dumps({"email": "test@example.com", "password": "first-secret"}),
            "retry-secret",
        ])
        self.assertEqual(portal.handle({"event": "configuration"})["email"],
                         "test@example.com")
        self.assertEqual(portal.handle({"event": "password"}), "first-secret")
        self.assertIsNone(portal._pending_password)
        self.assertEqual(portal.handle({"event": "password"}), "retry-secret")
        events = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([e["message"] for e in events],
                         ["Apple ID credentials: ", "Apple ID password: "])
        self.assertTrue(all(e["secure"] for e in events))
        self.assertNotIn(b"secret", output.getvalue())

    def test_provisioning_exception_clears_pending_password(self):
        portal, _ = self.portal([
            json.dumps({"email": "test@example.com", "password": "first-secret"}),
        ])
        child = Mock()
        child.stdout = iter(['{"event":"configuration"}', '{"event":"invalid"}'])
        child.poll.return_value = None
        from unittest.mock import MagicMock
        context = MagicMock()
        context.__enter__.return_value = child
        with patch.object(desktop.subprocess, "Popen", return_value=context):
            with self.assertRaisesRegex(ValueError, "Missing authenticated signing identity"):
                portal.run("unused-helper")
        self.assertIsNone(portal._pending_password)
        child.kill.assert_called_once()

    def test_launch_failure_clears_previous_password(self):
        portal, _ = self.portal([])
        portal._pending_password = "stale-secret"
        with patch.object(desktop.subprocess, "Popen", side_effect=OSError("launch failed")):
            with self.assertRaises(OSError):
                portal.run("unused-helper")
        self.assertIsNone(portal._pending_password)


class DesktopTests(unittest.TestCase):
    def test_imported_provisioning_is_native_fresh_and_isolated(self):
        import ipa_preview
        with self.assertRaises(ValueError):
            desktop.Provisioning(None, "udid", Mock(), "openssl", Mock(), Mock(),
                                 imported_bundle="com.example.app")
        with self.assertRaises(ValueError):
            desktop.Provisioning(None, "udid", Mock(), "openssl", Mock(), Mock(),
                                 native_helper="native", imported_bundle="app.zagstore.ios")
        with self.assertRaises(ValueError):
            desktop.Provisioning(None, "udid", Mock(), "openssl", Mock(), Mock(),
                                 native_helper="native", upgrade=True, imported_bundle="com.example.app")
        store = Mock()
        store.read.return_value = None  # No prior signing key: keep this a read-only isolation test.
        portal = desktop.Provisioning(None, "udid", store, "openssl", lambda _: TEAM,
                                      lambda _: "test@example.com", native_helper="native",
                                      imported_bundle="com.example.app")
        config = portal.handle({"event": "configuration"})
        self.assertEqual(config["imported_prefix"] + "." + TEAM,
                         ipa_preview.mapped_import_bundle("com.example.app", TEAM))
        self.assertEqual(config["suffixes"], [""])
        self.assertNotIn("account_bootstrap", config)
        portal.handle({"event": "team", "account": "test-account", "teams": []})
        self.assertNotEqual(portal.receipt_item, desktop.scope("installed-leaf", "udid", TEAM))


    def test_bundled_profile_root_matches_existing_pin(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "apple-root.pem"
            desktop.prepare_profile_root(installer.artifact, installer.ROOT, root)
            der = base64.b64decode("".join(root.read_text().splitlines()[1:-1]), validate=True)
            import hashlib
            self.assertEqual(hashlib.sha256(der).hexdigest(), installer.artifact.APPLE_ROOT)

    def test_provider_origin_requires_verified_https_origin(self):
        self.assertEqual(desktop.provider_origin("https://ani.example/"), "https://ani.example")
        for bad in ("", "http://ani.example", "https://user:password@ani.example",
                    "https://ani.example:443", "https://ani.example/v3", "https://ani.example/?q=x"):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                desktop.provider_origin(bad)

    def test_native_provision_requires_consent_and_reuses_account_state_offline(self):
        store = Mock()
        store.read.return_value = None
        approve = Mock(side_effect=["no", "ANISETTE"])
        native = desktop.NativeAnisette("helper", store, approve)
        native.item = desktop.scope("native", "one-account")
        with patch.object(desktop, "command") as command:
            with self.assertRaisesRegex(ValueError, "cancelled"):
                native.headers(prepare=True)
            command.assert_not_called()
            command.side_effect = [b'{"state":"c3RhdGU=","headers":{"source":"new"}}',
                                   b'{"headers":{"source":"offline"}}']
            self.assertEqual(native.headers(prepare=True), {"source": "new"})
            self.assertEqual(native.headers(prepare=False), {"source": "offline"})
            self.assertEqual(command.call_args.args[:2], (["helper", "headers"], b"state"))
        store.write.assert_called_once_with(native.item, b"state")

    def test_remote_selection_requires_explicit_approval_before_provider_exchange(self):
        portal = desktop.Provisioning("https://ani.example", "udid", Mock(), "openssl", Mock(),
                                      Mock(side_effect=["apple@example.invalid", "no"]))
        with self.assertRaisesRegex(ValueError, "cancelled"):
            portal.handle({"event": "configuration"})
        self.assertIsNone(portal.anisette_scope)

    def test_account_candidate_requires_explicit_native_opt_in_and_matching_account(self):
        import json
        store = Mock()
        store.read.return_value = None
        portal = desktop.Provisioning(None, "udid", store, "openssl", lambda _: TEAM,
                                      Mock(return_value="apple@example.invalid"), "native")
        event = {"event": "account_bootstrap", "credential": {
            "accountID": "12345", "token": "synthetic",
            "expiresAtMs": int((dt.datetime.now(dt.timezone.utc).timestamp() + 300) * 1000)}}
        self.assertNotIn("account_bootstrap", portal.handle({"event": "configuration"}))
        with self.assertRaisesRegex(ValueError, "Unexpected account"):
            portal.handle(event)
        portal.account_bootstrap = True
        self.assertTrue(portal.handle({"event": "configuration"})["account_bootstrap"])
        portal.handle({"event": "team", "account": "12345", "teams": [{"id": TEAM}]})
        with self.assertRaisesRegex(ValueError, "Invalid portable"):
            portal.handle({**event, "credential": {**event["credential"], "accountID": "67890"}})
        self.assertTrue(portal.handle(event))
        self.assertEqual(json.loads(portal.account_credential)["token"], event["credential"])
        store.write.assert_not_called()
        with self.assertRaisesRegex(ValueError, "Unexpected account"):
            portal.handle(event)

    def test_portable_apple_token_is_opaque_not_restricted_to_ascii_graphics(self):
        import json
        store = Mock()
        store.read.return_value = None
        portal = desktop.Provisioning(None, "udid", store, "openssl", lambda _: TEAM,
                                      Mock(return_value="apple@example.invalid"), "native")
        portal.account_bootstrap = True
        portal.handle({"event": "configuration"})
        portal.handle({"event": "team", "account": "12345", "teams": [{"id": TEAM}]})
        # Opaque Apple tokens may contain non-ASCII data or spaces. Do not
        # enforce a speculative alphabet; the bound identity and live Apple
        # service verification are authoritative.
        event = {"event": "account_bootstrap", "credential": {
            "accountID": "12345", "token": "test token · \\u00e9",
            "expiresAtMs": int((dt.datetime.now(dt.timezone.utc).timestamp() + 300) * 1000)}}
        self.assertTrue(portal.handle(event))
        self.assertEqual(json.loads(portal.account_credential)["token"]["token"], event["credential"]["token"])
        store.write.assert_not_called()

    def test_local_account_bootstrap_refuses_non_native_or_same_build(self):
        with patch.object(installer, "stage_local_candidate") as stage:
            with self.assertRaisesRegex(ValueError, "newer local candidate"):
                installer.upgrade_local_candidate(Path("candidate.ipa"), "a" * 64, "1.0.0", "6",
                    None, Path("."), Mock(), Mock(), account_bootstrap_dev=True)
            stage.assert_not_called()

    def test_unknown_second_factor_requires_a_delivery_method(self):
        event = {"retry": False, "unknown": True, "sms": False,
                 "numbers": [{"id": 77, "last_two": "12"}]}
        with patch.object(desktop, "secret") as secret_input:
            self.assertEqual(desktop.two_factor(event, lambda _: "c"), {"action": "abort"})
            self.assertEqual(desktop.two_factor(event, lambda _: "1"), {"action": "sms", "id": 77})
            secret_input.assert_not_called()
        event["unknown"] = False
        with patch.object(desktop, "secret", return_value="012345"):
            self.assertEqual(desktop.two_factor(event, lambda _: "c"),
                             {"action": "code", "code": "012345"})

    def test_profile_must_cover_exact_app_device_key_and_entitlements(self):
        identifier = f"{TEAM}.{BUNDLE}"
        profile = {
            "LocalProvision": True, "TeamIdentifier": [TEAM],
            "DeveloperCertificates": [b"certificate"], "ProvisionedDevices": ["udid"],
            "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
            "Entitlements": {"application-identifier": identifier,
                             "com.apple.developer.team-identifier": TEAM, "get-task-allow": True,
                             "keychain-access-groups": [f"{TEAM}.*"]},
        }
        check = desktop.personal_entitlements
        self.assertEqual(check(installer.artifact, profile, b"certificate", TEAM, "UDID")
                         ["keychain-access-groups"], [identifier])
        for change in ({"LocalProvision": False}, {"TeamIdentifier": ["wrong"]},
                       {"ProvisionedDevices": ["wrong"]}, {"DeveloperCertificates": [b"wrong"]},
                       {"Entitlements": {"application-identifier": identifier}}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                check(installer.artifact, {**profile, **change}, b"certificate", TEAM, "udid")

    def test_occupied_destination_blocks_before_any_portal_mutation(self):
        with tempfile.TemporaryDirectory() as folder:
            scratch = Path(folder)
            source = scratch / "input.ipa"
            with zipfile.ZipFile(source, "w") as archive:
                archive.writestr("Payload/Zag.app/Info.plist", plistlib.dumps({
                    "CFBundleIdentifier": installer.artifact.ORIGINAL,
                }))
            root = scratch / "root.pem"
            root.write_text("mock certificate")
            device = Mock()
            device.usb_device.return_value = ("device", "udid")
            device.apps.return_value = [{"bundleIdentifier": BUNDLE}]

            def run_portal(portal, _):
                portal.handle({"event": "team", "account": "account",
                               "teams": [{"id": TEAM, "name": "Personal Team"}]})
                self.fail("occupied destination was authorized")

            cache = Mock()
            cache.installer_tools.return_value = ("auth", "signer", "openssl", None)
            def acquire(_, _release, _helper, destination):
                shutil.copyfile(source, destination)

            with patch.object(installer.releases, "acquire", side_effect=acquire), \
                 patch.object(desktop, "prepare_profile_root"), patch.object(desktop.Provisioning, "run", run_portal), \
                 patch.object(desktop, "sign") as sign:
                with self.assertRaisesRegex(ValueError, "already installed"):
                    installer.install_release(RELEASE, "release-helper", root, "https://ani.example", None, scratch, device, cache,
                                              approve=lambda _: "1")
                device.install.assert_not_called()
                sign.assert_not_called()

    def test_signing_validation_failure_prevents_installation(self):
        device = Mock()
        with patch.object(installer.artifact, "validate", side_effect=ValueError("invalid signature")):
            with self.assertRaisesRegex(ValueError, "invalid signature"):
                installer.validate_and_install(Path("signed"), RELEASE, TEAM, Path("root"), Path("."), device,
                                               "target", "udid", Mock(), b"leaf")
        device.install.assert_not_called()

    def test_upgrade_refuses_to_create_a_new_certificate(self):
        store = Mock()
        store.read.return_value = None
        approve = Mock()
        identity = desktop.Identity(store, "account", TEAM, "openssl", approve, upgrade=True)
        with self.assertRaisesRegex(ValueError, "existing local signing key"):
            identity.select([])
        approve.assert_not_called()
        store.write.assert_not_called()

    def test_extensions_keep_their_identifier_suffix(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder)
            extension = app / "PlugIns/Widget.appex"
            extension.mkdir(parents=True)
            info = extension / "Info.plist"
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "app.zagstore.ios.widgets.home"}))
            self.assertEqual(desktop.signing_components(app, "app.zagstore.ios"),
                             {"": "", "PlugIns/Widget.appex": ".widgets.home"})
            info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "another.app.widget"}))
            with self.assertRaisesRegex(ValueError, "does not belong"):
                desktop.signing_components(app, "app.zagstore.ios")


class PrecompiledHelpersTests(unittest.TestCase):
    def create_inventory(self, folder):
        root = Path(folder)
        (root / "lib").mkdir()
        for name in ("release", "handoff", "zag_desktop", "zag-desktop-signer",
                     "zag-desktop-anisette", "openssl"):
            path = root / name
            path.write_bytes(b"test helper fixture")
            path.chmod(0o700)
        for name in ("libssl.3.dylib", "libcrypto.3.dylib"):
            (root / "lib" / name).write_bytes(b"test library fixture")
        return root

    def test_missing_helpers_fail_closed(self):
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "Required precompiled helper"):
                desktop.PrecompiledCache(folder)

    def test_precompiled_adapter_reuses_exact_binaries(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.create_inventory(folder)
            adapter = desktop.PrecompiledCache(root)
            canonical = root.resolve()
            self.assertEqual(adapter.build_swift("release", []), canonical / "release")
            self.assertEqual(adapter.build_swift("handoff", []), canonical / "handoff")
            self.assertEqual(adapter.signer_tools(None),
                             (canonical / "zag-desktop-signer", canonical / "openssl"))
            self.assertEqual(adapter.installer_tools(None, native=True),
                             (canonical / "zag_desktop", canonical / "zag-desktop-signer",
                              canonical / "openssl", canonical / "zag-desktop-anisette"))
            with self.assertRaisesRegex(ValueError, "Unknown precompiled"):
                adapter.build_swift("unexpected", [])

    def test_writable_or_symlinked_executable_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.create_inventory(folder)
            (root / "openssl").chmod(0o777)
            with self.assertRaisesRegex(ValueError, "insecure ownership or permissions"):
                desktop.PrecompiledCache(root)
            (root / "openssl").unlink()
            (root / "openssl").symlink_to(root / "release")
            with self.assertRaisesRegex(ValueError, "Required precompiled helper"):
                desktop.PrecompiledCache(root)

    def test_missing_library_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            root = self.create_inventory(folder)
            (root / "lib" / "libcrypto.3.dylib").unlink()
            with self.assertRaisesRegex(ValueError, "Missing packaged OpenSSL dependency"):
                desktop.PrecompiledCache(root)

