import os
import uuid
import shutil
import asyncio
import tempfile
import subprocess
import zipfile
import plistlib
import requests
from contextlib import asynccontextmanager
from typing import Optional
from pathlib import Path
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

import aiofiles
from fastapi import FastAPI, UploadFile, File, Form, HTTPException, BackgroundTasks, Request
from fastapi.responses import FileResponse, JSONResponse, Response, HTMLResponse
from fastapi.middleware.cors import CORSMiddleware

# ── Config ──────────────────────────────────────────────────────────────────
WORK_DIR      = "/tmp/ipa_jobs"
ZSIGN_BIN     = "/usr/local/bin/zsign"
BASE_URL      = os.getenv("BASE_URL", "").rstrip("/")
P12_PATH      = os.getenv("P12_PATH", "/run/secrets/cert.p12")
P12_PASSWORD  = os.getenv("P12_PASSWORD", "")
PROV_PATH     = os.getenv("PROV_PATH", "/run/secrets/app.mobileprovision")

os.makedirs(WORK_DIR, exist_ok=True)

# In-memory job store
jobs: dict = {}
executor = ThreadPoolExecutor(max_workers=4)

# ── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="IPA Signing Server",
    description="Fast IPA signing server — AppDB-style",
    version="2.0.0",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Helpers ───────────────────────────────────────────────────────────────────

def job_dir(job_id: str) -> str:
    path = os.path.join(WORK_DIR, job_id)
    os.makedirs(path, exist_ok=True)
    return path

def _do_sign_job(job_id: str, ipa_path: str, bundle_id: Optional[str], app_name: Optional[str]):
    """
    Blocking signing worker — runs in threadpool.
    Uses pre-configured P12 + provisioning profile (AppDB-style).
    """
    jdir = job_dir(job_id)

    try:
        # 1. Validate signing credentials
        jobs[job_id]["status"] = "checking_credentials"

        p12_path  = P12_PATH
        prov_path = PROV_PATH

        # Support credentials uploaded via env-base64 or mounted files
        p12_b64  = os.getenv("P12_BASE64")
        prov_b64 = os.getenv("PROV_BASE64")

        if p12_b64:
            import base64
            p12_path  = os.path.join(jdir, "cert.p12")
            prov_path = os.path.join(jdir, "app.mobileprovision")
            with open(p12_path, "wb")  as f: f.write(base64.b64decode(p12_b64))
        if prov_b64:
            import base64
            prov_path = os.path.join(jdir, "app.mobileprovision")
            with open(prov_path, "wb") as f: f.write(base64.b64decode(prov_b64))

        if not os.path.exists(p12_path):
            raise RuntimeError("P12 certificate not configured. Set P12_BASE64 env var.")
        if not os.path.exists(prov_path):
            raise RuntimeError("Provisioning profile not configured. Set PROV_BASE64 env var.")

        # 2. Read app info from IPA
        jobs[job_id]["status"] = "reading_ipa"
        info_bundle_id, info_app_name = _get_app_info(ipa_path)
        final_bundle_id = bundle_id or info_bundle_id
        final_app_name  = app_name or info_app_name

        # 3. Sign IPA with zsign (fast — under 30 seconds for normal IPAs)
        jobs[job_id]["status"] = "signing"
        signed_path = os.path.join(jdir, "signed.ipa")

        cmd = [
            ZSIGN_BIN,
            "-k", p12_path,
            "-p", P12_PASSWORD,
            "-m", prov_path,
            "-o", signed_path,
            "-z", "8",
            "-f",           # force re-sign
        ]
        if bundle_id:
            cmd += ["-b", bundle_id]
        if app_name:
            cmd += ["-n", app_name]
        cmd.append(ipa_path)

        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)

        if result.returncode != 0 or not os.path.exists(signed_path):
            err = result.stderr or result.stdout or "zsign returned non-zero exit"
            raise RuntimeError(f"Signing failed: {err[:500]}")

        # 4. Generate itms-services manifest
        jobs[job_id]["status"] = "generating_manifest"
        ipa_url      = f"{BASE_URL}/download/{job_id}/signed.ipa"
        manifest     = _make_manifest(ipa_url, final_bundle_id, final_app_name)
        manifest_path = os.path.join(jdir, "manifest.plist")
        with open(manifest_path, "w") as f:
            f.write(manifest)

        install_url = f"itms-services://?action=download-manifest&url={BASE_URL}/manifest/{job_id}.plist"

        jobs[job_id] = {
            "status":     "done",
            "error":      None,
            "bundle_id":  final_bundle_id,
            "app_name":   final_app_name,
            "install_url": install_url,
        }

    except Exception as e:
        jobs[job_id] = {"status": "failed", "error": str(e)}


def _get_app_info(ipa_path: str):
    with zipfile.ZipFile(ipa_path, "r") as zf:
        for name in zf.namelist():
            if name.count("/") == 2 and name.endswith("/Info.plist") and "Payload/" in name:
                with zf.open(name) as f:
                    data = plistlib.load(f)
                return (
                    data.get("CFBundleIdentifier", "com.unknown"),
                    data.get("CFBundleName", data.get("CFBundleExecutable", "App")),
                )
    return "com.unknown", "App"


