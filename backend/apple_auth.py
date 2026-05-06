import requests
import hashlib
import json
import base64
import plistlib
import uuid
from typing import Optional, Dict, Any

# Apple's developer service endpoints (same as used by AltStore/Sideloadly)
APPLE_AUTH_URL = "https://idmsa.apple.com/IDMSWebAuth/clientDAW.cgi"
DEV_SERVICES_URL = "https://developerservices2.apple.com/services/QH65B2"
XCODE_VERSION = "11.2"
CLIENT_ID = "XABBG36SBA"

class AppleAuthError(Exception):
    """Raised when Apple authentication fails"""
    pass

class TwoFactorRequired(Exception):
    """Raised when Apple requires 2FA verification"""
    def __init__(self, session_id: str, scnt: str):
        self.session_id = session_id
        self.scnt = scnt
        super().__init__("Two-factor authentication required")

class AppleAuth:
    def __init__(self, apple_id: str, password: str, anisette_url: str = "http://localhost:6969"):
        self.apple_id = apple_id
        self.password = password
        self.anisette_url = anisette_url
        self.session = requests.Session()
        self.auth_token: Optional[str] = None
        self.cookie: Optional[str] = None
        self.team_id: Optional[str] = None

    def _get_anisette_headers(self) -> Dict[str, str]:
        """Fetch anisette data from the local anisette-v3 server"""
        try:
            url = f"{self.anisette_url}/get"
            resp = requests.get(url, timeout=10)
            if resp.status_code == 404:
                url = f"{self.anisette_url}/"
                resp = requests.get(url, timeout=10)
            
            resp.raise_for_status()
            data = resp.json()
            return {
                "X-Apple-I-MD":      data.get("X-Apple-I-MD", ""),
                "X-Apple-I-MD-M":    data.get("X-Apple-I-MD-M", ""),
                "X-Apple-I-MD-RINFO": data.get("X-Apple-I-MD-RINFO", ""),
                "X-Apple-I-MD-LU":   data.get("X-Apple-I-MD-LU", ""),
                "X-Apple-I-SRL-NO":  data.get("X-Apple-I-SRL-NO", ""),
                "X-MMe-Client-Info": data.get("X-MMe-Client-Info", ""),
                "X-Apple-I-TimeZone": data.get("X-Apple-I-TimeZone", "UTC"),
                "X-Apple-Locale":    data.get("X-Apple-Locale", "en_US"),
            }
        except Exception as e:
            raise AppleAuthError(f"Failed to get anisette data: {e}")

    def authenticate(self) -> str:
        """
        Authenticate with Apple ID and return the auth token.
        Raises TwoFactorRequired if 2FA is needed.
        """
        anisette = self._get_anisette_headers()

        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": f"Xcode/{XCODE_VERSION}",
            "Accept": "text/x-xml-plist",
            **anisette,
        }

        data = {
            "appIdKey": CLIENT_ID,
            "appleId": self.apple_id,
            "password": self.password,
            "format": "plist",
            "userLocale": "en_US",
            "protocolVersion": "A1234",
        }

        resp = self.session.post(APPLE_AUTH_URL, data=data, headers=headers, timeout=30)
        
        # Parse plist response
        try:
            plist_data = plistlib.loads(resp.content)
        except Exception:
            raise AppleAuthError("Invalid response from Apple auth server")

        result_code = plist_data.get("resultCode", -1)
        
        if result_code == 0:
            # Success
            self.auth_token = plist_data.get("myacinfo", "")
            self.cookie = f"myacinfo={self.auth_token}"
            return self.auth_token
        elif result_code == -22406:
            # 2FA required
            session_id = resp.headers.get("X-Apple-ID-Session-Id", "")
            scnt = resp.headers.get("scnt", "")
            raise TwoFactorRequired(session_id, scnt)
        else:
            reason = plist_data.get("userString", plist_data.get("resultString", "Unknown error"))
            raise AppleAuthError(f"Authentication failed: {reason}")

    def submit_2fa_code(self, code: str, session_id: str, scnt: str) -> str:
        """Submit 2FA verification code"""
        anisette = self._get_anisette_headers()
        
        headers = {
            "Content-Type": "application/json",
            "User-Agent": f"Xcode/{XCODE_VERSION}",
            "X-Apple-ID-Session-Id": session_id,
            "scnt": scnt,
            "Accept": "application/json",
            **anisette,
        }
        
        resp = self.session.post(
            "https://idmsa.apple.com/appleauth/auth/verify/trusteddevice/securitycode",
            json={"securityCode": {"code": str(code)}},
            headers=headers,
            timeout=30
        )
        
        if resp.status_code == 204:
            # Re-authenticate after 2FA success
            return self.authenticate()
        else:
            raise AppleAuthError(f"2FA verification failed: {resp.text}")

    def _dev_request(self, endpoint: str, params: dict) -> dict:
        """Make an authenticated request to Apple Developer Services"""
        if not self.auth_token:
            raise AppleAuthError("Not authenticated. Call authenticate() first.")
        
        anisette = self._get_anisette_headers()
        headers = {
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": f"Xcode/{XCODE_VERSION}",
            "Accept": "text/x-xml-plist",
            "Cookie": self.cookie,
            **anisette,
        }
        
        params["clientId"] = CLIENT_ID
        params["protocolVersion"] = "A1234"
        params["requestId"] = str(uuid.uuid4()).upper()
        
        resp = self.session.post(
            f"{DEV_SERVICES_URL}/{endpoint}",
            data=params,
            headers=headers,
            timeout=30
        )
        
        try:
            return plistlib.loads(resp.content)
        except Exception:
            raise AppleAuthError(f"Invalid response from dev services: {resp.text[:500]}")

    def get_team_id(self) -> str:
        """Get the team ID associated with the Apple ID"""
        result = self._dev_request("listTeams.action", {})
        teams = result.get("teams", [])
        if not teams:
            raise AppleAuthError("No developer teams found for this Apple ID")
        self.team_id = teams[0].get("teamId", "")
        return self.team_id

    def get_or_create_certificate(self, private_key_pem: str) -> bytes:
        """Get existing certificate or create new one, returns DER bytes"""
        if not self.team_id:
            self.get_team_id()
        
        # List existing certificates
        result = self._dev_request("ios/listAllDevelopmentCerts.action", {
            "teamId": self.team_id,
            "DTDK_Platform": "ios",
        })
        
        certs = result.get("certificates", [])
        for cert in certs:
            if cert.get("status") == "Active" and cert.get("name", "").startswith("iPhone Developer"):
                return base64.b64decode(cert["certContent"])
        
        # Generate CSR from private key
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        import datetime
        
        private_key = serialization.load_pem_private_key(private_key_pem.encode(), password=None)
        
        csr = (
            x509.CertificateSigningRequestBuilder()
            .subject_name(x509.Name([
                x509.NameAttribute(NameOID.COMMON_NAME, "iPhone Developer"),
                x509.NameAttribute(NameOID.EMAIL_ADDRESS, self.apple_id),
            ]))
            .sign(private_key, hashes.SHA256())
        )
        
        csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
        csr_der_b64 = base64.b64encode(csr.public_bytes(serialization.Encoding.DER)).decode()
        
        # Submit CSR to Apple
        result = self._dev_request("ios/submitDevelopmentCSR.action", {
            "teamId": self.team_id,
            "csrContent": csr_der_b64,
            "DTDK_Platform": "ios",
        })
        
        cert_data = result.get("certRequest", {})
        if not cert_data:
            raise AppleAuthError("Failed to create certificate")
        
        return base64.b64decode(cert_data.get("certContent", ""))

    def register_device(self, udid: str, device_name: str = "My iPhone") -> str:
        """Register a device UDID with Apple Developer, returns deviceId"""
        if not self.team_id:
            self.get_team_id()
        
        result = self._dev_request("ios/addDevice.action", {
            "teamId": self.team_id,
            "deviceNumber": udid,
            "name": device_name,
            "DTDK_Platform": "ios",
        })
        
        device = result.get("device", {})
        device_id = device.get("deviceId", "")
        if not device_id:
            # May already be registered, try to list
            list_result = self._dev_request("ios/listDevices.action", {"teamId": self.team_id})
            for dev in list_result.get("devices", []):
                if dev.get("deviceNumber", "").lower() == udid.lower():
                    return dev.get("deviceId", "")
        return device_id

    def get_or_create_app_id(self, bundle_id: str, app_name: str) -> str:
        """Get or create an App ID, returns appIdId"""
        if not self.team_id:
            self.get_team_id()
        
        # List existing app IDs
        result = self._dev_request("ios/listAppIds.action", {"teamId": self.team_id})
        for app_id in result.get("appIds", []):
            if app_id.get("identifier", "") == bundle_id:
                return app_id.get("appIdId", "")
        
        # Create new App ID
        result = self._dev_request("ios/addAppId.action", {
            "teamId": self.team_id,
            "identifier": bundle_id,
            "name": app_name.replace(" ", "_"),
            "DTDK_Platform": "ios",
        })
        
        app_id = result.get("appId", {})
        return app_id.get("appIdId", "")

    def create_provisioning_profile(self, bundle_id: str, app_name: str, udid: str, cert_id: str) -> bytes:
        """Create a provisioning profile and return plist bytes"""
        if not self.team_id:
            self.get_team_id()
        
        app_id_id = self.get_or_create_app_id(bundle_id, app_name)
        device_id = self.register_device(udid)
        
        result = self._dev_request("ios/downloadTeamProvisioningProfile.action", {
            "teamId": self.team_id,
            "appIdId": app_id_id,
            "DTDK_Platform": "ios",
        })
        
        profile_data = result.get("provisioningProfile", {})
        encoded = profile_data.get("encodedProfile", "")
        if not encoded:
            raise AppleAuthError("Failed to create provisioning profile")
        
        return base64.b64decode(encoded)
