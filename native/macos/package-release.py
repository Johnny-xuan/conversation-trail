#!/usr/bin/env python3
"""Build one download: the local-audio installer and an unpacked Chrome extension."""
import base64
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

PROJECT = pathlib.Path(__file__).resolve().parents[2]
NATIVE = PROJECT / "native" / "macos"
DIST = PROJECT / "dist"
HOST_NAME = "com.johnny.conversation_trail_relay"
RELAY_DESTINATION = pathlib.Path("Library/Application Support/Conversation Trail/conversation-trail-relay")


def run(*args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def main():
    if sys.platform != "darwin":
        raise SystemExit("macOS release packages must be built on macOS.")
    manifest = json.loads((PROJECT / "manifest.json").read_text())
    version = manifest["version"]
    digest = hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32]
    extension_id = "".join(chr(ord("a") + int(nibble, 16)) for nibble in digest)
    arch = os.environ.get("LOCAL_AUDIO_ENGINE_ARCH", platform.machine())
    if arch not in ("arm64", "x86_64"):
        raise SystemExit(f"Unsupported macOS architecture: {arch}")
    installer_identity = os.environ.get("CONVERSATION_TRAIL_INSTALLER_IDENTITY")
    notary_profile = os.environ.get("CONVERSATION_TRAIL_NOTARY_PROFILE")
    if notary_profile and (not installer_identity or not os.environ.get("LOCAL_AUDIO_ENGINE_SIGNING_IDENTITY")):
        raise SystemExit("公证需要同时配置 Developer ID Application 和 Developer ID Installer 签名。")

    DIST.mkdir(exist_ok=True)
    run(NATIVE / "build-app.sh")
    run(NATIVE / "build-relay.sh")
    app = DIST / "Local Audio Engine.app"
    relay = DIST / "conversation-trail-relay"
    if notary_profile:
        for binary in (app, relay):
            signature = subprocess.run(
                ["codesign", "-dv", "--verbose=2", str(binary)],
                capture_output=True, text=True, check=True
            ).stderr
            if "Authority=Developer ID Application:" not in signature:
                raise SystemExit(f"正式发布需要 Developer ID Application 签名：{binary}")

    with tempfile.TemporaryDirectory(prefix="conversation-trail-release-") as temporary:
        work = pathlib.Path(temporary)
        payload = work / "payload"
        applications = payload / "Applications"
        applications.mkdir(parents=True)
        shutil.copytree(app, applications / app.name, symlinks=True)
        relay_target = payload / RELAY_DESTINATION
        relay_target.parent.mkdir(parents=True)
        shutil.copy2(relay, relay_target)
        relay_target.chmod(0o755)
        host_manifest = payload / "Library/Google/Chrome/NativeMessagingHosts" / f"{HOST_NAME}.json"
        host_manifest.parent.mkdir(parents=True)
        host_manifest.write_text(json.dumps({
            "name": HOST_NAME,
            "description": "Conversation Trail relay for Local Audio Engine",
            "path": "/" + str(RELAY_DESTINATION),
            "type": "stdio",
            "allowed_origins": [f"chrome-extension://{extension_id}/"]
        }, ensure_ascii=False, indent=2) + "\n")
        host_manifest.chmod(0o644)

        component_plist = work / "components.plist"
        run("pkgbuild", "--analyze", "--root", payload, component_plist)
        components = plistlib.loads(component_plist.read_bytes())
        for component in components:
            component["BundleIsRelocatable"] = False
            component["BundleIsVersionChecked"] = False
            component["BundleOverwriteAction"] = "upgrade"
        component_plist.write_bytes(plistlib.dumps(components))

        bundle = work / f"Conversation Trail {version}"
        extension = bundle / "Conversation Trail Extension"
        extension.mkdir(parents=True)
        shutil.copy2(PROJECT / "manifest.json", extension / "manifest.json")
        (bundle / "docs").mkdir()
        shutil.copy2(PROJECT / "docs/local-audio-engine-protocol.md", bundle / "docs/local-audio-engine-protocol.md")
        for directory in ("content", "background", "popup"):
            shutil.copytree(PROJECT / "src" / directory, extension / "src" / directory)
        icons = set(manifest["icons"].values()) | set(manifest["action"]["default_icon"].values())
        for icon in icons:
            destination = extension / icon
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PROJECT / icon, destination)
        shutil.copy2(PROJECT / "README.md", bundle / "README.md")

        package = bundle / "Conversation Trail Audio.pkg"
        package_args = [
            "pkgbuild", "--root", payload,
            "--component-plist", component_plist,
            "--identifier", "com.johnny.conversation-trail.local-audio",
            "--version", version, "--install-location", "/",
            "--ownership", "recommended"
        ]
        if installer_identity:
            package_args.extend(["--sign", installer_identity, "--timestamp"])
        run(*package_args, package)
        if notary_profile:
            run("xcrun", "notarytool", "submit", package, "--keychain-profile", notary_profile, "--wait")
            run("xcrun", "stapler", "staple", package)

        suffix = "" if notary_profile else "-preview"
        archive = DIST / f"Conversation-Trail-{version}-macOS-{arch}{suffix}.zip"
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", bundle, archive)
        print(f"已生成统一下载包：{archive}")
        print("包内：本地音频安装器（Engine + relay）和 Conversation Trail Extension 文件夹。")
        if not notary_profile:
            print("此为未公证预览包，不应作为免拦截的公开发行包；正式发布前须配置 Developer ID 签名及公证。")


if __name__ == "__main__":
    main()
