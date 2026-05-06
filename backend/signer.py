import os
import subprocess
import zipfile
import shutil
import plistlib
import tempfile
from pathlib import Path
from typing import Optional, Tuple

ZSIGN_BIN = "/usr/local/bin/zsign"

class SigningError(Exception):
    pass

class IPASigner:

    def sign(
        self,
        ipa_path: str,
        p12_path: str,
        p12_password: str,
        provision_path: str,
        output_path: str,
        bundle_id: Optional[str] = None,
        app_name: Optional[str] = None,
    ) -> str:
        """
        Sign an IPA using zsign.
        Optionally override bundle ID and app name in Info.plist before signing.
        Returns output_path on success.
        """
        # 1. Extract IPA to temp dir
        with tempfile.TemporaryDirectory() as tmpdir:
            extract_dir = os.path.join(tmpdir, "extracted")
            os.makedirs(extract_dir)
            
            with zipfile.ZipFile(ipa_path, 'r') as zf:
                zf.extractall(extract_dir)
            
            # 2. Find .app directory
            payload_dir = os.path.join(extract_dir, "Payload")
            if not os.path.isdir(payload_dir):
                raise SigningError("Invalid IPA: no Payload directory found")
            
            app_dirs = [d for d in os.listdir(payload_dir) if d.endswith(".app")]
            if not app_dirs:
                raise SigningError("Invalid IPA: no .app bundle found in Payload")
            
            app_dir = os.path.join(payload_dir, app_dirs[0])
            
            # 3. Read and optionally modify Info.plist
            plist_path = os.path.join(app_dir, "Info.plist")
            with open(plist_path, "rb") as f:
                plist_data = plistlib.load(f)
            
            modified = False
            if bundle_id:
                plist_data["CFBundleIdentifier"] = bundle_id
                modified = True
            if app_name:
                plist_data["CFBundleName"] = app_name
                plist_data["CFBundleDisplayName"] = app_name
                modified = True
            
            if modified:
                with open(plist_path, "wb") as f:
                    plistlib.dump(plist_data, f)
            
            actual_bundle_id = plist_data.get("CFBundleIdentifier", "com.unknown.app")
            actual_app_name = plist_data.get("CFBundleName", plist_data.get("CFBundleExecutable", "App"))
            
            # 4. Replace embedded.mobileprovision
            embedded_path = os.path.join(app_dir, "embedded.mobileprovision")
            shutil.copy2(provision_path, embedded_path)
            
            # 5. Run zsign
            cmd = [
                ZSIGN_BIN,
                "-k", p12_path,
                "-p", p12_password,
                "-m", provision_path,
                "-o", output_path,
                "-z", "9",  # max compression
                os.path.join(extract_dir),
            ]
            
            # zsign can sign a directory directly
            cmd_alt = [
                ZSIGN_BIN,
                "-k", p12_path,
                "-p", p12_password,
                "-m", provision_path,
                "-o", output_path,
                "-z", "9",
                app_dir,
            ]
            
            result = subprocess.run(
                cmd_alt,
                capture_output=True,
                text=True,
                timeout=120,
            )
            
            if result.returncode != 0:
                # Try alternative: repack manually then sign
                repacked = os.path.join(tmpdir, "repacked.ipa")
                with zipfile.ZipFile(repacked, 'w', zipfile.ZIP_DEFLATED) as zf:
                    for root, dirs, files in os.walk(extract_dir):
                        for file in files:
                            file_path = os.path.join(root, file)
                            arcname = os.path.relpath(file_path, extract_dir)
                            zf.write(file_path, arcname)
                
                cmd_ipa = [
                    ZSIGN_BIN,
                    "-k", p12_path,
                    "-p", p12_password,
                    "-m", provision_path,
                    "-o", output_path,
                    "-z", "9",
                    repacked,
                ]
                result2 = subprocess.run(
                    cmd_ipa,
                    capture_output=True,
                    text=True,
                    timeout=120,
                )
                
                if result2.returncode != 0:
                    raise SigningError(f"zsign failed:\nstdout: {result2.stdout}\nstderr: {result2.stderr}")
            
            if not os.path.exists(output_path):
                raise SigningError("zsign did not produce output file")
            
            return actual_bundle_id, actual_app_name

    def get_app_info(self, ipa_path: str) -> Tuple[str, str]:
        """Extract Bundle ID and App Name from an IPA without signing"""
        with zipfile.ZipFile(ipa_path, 'r') as zf:
            for name in zf.namelist():
                if name.count('/') == 2 and name.endswith('/Info.plist') and 'Payload/' in name:
                    with zf.open(name) as f:
                        plist_data = plistlib.load(f)
                    bundle_id = plist_data.get("CFBundleIdentifier", "com.unknown")
                    app_name = plist_data.get("CFBundleName", plist_data.get("CFBundleExecutable", "App"))
                    return bundle_id, app_name
        raise SigningError("Could not find Info.plist in IPA")
