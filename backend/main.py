import os
import uuid
import shutil
import asyncio
import tempfile
from contextlib import asynccontextmanager
from typing import Optional
from pathlib import Path
from datetime import datetime, timedelta

import aiofiles
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, BackgroundTasks, Request
from fastapi.responses import FileResponse, JSONResponse, Response, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware

from apple_auth import AppleAuth, AppleAuthError, TwoFactorRequired
from signer import IPASigner, SigningError
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

# ── Config ──────────────────────────────────────────────────────────────────
WORK_DIR = "/tmp/ipa_jobs"
ANISETTE_URL = os.getenv("ANISETTE_URL", "http://localhost:6969")
BASE_URL = os.getenv("BASE_URL", "http://localhost:8000")  # Set this to your Railway URL
os.makedirs(WORK_DIR, exist_ok=True)

# In-memory job store (use Redis in production)
jobs: dict = {}

# In-memory UDID session store: {session_id: {"udid": str|None, "created_at": datetime}}
udid_sessions: dict = {}

# ── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="IPA Signing Server",
    description="Sign IPA files using Apple ID – no P12 needed from user",
    version="1.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

signer = IPASigner()

# ── Helper ────────────────────────────────────────────────────────────────────
def job_dir(job_id: str) -> str:
    path = os.path.join(WORK_DIR, job_id)
    os.makedirs(path, exist_ok=True)
    return path

def generate_private_key() -> tuple[str, str]:
    """Generate RSA private key and return (private_pem, public_pem)"""
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.TraditionalOpenSSL,
        serialization.NoEncryption(),
    ).decode()
    return private_pem

async def do_signing_job(
    job_id: str,
    ipa_path: str,
    apple_id: str,
    password: str,
    udid: str,
    bundle_id: Optional[str],
    app_name: Optional[str],
):
    """Background task: authenticate, sign, and store result"""
    jdir = job_dir(job_id)
    jobs[job_id] = {"status": "authenticating", "error": None}

    try:
        # 1. Authenticate with Apple
        auth = AppleAuth(apple_id, password, ANISETTE_URL)
        auth.authenticate()
        jobs[job_id]["status"] = "fetching_certificate"

        # 2. Generate private key
        private_key_pem = generate_private_key()
        key_path = os.path.join(jdir, "key.pem")
        with open(key_path, "w") as f:
            f.write(private_key_pem)

        # 3. Get/create development certificate
        cert_der = auth.get_or_create_certificate(private_key_pem)
        cert_path = os.path.join(jdir, "cert.der")
        with open(cert_path, "wb") as f:
            f.write(cert_der)

        # 4. Create P12 from key + cert (needed by zsign)
        from cryptography.hazmat.primitives.serialization.pkcs12 import serialize_key_and_certificates
        from cryptography import x509
        from cryptography.hazmat.primitives.serialization import load_pem_private_key

        private_key = load_pem_private_key(private_key_pem.encode(), password=None)
        cert = x509.load_der_x509_certificate(cert_der)
        p12_password = "signing123"
        p12_bytes = serialize_key_and_certificates(
            name=b"iPhone Developer",
            key=private_key,
            cert=cert,
            cas=None,
            encryption_algorithm=serialization.BestAvailableEncryption(p12_password.encode()),
        )
        p12_path = os.path.join(jdir, "cert.p12")
        with open(p12_path, "wb") as f:
            f.write(p12_bytes)

        jobs[job_id]["status"] = "creating_provision"

        # 5. Get app info from IPA
        info_bundle_id, info_app_name = signer.get_app_info(ipa_path)
        final_bundle_id = bundle_id or info_bundle_id
        final_app_name = app_name or info_app_name

        # 6. Create provisioning profile
        provision_bytes = auth.create_provisioning_profile(
            bundle_id=final_bundle_id,
            app_name=final_app_name,
            udid=udid,
            cert_id="",  # Apple determines from certificate
        )
        provision_path = os.path.join(jdir, "app.mobileprovision")
        with open(provision_path, "wb") as f:
            f.write(provision_bytes)

        jobs[job_id]["status"] = "signing"

        # 7. Sign the IPA
        signed_path = os.path.join(jdir, "signed.ipa")
        actual_bundle_id, actual_app_name = signer.sign(
            ipa_path=ipa_path,
            p12_path=p12_path,
            p12_password=p12_password,
            provision_path=provision_path,
            output_path=signed_path,
            bundle_id=bundle_id,
            app_name=app_name,
        )

        # 8. Generate manifest.plist
        manifest = generate_manifest(
            ipa_url=f"{BASE_URL}/download/{job_id}/signed.ipa",
            bundle_id=actual_bundle_id,
            app_name=actual_app_name,
        )
        manifest_path = os.path.join(jdir, "manifest.plist")
        with open(manifest_path, "w") as f:
            f.write(manifest)

        jobs[job_id] = {
            "status": "done",
            "error": None,
            "bundle_id": actual_bundle_id,
            "app_name": actual_app_name,
            "install_url": f"itms-services://?action=download-manifest&url={BASE_URL}/manifest/{job_id}.plist",
        }

    except TwoFactorRequired as e:
        jobs[job_id] = {
            "status": "2fa_required",
            "error": None,
            "session_id": e.session_id,
            "scnt": e.scnt,
        }
    except (AppleAuthError, SigningError) as e:
        jobs[job_id] = {"status": "failed", "error": str(e)}
    except Exception as e:
        jobs[job_id] = {"status": "failed", "error": f"Unexpected error: {str(e)}"}