def _make_manifest(ipa_url: str, bundle_id: str, app_name: str) -> str:
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
    creds_ok = bool(os.getenv("P12_BASE64")) and bool(os.getenv("PROV_BASE64"))
    return {
        "service":     "IPA Signing Server v2",
        "status":      "running",
        "credentials": "configured" if creds_ok else "NOT configured — set P12_BASE64 and PROV_BASE64",
        "base_url":    BASE_URL or "NOT SET — set BASE_URL env var",
    }

@app.get("/health")
def health():
    return {"status": "ok"}


# ── UDID Auto-Detect ──────────────────────────────────────────────────────────

udid_sessions: dict = {}

@app.get("/udid/start")
def udid_start():
    session_id  = str(uuid.uuid4())
    udid_sessions[session_id] = {"udid": None, "created_at": datetime.utcnow()}
    profile_url = f"{BASE_URL}/udid/profile/{session_id}"
    return {"session_id": session_id, "profile_url": profile_url}

@app.get("/udid/profile/{session_id}")
def udid_profile(session_id: str):
    if session_id not in udid_sessions:
        raise HTTPException(404, "Session not found")
    capture_url  = f"{BASE_URL}/udid/capture/{session_id}"
    profile_uuid = str(uuid.uuid4()).upper()
    mobileconfig = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>PayloadContent</key>
    <array>
        <dict>
            <key>PayloadType</key><string>Profile Service</string>
            <key>PayloadVersion</key><integer>1</integer>
            <key>PayloadIdentifier</key><string>com.ipainstaller.udid.{session_id}</string>
            <key>PayloadUUID</key><string>{profile_uuid}</string>
            <key>PayloadDisplayName</key><string>IPA Installer UDID</string>
            <key>PayloadDescription</key><string>Used to detect your device UDID for app signing.</string>
            <key>URL</key><string>{capture_url}</string>
        </dict>
    </array>
    <key>PayloadDisplayName</key><string>IPA Installer</string>
    <key>PayloadIdentifier</key><string>com.ipainstaller.udid</string>
    <key>PayloadRemovalDisallowed</key><false/>
    <key>PayloadType</key><string>Configuration</string>
    <key>PayloadUUID</key><string>{str(uuid.uuid4()).upper()}</string>
    <key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>"""
    return Response(
        content=mobileconfig,
        media_type="application/x-apple-aspen-config",
        headers={"Content-Disposition": 'attachment; filename="udid-detect.mobileconfig"'},
    )

@app.post("/udid/capture/{session_id}")
async def udid_capture(session_id: str, request: Request):
    if session_id not in udid_sessions:
        raise HTTPException(404, "Session not found")
    body = await request.body()
    udid = None
    try:
        plist = plistlib.loads(body)
        udid  = plist.get("UDID") or plist.get("udid") or plist.get("DeviceUDID")
    except Exception:
        import re
        m = re.search(r"[0-9a-fA-F-]{25,}", body.decode("utf-8", errors="ignore"))
        if m: udid = m.group(0)
    if udid:
        udid_sessions[session_id]["udid"] = udid.lower()
    empty = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict></dict></plist>"""
    return Response(content=empty, media_type="application/x-apple-aspen-config")

@app.get("/udid/get/{session_id}")
def udid_get(session_id: str):
    if session_id not in udid_sessions:
        raise HTTPException(404, "Session not found")
    from datetime import timedelta
    session = udid_sessions[session_id]
    if datetime.utcnow() - session["created_at"] > timedelta(minutes=10):
        del udid_sessions[session_id]
        raise HTTPException(410, "Session expired")
    udid = session.get("udid")
    return {"udid": udid, "ready": udid is not None}


# ── Sign endpoint ─────────────────────────────────────────────────────────────

@app.post("/sign")
async def sign_ipa(
    background_tasks: BackgroundTasks,
    ipa: UploadFile = File(...),
    udid: str = Form(...),
    bundle_id: Optional[str] = Form(None),
    app_name: Optional[str] = Form(None),
    # Apple ID fields kept for compatibility but ignored in v2
    apple_id: Optional[str] = Form(None),
    password: Optional[str] = Form(None),
):
    job_id = str(uuid.uuid4())
    jdir   = job_dir(job_id)
    ipa_path = os.path.join(jdir, "input.ipa")

    async with aiofiles.open(ipa_path, "wb") as f:
        content = await ipa.read()
        await f.write(content)

    jobs[job_id] = {"status": "queued", "error": None}

    # Run blocking signing in threadpool — won't freeze FastAPI
    loop = asyncio.get_event_loop()
    loop.run_in_executor(
        executor,
        _do_sign_job,
        job_id, ipa_path, bundle_id or None, app_name or None
    )

    return JSONResponse({"job_id": job_id, "status": "queued"})


@app.get("/status/{job_id}")
def get_status(job_id: str):
    if job_id not in jobs:
        raise HTTPException(404, "Job not found")
    return jobs[job_id]

@app.get("/manifest/{job_id}.plist")
def get_manifest(job_id: str):
    path = os.path.join(job_dir(job_id), "manifest.plist")
    if not os.path.exists(path):
        raise HTTPException(404, "Manifest not found")
    return FileResponse(path, media_type="text/xml")

@app.get("/download/{job_id}/signed.ipa")
def download_signed_ipa(job_id: str):
    path = os.path.join(job_dir(job_id), "signed.ipa")
    if not os.path.exists(path):
        raise HTTPException(404, "Signed IPA not found")
    return FileResponse(path, media_type="application/octet-stream", filename="signed.ipa")
