import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cloudkit_signing as signing


class CloudKitSigningTests(unittest.TestCase):
    def setUp(self):
        self.container = "iCloud.org.example.gamebox"
        self.app_id = "TEAM000001.org.example.gamebox"
        self.info = {"CFBundleIdentifier": "org.example.gamebox"}
        self.profile = {
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
            "Entitlements": {
                "application-identifier": self.app_id,
                signing.CONTAINERS: [self.container],
                signing.SERVICES: "*",
                signing.ENVIRONMENT: ["Development", "Production"],
            },
        }

    def configure(self, container=None):
        return signing.configure(self.profile, self.info, {"get-task-allow": True},
                                 self.app_id, container or self.container, "Development")

    def test_apple_development_profile_grants_all_services(self):
        info, entitlements = self.configure()
        self.assertEqual(info["DMCloudSaveContainer"], self.container)
        self.assertEqual(entitlements[signing.SERVICES], ["CloudKit"])
        self.assertEqual(entitlements[signing.ENVIRONMENT], "Development")
        self.assertTrue(entitlements["get-task-allow"])

    def test_wildcard_does_not_authorize_a_different_container(self):
        with self.assertRaisesRegex(ValueError, "does not authorize CloudKit"):
            self.configure("iCloud.org.example.other")

    def test_same_bundle_on_different_team_is_not_an_in_place_upgrade(self):
        self.profile["Entitlements"]["application-identifier"] = "TEAM000002.org.example.gamebox"
        with self.assertRaisesRegex(ValueError, "exact existing app identifier"):
            self.configure()
