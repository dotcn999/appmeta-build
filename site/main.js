const REPO = "dotcn999/appmeta-build";
const ASSET_NAME = "AppMeta-Build.zip";

async function resolveLatestDownload() {
  const primary = document.getElementById("dl-primary");
  const downloadBtn = document.getElementById("download-btn");
  const versionLabel = document.getElementById("version-label");
  const dlSub = document.getElementById("dl-sub");

  const fallback = `https://github.com/${REPO}/releases/latest`;
  primary.href = fallback;
  downloadBtn.href = "#download";

  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const data = await res.json();
    const asset = (data.assets || []).find((a) => a.name === ASSET_NAME)
      || (data.assets || []).find((a) => /\.zip$/i.test(a.name));

    if (data.tag_name) {
      versionLabel.textContent = data.tag_name;
    }

    if (asset?.browser_download_url) {
      primary.href = asset.browser_download_url;
      downloadBtn.href = asset.browser_download_url;
      dlSub.textContent = `${ASSET_NAME} · ${formatBytes(asset.size)} · ${formatDate(data.published_at)}`;
    } else {
      primary.href = "/downloads/AppMeta-Build.zip";
      downloadBtn.href = "/downloads/AppMeta-Build.zip";
      dlSub.textContent = "使用站点镜像下载 AppMeta-Build.zip";
    }
  } catch (_) {
    primary.href = "/downloads/AppMeta-Build.zip";
    downloadBtn.href = "/downloads/AppMeta-Build.zip";
    dlSub.textContent = "使用站点镜像下载，或前往 GitHub Releases";
  }
}

function formatBytes(n) {
  if (!n && n !== 0) return "";
  const u = ["B", "KB", "MB", "GB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i += 1;
  }
  return `${v.toFixed(i === 0 ? 0 : 1)} ${u[i]}`;
}

function formatDate(iso) {
  if (!iso) return "";
  try {
    return new Intl.DateTimeFormat("zh-CN", { dateStyle: "medium" }).format(new Date(iso));
  } catch {
    return "";
  }
}

resolveLatestDownload();