def generate_manifest(ipa_url: str, bundle_id: str, app_name: str) -> str:
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>items</key>
    <array>
        <dict>
            <key>assets</key>
            <array>
                <dict>
                    <key>kind</key><string>software-package</string>
                    <key>url</key><string>{ipa_url}</string>
                </dict>
            </array>
            <key>metadata</key>
            <dict>
                <key>bundle-identifier</key><string>{bundle_id}</string>
                <key>bundle-version</key><string>1.0</string>
                <key>kind</key><string>software</string>
                <key>title</key><string>{app_name}</string>
            </dict>
        </dict>
    </array>
</dict>
</plist>"""

# ── Endpoints ─────────────────────────────────────────────────────────────────

@app.get("/")
def root():
    return {"service": "IPA Signing Server", "status": "running"}

@app.get("/health")
def health():
    return {"status": "ok"}


# ── UDID Auto-Detect (Configuration Profile technique) ────────────────────────

@app.get("/udid/start")
def udid_start():
    """
    Buat session baru untuk deteksi UDID.
    App memanggil ini, lalu buka Safari ke /udid/profile/{session_id}
    """
    session_id = str(uuid.uuid4())
    udid_sessions[session_id] = {
        "udid": None,
        "created_at": datetime.utcnow(),
    }
    profile_url = f"{BASE_URL}/udid/profile/{session_id}"
    return {"session_id": session_id, "profile_url": profile_url}


@app.get("/udid/profile/{session_id}")
def udid_profile(session_id: str):
    """
    Serve .mobileconfig yang ketika di-install oleh iOS,
    iOS akan POST UDID device ke /udid/capture/{session_id}
    """
    if session_id not in udid_sessions:
        raise HTTPException(status_code=404, detail="Session tidak ditemukan")

    capture_url = f"{BASE_URL}/udid/capture/{session_id}"
    profile_uuid = str(uuid.uuid4()).upper()

    mobileconfig = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key>
            <string>Profile Service</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
            <key>PayloadIdentifier</key>
            <string>com.ipainstaller.udid.{session_id}</string>
            <key>PayloadUUID</key>
            <string>{profile_uuid}</string>
            <key>PayloadDisplayName</key>
            <string>IPA Installer - Deteksi UDID</string>
            <key>PayloadDescription</key>
            <string>Profil ini digunakan untuk mendeteksi UDID device Anda secara otomatis. Profil akan dihapus setelah UDID terdeteksi.</string>
            <key>URL</key>
            <string>{capture_url}</string>
        </dict>
    </array>
    <key>PayloadDisplayName</key>
    <string>IPA Installer - Deteksi UDID</string>
    <key>PayloadIdentifier</key>
    <string>com.ipainstaller.udid</string>
    <key>PayloadRemovalDisallowed</key>
    <false/>
    <key>PayloadType</key>
    <string>Configuration</string>
    <key>PayloadUUID</key>
    <string>{str(uuid.uuid4()).upper()}</string>
    <key>PayloadVersion</key>
    <integer>1</integer>
</dict>
</plist>"""

    return Response(
        content=mobileconfig,
        media_type="application/x-apple-aspen-config",
        headers={
            "Content-Disposition": f'attachment; filename="udid-detect.mobileconfig"'
        }
    )


