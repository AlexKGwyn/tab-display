// Tab Display website: fetch the current release version from GitHub.
"use strict";

async function showReleaseVersion() {
  try {
    const res = await fetch("https://api.github.com/repos/AlexKGwyn/tab-display/releases/latest", {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) return;
    const release = await res.json();
    const tag = (release.tag_name || "").replace(/^v/, "");
    for (const el of document.querySelectorAll("[data-release-meta]")) {
      el.textContent = tag ? `Version ${tag} · macOS 14 or later` : "macOS 14 or later";
    }
  } catch {
    // Keep the static text.
  }
}

showReleaseVersion();