@app.post("/udid/capture/{session_id}")
async def udid_capture(session_id: str, request: Request):
    """
    iOS mengirim POST ke sini setelah profil berhasil diverifikasi.
    Body berisi plist dengan UDID device.
    """
    if session_id not in udid_sessions:
        raise HTTPException(status_code=404, detail="Session tidak ditemukan")

    body = await request.body()

    udid = None
    try:
        import plistlib
        plist = plistlib.loads(body)
        # iOS mengirim UDID di key 'UDID'
        udid = plist.get("UDID") or plist.get("udid") or plist.get("DeviceUDID")
    except Exception:
        # Fallback: cari pola UDID (40 karakter hex) di body raw
        import re
        body_str = body.decode("utf-8", errors="ignore")
        match = re.search(r'[0-9a-fA-F]{40}', body_str)
        if match:
            udid = match.group(0)

    if udid:
        udid_sessions[session_id]["udid"] = udid.lower()

    # iOS perlu menerima signed profile untuk melanjutkan — kita return profile kosong
    # Sebenarnya cukup return HTTP 200 dengan plist kosong
    empty_profile = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>"""

    return Response(content=empty_profile, media_type="application/x-apple-aspen-config")


@app.get("/udid/get/{session_id}")
def udid_get(session_id: str):
    """
    App polling endpoint ini sampai UDID tersedia.
    Returns: {"udid": "abc123..."|null, "ready": bool}
    """
    if session_id not in udid_sessions:
        raise HTTPException(status_code=404, detail="Session tidak ditemukan")

    session = udid_sessions[session_id]

    # Hapus session lama (>10 menit)
    age = datetime.utcnow() - session["created_at"]
    if age > timedelta(minutes=10):
        del udid_sessions[session_id]
        raise HTTPException(status_code=410, detail="Session kadaluarsa")

    udid = session.get("udid")
    return {"udid": udid, "ready": udid is not None}

@app.post("/sign")
async def sign_ipa(
    background_tasks: BackgroundTasks,
    ipa: UploadFile = File(...),
    apple_id: str = Form(...),
    password: str = Form(...),
    udid: str = Form(...),
    bundle_id: Optional[str] = Form(None),
    app_name: Optional[str] = Form(None),
):
    """
    Upload an IPA and sign it using Apple ID credentials.
    Returns a job_id to poll for status.
    """
    job_id = str(uuid.uuid4())
    jdir = job_dir(job_id)

    # Save uploaded IPA
    ipa_path = os.path.join(jdir, "input.ipa")
    async with aiofiles.open(ipa_path, "wb") as f:
        content = await ipa.read()
        await f.write(content)

    jobs[job_id] = {"status": "queued", "error": None}

    background_tasks.add_task(
        do_signing_job,
        job_id, ipa_path, apple_id, password, udid,
        bundle_id or None,
        app_name or None,
    )

    return JSONResponse({"job_id": job_id, "status": "queued"})

@app.get("/status/{job_id}")
def get_status(job_id: str):
    """Poll this endpoint to check signing progress"""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
    return jobs[job_id]

@app.post("/verify-2fa/{job_id}")
async def verify_2fa(
    background_tasks: BackgroundTasks,
    job_id: str,
    code: str = Form(...),
):
    """Submit 2FA code when required"""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
    
    job = jobs[job_id]
    if job.get("status") != "2fa_required":
        raise HTTPException(status_code=400, detail="This job does not require 2FA")
    
    # TODO: re-run signing after 2FA
    return {"message": "2FA submitted, re-authentication will proceed"}

@app.get("/manifest/{job_id}.plist")
def get_manifest(job_id: str):
    """Serve the manifest plist for itms-services://"""
    manifest_path = os.path.join(job_dir(job_id), "manifest.plist")
    if not os.path.exists(manifest_path):
        raise HTTPException(status_code=404, detail="Manifest not found")
    return FileResponse(manifest_path, media_type="text/xml")

@app.get("/download/{job_id}/signed.ipa")
def download_signed_ipa(job_id: str):
    """Serve the signed IPA file"""
    ipa_path = os.path.join(job_dir(job_id), "signed.ipa")
    if not os.path.exists(ipa_path):
        raise HTTPException(status_code=404, detail="Signed IPA not found")
    return FileResponse(ipa_path, media_type="application/octet-stream", filename="signed.ipa")
